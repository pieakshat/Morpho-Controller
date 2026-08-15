// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";

import {IMorpho} from "../../src/morpho/interfaces/IMorpho.sol";
import {IBundler3} from "../../src/morpho/interfaces/IBundler3.sol";
import {IGeneralAdapter1} from "../../src/morpho/interfaces/IGeneralAdapter1.sol";
import {MorphoLeverageVault} from "../../src/morpho/MorphoLeverageVault.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @notice Share-price inflation ("first depositor donation") attack against
///         MorphoLeverageVault, plus two control vaults that isolate which mitigation is
///         actually load-bearing.
///
/// @dev No network. No markets are ever registered, so totalAssets() reduces to idle
///      balance and the leverage engine is out of the picture entirely — this tier tests
///      share math and nothing else.
///
///      Attack model is a sandwich around a victim's pending deposit:
///        1. attacker seeds the empty vault with `seed`
///        2. attacker donates `donation` by raw transfer, inflating price-per-share
///        3. victim's deposit lands and rounds down, possibly to zero shares
///        4. attacker redeems everything
///
///      The attack "works" only if step 4 returns more than seed + donation. Donations are
///      recoverable in principle because the attacker holds the shares, so unprofitability
///      has to come from somewhere else: the virtual shares/assets the attacker can never
///      own. Each test below reports the actual numbers rather than only asserting a bound.
contract InflationAttackTest is Test {
    MockERC20 asset;

    address attacker = makeAddr("attacker");
    address victim = makeAddr("victim");
    address owner = makeAddr("owner");

    /// @dev 10 ** MorphoLeverageVault._decimalsOffset().
    uint256 constant OFFSET_SCALE = 1000;

    uint256 constant VICTIM_DEPOSIT = 100_000e6; // $100k

    function setUp() public {
        asset = new MockERC20("USD Coin", "USDC", 6);
    }

    function _newVault() internal returns (MorphoLeverageVault) {
        return new MorphoLeverageVault(
            asset, owner, IMorpho(address(0x1111)), IBundler3(address(0x2222)), IGeneralAdapter1(address(0x3333))
        );
    }

    struct Outcome {
        uint256 victimShares;
        uint256 attackerSpent;
        uint256 attackerRecovered;
        int256 attackerNet;
        uint256 victimRecovered;
        int256 victimNet;
    }

    /// @dev Incremented per attack so each run gets untouched addresses. Reusing one
    ///      attacker address across a sweep leaves the previous run's redemption sitting in
    ///      their balance, which reads as profit that never happened.
    uint256 runId;

    /// @dev Runs the full sandwich and reports what each side ended up with.
    function _runAttack(uint256 seed, uint256 donation, uint256 victimDeposit) internal returns (Outcome memory o) {
        MorphoLeverageVault vault = _newVault();

        attacker = address(uint160(uint256(keccak256(abi.encodePacked("attacker", runId)))));
        victim = address(uint160(uint256(keccak256(abi.encodePacked("victim", runId)))));
        runId++;

        asset.mint(attacker, seed + donation);
        asset.mint(victim, victimDeposit);

        // 1 + 2: seed the empty vault, then donate to inflate price-per-share.
        vm.startPrank(attacker);
        asset.approve(address(vault), type(uint256).max);
        vault.deposit(seed, attacker);
        asset.transfer(address(vault), donation);
        vm.stopPrank();

        // 3: the victim's deposit lands into the inflated price.
        vm.startPrank(victim);
        asset.approve(address(vault), type(uint256).max);
        o.victimShares = vault.deposit(victimDeposit, victim);
        vm.stopPrank();

        // 4: attacker exits first. Hoist balanceOf out of the call — evaluating it inline
        // would consume the prank and run redeem() as this test contract.
        uint256 attackerShares = vault.balanceOf(attacker);
        vm.prank(attacker);
        if (attackerShares > 0) vault.redeem(attackerShares, attacker, attacker);

        if (o.victimShares > 0) {
            vm.prank(victim);
            vault.redeem(o.victimShares, victim, victim);
        }

        o.attackerSpent = seed + donation;
        o.attackerRecovered = asset.balanceOf(attacker);
        o.attackerNet = int256(o.attackerRecovered) - int256(o.attackerSpent);
        o.victimRecovered = asset.balanceOf(victim);
        o.victimNet = int256(o.victimRecovered) - int256(victimDeposit);
    }

    /// @dev Smallest donation that floors the victim to zero shares, from OZ's
    ///      shares = assets * (totalSupply + 10**offset) / (totalAssets + 1).
    ///      After seeding an empty vault, totalSupply == seed * OFFSET_SCALE, so the victim
    ///      gets zero exactly when
    ///          victimDeposit * OFFSET_SCALE * (seed + 1) < seed + donation + 1
    function _donationToZeroOutVictim(uint256 seed, uint256 victimDeposit) internal pure returns (uint256) {
        return victimDeposit * OFFSET_SCALE * (seed + 1);
    }

    function _log(string memory label, Outcome memory o) internal pure {
        console2.log(label);
        console2.log("  victim shares minted :", o.victimShares);
        console2.log("  attacker spent       :", o.attackerSpent);
        console2.log("  attacker recovered   :", o.attackerRecovered);
        console2.log("  attacker net         :", o.attackerNet);
        console2.log("  victim net           :", o.victimNet);
    }

    /*//////////////////////////////////////////////////////////////
                     THE TEXTBOOK ATTACK, RUN FOR REAL
    //////////////////////////////////////////////////////////////*/

    /// @dev 1 wei seed, donation sized to floor the victim to exactly zero shares. This is
    ///      the canonical shape, and it is where the attacker's capital requirement is
    ///      lowest. It still loses money, and loses it badly.
    function test_textbookAttack_victimGetsZeroShares_butAttackerLosesHalf() public {
        uint256 seed = 1;
        uint256 donation = _donationToZeroOutVictim(seed, VICTIM_DEPOSIT);

        Outcome memory o = _runAttack(seed, donation, VICTIM_DEPOSIT);
        _log("textbook attack (1 wei seed)", o);

        // The steal half works: the victim really is minted nothing.
        assertEq(o.victimShares, 0, "victim should be floored to zero shares");

        // The profit half does not. The attacker holds seed*1000 real shares against 1000
        // virtual shares they can never own, so they redeem roughly half the pot.
        assertLt(o.attackerNet, 0, "attack must not be profitable");
        assertGt(uint256(-o.attackerNet), VICTIM_DEPOSIT, "attacker should lose more than the victim's entire deposit");
    }

    /// @dev The capital needed to pull off the zero-share case, stated plainly.
    function test_zeroingOutVictim_costsOrdersOfMagnitudeMoreThanItSteals() public pure {
        uint256 donation = _donationToZeroOutVictim(1, VICTIM_DEPOSIT);

        console2.log("to steal (USDC 6dp) :", VICTIM_DEPOSIT);
        console2.log("donation required   :", donation);
        console2.log("ratio               :", donation / VICTIM_DEPOSIT);

        assertGe(donation / VICTIM_DEPOSIT, 2 * OFFSET_SCALE, "should need >=2000x the target");
    }

    /*//////////////////////////////////////////////////////////////
                  SWEEPING THE ATTACKER'S FREE PARAMETER
    //////////////////////////////////////////////////////////////*/

    /// @dev A bigger seed dilutes the virtual shares, so the attacker keeps more of the pot
    ///      on exit. But the donation needed to floor the victim scales with the seed too.
    ///      Sweep it and confirm there is no seed size where the tradeoff flips.
    function test_sweepSeedSize_noSeedMakesTheAttackProfitable() public {
        uint256[5] memory seeds = [uint256(1), 10, 1e3, 1e6, 1e9];

        for (uint256 i = 0; i < seeds.length; i++) {
            uint256 seed = seeds[i];
            uint256 donation = _donationToZeroOutVictim(seed, VICTIM_DEPOSIT);

            Outcome memory o = _runAttack(seed, donation, VICTIM_DEPOSIT);
            console2.log("--- seed:", seed);
            _log("", o);

            assertEq(o.victimShares, 0, "victim floored at this seed");
            assertLt(o.attackerNet, 0, "no seed size makes this profitable");
        }
    }

    /// @dev The general case: any seed, any donation, any victim size. Nothing profits.
    function testFuzz_inflationAttack_isNeverProfitable(uint256 seed, uint256 donation, uint256 victimDeposit) public {
        seed = bound(seed, 1, 1e12);
        donation = bound(donation, 0, 1e18);
        victimDeposit = bound(victimDeposit, 1e6, 1e15);

        Outcome memory o = _runAttack(seed, donation, victimDeposit);

        assertLe(o.attackerNet, 0, "attacker must never end up ahead");
    }

    /*//////////////////////////////////////////////////////////////
                            GRIEFING, NOT PROFIT
    //////////////////////////////////////////////////////////////*/

    /// @dev Unprofitability is not the whole story: a griefer may accept a loss to impose
    ///      one. The victim's loss is NOT bounded to dust — a donation just under the
    ///      zero-share threshold rounds most of their deposit away. What does hold is that
    ///      the griefer always burns more than the victim loses, which is what makes it
    ///      economically irrational rather than merely unprofitable.
    function testFuzz_griefingAlwaysCostsTheGrieferMoreThanTheVictim(uint256 seed, uint256 donation) public {
        seed = bound(seed, 1, 1e12);
        donation = bound(donation, 0, 1e18);

        Outcome memory o = _runAttack(seed, donation, VICTIM_DEPOSIT);

        assertLe(o.attackerNet, 0, "griefer can never profit");

        if (o.victimNet >= 0) return; // victim captured part of the donation instead
        uint256 victimLoss = uint256(-o.victimNet);

        // Sub-dust losses are ordinary ERC4626 round-down. That value is stranded in the
        // vault for the remaining shareholders, not captured by anyone, so it is not a
        // griefing vector. Only test the property above that floor.
        if (victimLoss <= VICTIM_DEPOSIT / 1e6) return;

        assertGe(uint256(-o.attackerNet), victimLoss, "griefer must burn at least what the victim loses");
    }

    /// @dev Quantify the worst case honestly rather than asserting it small. Walks the
    ///      donation up to the zero-share threshold and reports the victim's peak loss
    ///      alongside what it cost to inflict.
    function test_worstCaseGriefing_victimCanLoseNearlyEverything() public {
        uint256 threshold = _donationToZeroOutVictim(1, VICTIM_DEPOSIT);
        uint256[4] memory fractions = [uint256(50), 90, 99, 100];

        uint256 worstVictimLoss;
        uint256 costOfWorst;

        for (uint256 i = 0; i < fractions.length; i++) {
            uint256 donation = (threshold * fractions[i]) / 100;
            Outcome memory o = _runAttack(1, donation, VICTIM_DEPOSIT);

            uint256 victimLoss = o.victimNet < 0 ? uint256(-o.victimNet) : 0;
            console2.log("--- donation as % of zero-share threshold:", fractions[i]);
            console2.log("  victim shares :", o.victimShares);
            console2.log("  victim loss   :", victimLoss);
            console2.log("  griefer burned:", uint256(-o.attackerNet));

            if (victimLoss > worstVictimLoss) {
                worstVictimLoss = victimLoss;
                costOfWorst = uint256(-o.attackerNet);
            }
        }

        console2.log("worst victim loss :", worstVictimLoss);
        console2.log("cost to inflict it:", costOfWorst);

        // The point of this test: the loss is material, and the price of causing it is not.
        assertGt(worstVictimLoss, VICTIM_DEPOSIT / 2, "victim really can lose most of their deposit");
        assertGt(costOfWorst, worstVictimLoss * 100, "but it costs the griefer >100x that to do it");
    }

    /*//////////////////////////////////////////////////////////////
                   CONTROLS: WHICH MITIGATION IS DOING IT
    //////////////////////////////////////////////////////////////*/

    /// @dev A vault with no virtual shares or assets at all — the pre-OZ-4.9 formula. This
    ///      is the shape the attack was named for. If it does not succeed here, the harness
    ///      above is not actually testing anything.
    function test_control_naiveVaultIsFullyDrained() public {
        NaiveVault naive = new NaiveVault(asset);

        asset.mint(attacker, 1 + VICTIM_DEPOSIT);
        asset.mint(victim, VICTIM_DEPOSIT);

        vm.startPrank(attacker);
        asset.approve(address(naive), type(uint256).max);
        naive.deposit(1);
        asset.transfer(address(naive), VICTIM_DEPOSIT); // donation == victim's deposit
        vm.stopPrank();

        vm.startPrank(victim);
        asset.approve(address(naive), type(uint256).max);
        uint256 victimShares = naive.deposit(VICTIM_DEPOSIT);
        vm.stopPrank();

        uint256 attackerShares = naive.balanceOf(attacker);
        vm.prank(attacker);
        naive.redeem(attackerShares);

        int256 attackerNet = int256(asset.balanceOf(attacker)) - int256(1 + VICTIM_DEPOSIT);
        console2.log("naive vault - victim shares:", victimShares);
        console2.log("naive vault - attacker net :", attackerNet);

        assertEq(victimShares, 0, "naive vault mints the victim nothing");
        assertGt(attackerNet, 0, "naive vault: attack is profitable, as expected");
        assertApproxEqAbs(
            uint256(attackerNet), VICTIM_DEPOSIT, 2, "attacker walks away with the victim's whole deposit"
        );
    }

    /// @dev Same attack against a stock OZ ERC4626 (offset 0). Virtual shares/assets alone
    ///      already defeat it; our offset of 3 raises the cost a further 1000x. Quantifies
    ///      what _decimalsOffset() actually buys on top of the OZ default.
    function test_control_offsetThreeCosts1000xMoreThanOffsetZero() public {
        PlainVault plain = new PlainVault(asset);

        // Zero-share threshold with offset 0 and a 1 wei seed: donation > 2 * victimDeposit.
        uint256 plainDonation = 2 * VICTIM_DEPOSIT;

        asset.mint(attacker, 1 + plainDonation);
        asset.mint(victim, VICTIM_DEPOSIT);

        vm.startPrank(attacker);
        asset.approve(address(plain), type(uint256).max);
        plain.deposit(1, attacker);
        asset.transfer(address(plain), plainDonation);
        vm.stopPrank();

        vm.startPrank(victim);
        asset.approve(address(plain), type(uint256).max);
        uint256 plainVictimShares = plain.deposit(VICTIM_DEPOSIT, victim);
        vm.stopPrank();

        uint256 ourDonation = _donationToZeroOutVictim(1, VICTIM_DEPOSIT);

        console2.log("offset 0 donation to zero out victim:", plainDonation);
        console2.log("offset 3 donation to zero out victim:", ourDonation);
        console2.log("multiplier                          :", ourDonation / plainDonation);

        assertEq(plainVictimShares, 0, "offset 0 victim also floored at this donation");
        assertEq(ourDonation / plainDonation, OFFSET_SCALE, "offset 3 costs exactly 1000x more");
    }
}

/// @notice Pre-virtual-shares ERC4626 math. Exists only as a positive control.
contract NaiveVault is ERC20 {
    IERC20 public immutable ASSET;

    constructor(IERC20 asset_) ERC20("Naive", "NV") {
        ASSET = asset_;
    }

    function totalAssets() public view returns (uint256) {
        return ASSET.balanceOf(address(this));
    }

    function deposit(uint256 assets) external returns (uint256 shares) {
        uint256 supply = totalSupply();
        shares = supply == 0 ? assets : (assets * supply) / totalAssets();
        ASSET.transferFrom(msg.sender, address(this), assets);
        _mint(msg.sender, shares);
    }

    function redeem(uint256 shares) external returns (uint256 assets) {
        assets = (shares * totalAssets()) / totalSupply();
        _burn(msg.sender, shares);
        ASSET.transfer(msg.sender, assets);
    }
}

/// @notice Stock OZ ERC4626, default _decimalsOffset() of 0. Control for isolating what
///         our offset of 3 adds on top of OZ's built-in virtual shares/assets.
contract PlainVault is ERC4626 {
    constructor(IERC20 asset_) ERC20("Plain", "PLN") ERC4626(asset_) {}
}
