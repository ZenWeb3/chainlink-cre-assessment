// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title ISnapshot
/// @notice Interface for a contract that records Chainlink Data Feed price
///         snapshots delivered by a CRE workflow.
interface ISnapshot {
    /// @notice A single price observation taken from a Chainlink Data Feed.
    /// @param token       Token symbol the price refers to, e.g. "ETH".
    /// @param price       Feed answer, in the feed's own decimals (8 for USD feeds).
    /// @param blockNumber Block at which the Data Feed answer was last updated
    ///                    (the block of the aggregator's `AnswerUpdated` event),
    ///                    NOT the block in which this snapshot was stored.
    /// @param timestamp   Feed's `updatedAt` for that answer (seconds since epoch).
    struct Record {
        string token;
        uint256 price;
        uint256 blockNumber;
        uint256 timestamp;
    }

    /// @notice Records a price snapshot.
    /// @dev This is the function signature that defines the shape of the CRE
    ///      report payload: the workflow writes `abi.encode(Record)`, which the
    ///      Chainlink Forwarder delivers to `onReport`, which in turn routes it
    ///      here. Direct external calls are rejected — see
    ///      `PriceSnapshot.snapshot`.
    /// @param record The price snapshot to store.
    function snapshot(Record calldata record) external;
}
