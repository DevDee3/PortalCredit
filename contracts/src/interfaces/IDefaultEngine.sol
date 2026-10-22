// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @notice Lifecycle states of a financed receivable, as tracked by the DefaultEngine.
interface IDefaultEngine {
    enum Status {
        None,
        Performing,
        Overdue,
        Disputed,
        Seized,
        Liquidated, // auction settled, principal shortfall may still be recoverable
        Recovered, // all principal recovered
        WrittenOff, // shortfall accepted as a loss
        Repaid // borrower repaid in full, no default
    }

    function statusOf(uint256 tokenId) external view returns (Status);

    /// @dev Called by the vault when a loan is originated.
    function onAdvanced(uint256 tokenId) external;

    /// @dev Called by the vault when a loan is fully repaid.
    function onRepaid(uint256 tokenId) external;
}
