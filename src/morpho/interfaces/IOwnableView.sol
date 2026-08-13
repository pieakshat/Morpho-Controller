// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice The read half of OZ's Ownable — enough for CircuitBreaker to single-source its
///         admin rights from whatever contract deployed it, without importing the full
///         Ownable/Ownable2Step dependency chain or caring how that contract implements it.
interface IOwnableView {
    function owner() external view returns (address);
}
