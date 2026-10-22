// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @notice Pluggable default-resolution backend. Portaldot's DaaS protocol can be adapted to this interface.
interface IDefaultResolver {
    /// @notice Return false to veto seizure of a receivable (e.g. the default was not validated).
    function validateDefault(uint256 tokenId, bytes calldata evidence) external returns (bool isValid);

    /// @notice Notification that collateral was seized.
    function onSeized(uint256 tokenId) external;

    /// @notice Notification that a seized receivable was liquidated for `recovered`.
    function onLiquidated(uint256 tokenId, uint256 recovered) external;
}
