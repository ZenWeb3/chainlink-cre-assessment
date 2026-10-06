// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC165} from "./IERC165.sol";
import {IReceiver} from "./IReceiver.sol";
import {ISnapshot} from "./ISnapshot.sol";

/// @title PriceSnapshot
/// @notice Stores Chainlink Data Feed price snapshots delivered by a CRE workflow.
/// @dev A CRE workflow never calls this contract directly. It produces a signed
///      report that the Chainlink `KeystoneForwarder` verifies and then delivers
///      by calling `onReport`. The forwarder check in `onReport` is therefore the
///      contract's primary access control: it is what makes a stored snapshot
///      trustworthy.
///
///      Report payload layout: `abi.encode(ISnapshot.Record)`.
contract PriceSnapshot is ISnapshot, IReceiver {
    // ---------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------

    /// @notice Contract owner, allowed to update the forwarder and the optional
    ///         workflow-identity checks.
    address public owner;

    /// @notice The only address allowed to call `onReport`.
    /// @dev In production this is the Chainlink `KeystoneForwarder` for the
    ///      chain. When running `cre workflow simulate --broadcast` the caller is
    ///      the `MockKeystoneForwarder` instead, which has a different address.
    address public forwarder;

    /// @notice Optional: if set, only reports authored by this workflow owner are
    ///         accepted. Zero disables the check.
    address public expectedWorkflowOwner;

    /// @notice Optional: if set, only reports from this workflow name are
    ///         accepted. Requires `expectedWorkflowOwner` to also be set,
    ///         because names are only unique per owner and are truncated to 10
    ///         bytes. Zero disables the check.
    bytes10 public expectedWorkflowName;

    /// @notice Latest snapshot per token, keyed by `keccak256(bytes(token))`.
    mapping(bytes32 tokenKey => Record record) private s_records;

    /// @notice Every token that has ever been recorded, in first-seen order.
    string[] private s_tokens;

    /// @notice Most recently recorded snapshot across all tokens.
    Record public latestRecord;

    /// @notice Total number of snapshots stored.
    uint256 public snapshotCount;

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    event SnapshotRecorded(
        string indexed token, uint256 price, uint256 blockNumber, uint256 timestamp
    );
    event ForwarderUpdated(address indexed previousForwarder, address indexed newForwarder);
    event ExpectedWorkflowOwnerUpdated(address indexed previousOwner, address indexed newOwner);
    event ExpectedWorkflowNameUpdated(bytes10 indexed previousName, bytes10 indexed newName);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------

    error ZeroAddress();
    error NotOwner(address caller);
    /// @dev Raised by the forwarder check: `onReport` was not called by `forwarder`.
    error UnauthorizedForwarder(address caller, address expected);
    error DirectSnapshotCallNotAllowed(address caller);
    error InvalidMetadataLength(uint256 length);
    error UnauthorizedWorkflowOwner(address received, address expected);
    error UnauthorizedWorkflowName(bytes10 received, bytes10 expected);
    error WorkflowNameRequiresOwnerCheck();
    error EmptyToken();
    error ZeroPrice();
    /// @dev Replay / out-of-order protection: a snapshot must be strictly newer
    ///      than the one already stored for the same token.
    error StaleSnapshot(uint256 incomingBlockNumber, uint256 storedBlockNumber);

    // ---------------------------------------------------------------------
    // Construction
    // ---------------------------------------------------------------------

    /// @param forwarder_ The Chainlink Forwarder permitted to call `onReport`.
    ///        Use the `MockKeystoneForwarder` address to exercise the contract
    ///        with `cre workflow simulate --broadcast`, and the production
    ///        `KeystoneForwarder` for a deployed workflow. It can be changed
    ///        later with `setForwarder`.
    constructor(address forwarder_) {
        if (forwarder_ == address(0)) revert ZeroAddress();
        owner = msg.sender;
        forwarder = forwarder_;
        emit OwnershipTransferred(address(0), msg.sender);
        emit ForwarderUpdated(address(0), forwarder_);
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner(msg.sender);
        _;
    }

    // ---------------------------------------------------------------------
    // CRE report intake
    // ---------------------------------------------------------------------

    /// @inheritdoc IReceiver
    /// @dev `report` is `abi.encode(ISnapshot.Record)`.
    function onReport(bytes calldata metadata, bytes calldata report) external override {
        // ---- The forwarder check -----------------------------------------
        // Only the trusted Chainlink Forwarder may deliver reports. The
        // forwarder has already verified the report's DON signatures, so this
        // single check is what lets the contract treat `report` as authentic.
        if (msg.sender != forwarder) {
            revert UnauthorizedForwarder(msg.sender, forwarder);
        }

        // ---- Optional workflow-identity checks ---------------------------
        // Skipped entirely when unset, because the MockKeystoneForwarder used by
        // `cre workflow simulate` does not supply workflow metadata.
        if (expectedWorkflowOwner != address(0) || expectedWorkflowName != bytes10(0)) {
            _validateWorkflowIdentity(metadata);
        }

        Record memory record = abi.decode(report, (Record));

        // Route through the ISnapshot entry point so that there is exactly one
        // code path that writes a snapshot.
        this.snapshot(record);
    }

    /// @inheritdoc ISnapshot
    /// @dev Only reachable through `onReport`'s self-call. A direct external call
    ///      is rejected, so the forwarder check cannot be bypassed by calling
    ///      `snapshot` straight from an EOA.
    function snapshot(Record calldata record) external override {
        if (msg.sender != address(this)) revert DirectSnapshotCallNotAllowed(msg.sender);

        if (bytes(record.token).length == 0) revert EmptyToken();
        if (record.price == 0) revert ZeroPrice();

        bytes32 tokenKey = keccak256(bytes(record.token));
        Record storage stored = s_records[tokenKey];

        if (stored.timestamp == 0) {
            // First snapshot for this token.
            s_tokens.push(record.token);
        } else if (record.blockNumber <= stored.blockNumber) {
            // Reject replays of an older signed report, and no-op rewrites of
            // the same feed round.
            revert StaleSnapshot(record.blockNumber, stored.blockNumber);
        }

        s_records[tokenKey] = record;
        latestRecord = record;
        snapshotCount++;

        emit SnapshotRecorded(record.token, record.price, record.blockNumber, record.timestamp);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    /// @notice Returns the latest snapshot recorded for `token`.
    /// @dev A token that has never been recorded returns a zero-valued `Record`;
    ///      check `timestamp != 0` to distinguish that from a real snapshot.
    function getSnapshot(string calldata token) external view returns (Record memory) {
        return s_records[keccak256(bytes(token))];
    }

    /// @notice True if a snapshot has ever been recorded for `token`.
    function hasSnapshot(string calldata token) external view returns (bool) {
        return s_records[keccak256(bytes(token))].timestamp != 0;
    }

    /// @notice Every token that has ever been recorded, in first-seen order.
    function getTokens() external view returns (string[] memory) {
        return s_tokens;
    }

    /// @notice Number of distinct tokens recorded.
    function tokenCount() external view returns (uint256) {
        return s_tokens.length;
    }

    /// @inheritdoc IERC165
    /// @dev The forwarder checks this before delivering a report.
    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IReceiver).interfaceId
            || interfaceId == type(IERC165).interfaceId;
    }

    // ---------------------------------------------------------------------
    // Administration
    // ---------------------------------------------------------------------

    /// @notice Points the contract at a different Chainlink Forwarder.
    /// @dev Used when moving from simulation (`MockKeystoneForwarder`) to a
    ///      deployed workflow (`KeystoneForwarder`). `address(0)` is rejected:
    ///      disabling the forwarder check would let anyone write snapshots.
    function setForwarder(address forwarder_) external onlyOwner {
        if (forwarder_ == address(0)) revert ZeroAddress();
        emit ForwarderUpdated(forwarder, forwarder_);
        forwarder = forwarder_;
    }

    /// @notice Restricts accepted reports to a single workflow owner.
    /// @param workflowOwner Workflow owner address, or `address(0)` to disable.
    /// @dev Leave disabled while using `cre workflow simulate`: the
    ///      MockKeystoneForwarder does not provide workflow metadata.
    function setExpectedWorkflowOwner(address workflowOwner) external onlyOwner {
        emit ExpectedWorkflowOwnerUpdated(expectedWorkflowOwner, workflowOwner);
        expectedWorkflowOwner = workflowOwner;
    }

    /// @notice Restricts accepted reports to a single workflow name.
    /// @param workflowName The 10-byte encoded workflow name, or `bytes10(0)` to
    ///        disable. See `encodeWorkflowName` for how to derive it.
    function setExpectedWorkflowName(bytes10 workflowName) external onlyOwner {
        emit ExpectedWorkflowNameUpdated(expectedWorkflowName, workflowName);
        expectedWorkflowName = workflowName;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    // ---------------------------------------------------------------------
    // Workflow metadata helpers
    // ---------------------------------------------------------------------

    /// @notice Encodes a plaintext workflow name the way the CRE engine does.
    /// @dev sha256(name) -> lowercase hex string -> first 10 ASCII characters,
    ///      taken as `bytes10`. Pass the result to `setExpectedWorkflowName`.
    function encodeWorkflowName(string memory name) public pure returns (bytes10) {
        if (bytes(name).length == 0) return bytes10(0);

        bytes memory hexChars = "0123456789abcdef";
        bytes32 digest = sha256(bytes(name));
        bytes memory first10 = new bytes(10);
        for (uint256 i = 0; i < 10; i++) {
            uint8 nibble = i % 2 == 0 ? uint8(digest[i / 2]) >> 4 : uint8(digest[i / 2]) & 0x0f;
            first10[i] = hexChars[nibble];
        }
        // casting to 'bytes10' is safe because first10 is allocated with length 10
        // forge-lint: disable-next-line(unsafe-typecast)
        return bytes10(first10);
    }

    /// @notice Decodes the `metadata` argument the Forwarder passes to `onReport`.
    /// @dev Layout is `abi.encodePacked(bytes32 workflowId, bytes10 workflowName,
    ///      address workflowOwner)` = 62 bytes. The production forwarder hands
    ///      over a 64-byte word-aligned slice whose trailing 2 bytes are the
    ///      `reportId`, so both lengths are accepted.
    function decodeMetadata(bytes calldata metadata)
        public
        pure
        returns (bytes32 workflowId, bytes10 workflowName, address workflowOwner)
    {
        if (metadata.length != 62 && metadata.length != 64) {
            revert InvalidMetadataLength(metadata.length);
        }
        workflowId = bytes32(metadata[0:32]);
        workflowName = bytes10(metadata[32:42]);
        workflowOwner = address(bytes20(metadata[42:62]));
    }

    function _validateWorkflowIdentity(bytes calldata metadata) private view {
        (, bytes10 workflowName, address workflowOwner) = decodeMetadata(metadata);

        if (expectedWorkflowOwner != address(0) && workflowOwner != expectedWorkflowOwner) {
            revert UnauthorizedWorkflowOwner(workflowOwner, expectedWorkflowOwner);
        }

        if (expectedWorkflowName != bytes10(0)) {
            // A 10-byte name is only unique per owner, so validating it without
            // also pinning the owner would be unsafe.
            if (expectedWorkflowOwner == address(0)) revert WorkflowNameRequiresOwnerCheck();
            if (workflowName != expectedWorkflowName) {
                revert UnauthorizedWorkflowName(workflowName, expectedWorkflowName);
            }
        }
    }
}
