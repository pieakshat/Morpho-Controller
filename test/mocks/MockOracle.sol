// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IOracle} from "../../src/morpho/interfaces/IOracle.sol";

/// @notice Settable IOracle stand-in. Returns whatever price() the test configures, or
///         reverts entirely once setBroken() is called, to simulate an oracle outage.
contract MockOracle is IOracle {
    uint256 internal _price;
    bool internal _broken;

    function setPrice(uint256 price_) external {
        _price = price_;
        _broken = false;
    }

    function setBroken() external {
        _broken = true;
    }

    function price() external view returns (uint256) {
        require(!_broken, "MockOracle: broken");
        return _price;
    }
}
