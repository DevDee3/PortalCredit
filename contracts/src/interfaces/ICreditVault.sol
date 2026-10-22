// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @notice The surface of the vault that the DefaultEngine depends on.
interface ICreditVault {
    function isActive(uint256 tokenId) external view returns (bool);
    function dueDateOf(uint256 tokenId) external view returns (uint64);
    function borrowerOf(uint256 tokenId) external view returns (address);
    function debtOf(uint256 tokenId) external view returns (uint256);

    /// @notice Moves collateral to the engine and marks the loan impaired at the auction floor.
    function seize(uint256 tokenId, uint16 floorBps) external;

    /// @notice Extends a loan after a successful dispute.
    function setDueDate(uint256 tokenId, uint64 newDueDate) external;

    /// @notice Pulls `recovered` from `payer`, waterfalls it (principal, then fee) and closes the loan.
    /// @return principalShortfall principal that was not recovered
    function applyLiquidation(uint256 tokenId, uint256 recovered, address payer)
        external
        returns (uint256 principalShortfall);

    /// @notice Pulls a late recovery from `payer` and credits it to LPs.
    function creditRecovery(address payer, uint256 amount) external;

    /// @notice Books tokens the engine has already transferred in (e.g. a forfeited bond) as LP yield.
    function bookYield(uint256 amount) external;
}
