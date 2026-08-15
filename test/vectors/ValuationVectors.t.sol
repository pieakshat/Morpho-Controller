// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IMorpho, Id, MarketParams} from "../../src/morpho/interfaces/IMorpho.sol";
import {IBundler3} from "../../src/morpho/interfaces/IBundler3.sol";
import {IGeneralAdapter1} from "../../src/morpho/interfaces/IGeneralAdapter1.sol";
import {IOracle} from "../../src/morpho/interfaces/IOracle.sol";
import {MarketAction} from "../../src/morpho/types/MorphoTypes.sol";
import {MorphoLeverageVault} from "../../src/morpho/MorphoLeverageVault.sol";
import {MockSwapRouter} from "../mocks/MockSwapRouter.sol";

/// @notice Dumps real positions and the vault's own reported totals to JSON, so the
///         TypeScript valuation mirror can be checked against them.
///
/// @dev `_positionValue` and `_morphoSurplusAndShortfall` are internal, so the off-chain side
///      has to reconstruct them from raw Morpho state. Nothing but a differential test
///      catches that reconstruction drifting. Here the contract reports totalAssets() and
///      totalMorphoAssets(); the mirror must derive the same numbers from the raw inputs
///      alone.
///
///      Needs a fork to regenerate, but the output is committed so the TypeScript suite runs
///      offline:
///        forge test --match-path 'test/vectors/ValuationVectors.t.sol'
///
///      Two line kinds, grouped by scenario index:
///        pos,<i>,<collateral>,<borrowShares>,<totalBorrowAssets>,<totalBorrowShares>,<price>
///        tot,<i>,<idle>,<totalMorphoAssets>,<totalAssets>
contract ValuationVectorsTest is Test {
    address constant MORPHO = 0x6c247b1F6182318877311737BaC0844bAa518F5e;
    address constant BUNDLER3 = 0x1FA4431bC113D308beE1d46B0e98Cb805FB48C13;
    address constant GENERAL_ADAPTER = 0x9954aFB60BB5A222714c478ac86990F221788B88;
    address constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address constant WSTETH = 0x5979D7b546E38E414F7E9822514be443A4800529;
    address constant WSTETH_ORACLE = 0x8e02a9b9Cc29d783b2fCB71C3a72651B591cae31;
    address constant WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address constant WETH_ORACLE = 0x282FEB10549fde52bD61A6979424Ddf18A4971A2;
    address constant IRM = 0x66F30587FB8D4206918deb78ecA7d5eBbafD06DA;
    uint256 constant FORK_BLOCK = 491_260_000;

    MorphoLeverageVault vault;
    MockSwapRouter router;
    address owner = makeAddr("owner");

    MarketParams wstEthParams;
    MarketParams wethParams;

    string[] private lines;
    uint256 private scenario;

    function setUp() public {
        vm.createSelectFork(vm.envString("ARBITRUM_RPC_URL"), FORK_BLOCK);
        router = new MockSwapRouter();

        vault = new MorphoLeverageVault(
            IERC20(USDC), owner, IMorpho(MORPHO), IBundler3(BUNDLER3), IGeneralAdapter1(GENERAL_ADAPTER)
        );

        wstEthParams =
            MarketParams({loanToken: USDC, collateralToken: WSTETH, oracle: WSTETH_ORACLE, irm: IRM, lltv: 0.86e18});
        wethParams =
            MarketParams({loanToken: USDC, collateralToken: WETH, oracle: WETH_ORACLE, irm: IRM, lltv: 0.86e18});

        vm.startPrank(owner);
        vault.registerMarket(wstEthParams, 10e18, 50);
        vault.registerMarket(wethParams, 10e18, 50);
        vm.stopPrank();

        deal(USDC, address(this), 1_000_000e6);
        IERC20(USDC).approve(address(vault), type(uint256).max);
        vault.deposit(1_000_000e6, address(this));
    }

    function _open(MarketParams memory params, address oracle, uint256 ownAmount, uint256 leverage) internal {
        uint256 totalAmount = (ownAmount * leverage) / 1e18;
        uint256 rate = 1e54 / IOracle(oracle).price();
        router.setRate(rate);
        uint256 expectedOut = (totalAmount * rate) / 1e18;
        deal(params.collateralToken, address(router), expectedOut);

        MarketAction[] memory actions = new MarketAction[](1);
        actions[0] = MarketAction({
            marketId: Id.wrap(keccak256(abi.encode(params))),
            isIncrease: true,
            amount: ownAmount,
            leverage: leverage,
            minOut: expectedOut,
            swapTarget: address(router),
            swapCalldata: abi.encodeCall(MockSwapRouter.swap, (IERC20(USDC), IERC20(params.collateralToken), totalAmount))
        });
        vm.prank(owner);
        vault.executeActions(actions);
    }

    /// @dev Records the raw inputs for every active market plus the vault's own totals. The
    ///      mirror gets only the `pos` lines and must produce the `tot` line.
    function _record() internal {
        Id[] memory active = vault.activeMarkets();
        for (uint256 i = 0; i < active.length; ++i) {
            Id id = active[i];
            MarketParams memory params = vault.marketConfig(id).params;
            (, uint128 borrowShares, uint128 collateral) = IMorpho(MORPHO).position(id, address(vault));
            (,, uint128 tba, uint128 tbs,,) = IMorpho(MORPHO).market(id);
            lines.push(
                string.concat(
                    "pos,",
                    vm.toString(scenario),
                    ",",
                    vm.toString(uint256(collateral)),
                    ",",
                    vm.toString(uint256(borrowShares)),
                    ",",
                    vm.toString(uint256(tba)),
                    ",",
                    vm.toString(uint256(tbs)),
                    ",",
                    vm.toString(IOracle(params.oracle).price())
                )
            );
        }
        lines.push(
            string.concat(
                "tot,",
                vm.toString(scenario),
                ",",
                vm.toString(IERC20(USDC).balanceOf(address(vault))),
                ",",
                vm.toString(vault.totalMorphoAssets()),
                ",",
                vm.toString(vault.totalAssets())
            )
        );
        scenario++;
    }

    function test_writeValuationVectors() public {
        _record(); // 0: idle only, no positions at all

        _open(wstEthParams, WSTETH_ORACLE, 100_000e6, 2e18);
        _record(); // 1: single 2x position

        _open(wethParams, WETH_ORACLE, 50_000e6, 3e18);
        _record(); // 2: two markets, different collateral and oracles

        _open(wstEthParams, WSTETH_ORACLE, 25_000e6, 1e18);
        _record(); // 3: adds collateral with no borrow, lowering the wstETH position's ratio

        string memory obj = "valuation";
        string memory out = vm.serializeString(obj, "cases", lines);
        vm.writeJson(out, "./allocator/packages/core/test/vectors/valuation.json");
    }
}
