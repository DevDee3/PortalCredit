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

    /// @notice Seconds after the due date before a loan can be flagged overdue.
    function gracePeriod() external view returns (uint64);

    /// @notice Expected auction floor, in bps of debt. Used to size the write-down when a loan goes overdue.
    function floorBps() external view returns (uint16);

    /// @dev Called by the vault when it recognises a loan as overdue on its own (stale-loan sync).
    ///      The vault has already booked the write-down; the engine only moves the state machine.
    function onOverdue(uint256 tokenId) external;

    /// @dev Called by the vault when a loan is originated.
    function onAdvanced(uint256 tokenId) external;

    /// @dev Called by the vault when a loan is fully repaid.
    function onRepaid(uint256 tokenId) external;
}
