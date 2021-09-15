// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.4;

/// @title Interface for operator selectors
interface IOperatorSelector {
    /// @notice Return the operator commit function selector
    /// @return Function selector
    function getCommitSelector() external pure returns (bytes4);

    /// @notice Return the operator revert function selector
    /// @return Function selector
    function getRevertSelector() external pure returns (bytes4);
}
