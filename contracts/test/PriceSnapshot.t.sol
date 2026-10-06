// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC165} from "../src/IERC165.sol";
import {IReceiver} from "../src/IReceiver.sol";
import {ISnapshot} from "../src/ISnapshot.sol";
import {PriceSnapshot} from "../src/PriceSnapshot.sol";

contract PriceSnapshotTest is Test {
    PriceSnapshot internal snap;

    address internal constant FORWARDER = address(0xF0F0);
    address internal constant OTHER_FORWARDER = address(0xBEEF);
    address internal constant ATTACKER = address(0xBAD);
    address internal constant OWNER = address(0xA11CE);

    address internal constant WORKFLOW_OWNER = address(0x1234);
    bytes32 internal constant WORKFLOW_ID = keccak256("workflow-id");

    event SnapshotRecorded(
        string indexed token, uint256 price, uint256 blockNumber, uint256 timestamp
    );

    function setUp() public {
        vm.prank(OWNER);
        snap = new PriceSnapshot(FORWARDER);
    }

    // ----- helpers ---------------------------------------------------------

    function _record(string memory token, uint256 price, uint256 blockNumber, uint256 timestamp)
        internal
        pure
        returns (ISnapshot.Record memory)
    {
        return ISnapshot.Record({
            token: token,
            price: price,
            blockNumber: blockNumber,
            timestamp: timestamp
        });
    }

    /// @dev Mirrors what the workflow writes: `abi.encode(Record)`.
    function _report(ISnapshot.Record memory record) internal pure returns (bytes memory) {
        return abi.encode(record);
    }

    /// @dev 62-byte packed metadata, as the layout is documented.
    function _metadata62(bytes32 workflowId, bytes10 workflowName, address workflowOwner)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodePacked(workflowId, workflowName, workflowOwner);
    }

    /// @dev 64-byte slice the production KeystoneForwarder actually passes: the
    ///      62 identity bytes plus a 2-byte reportId.
    function _metadata64(
        bytes32 workflowId,
        bytes10 workflowName,
        address workflowOwner,
        bytes2 reportId
    ) internal pure returns (bytes memory) {
        return abi.encodePacked(workflowId, workflowName, workflowOwner, reportId);
    }

    function _deliver(ISnapshot.Record memory record) internal {
        vm.prank(FORWARDER);
        snap.onReport(_metadata64(WORKFLOW_ID, bytes10(0), WORKFLOW_OWNER, bytes2(0)), _report(record));
    }

    // ----- construction ----------------------------------------------------

    function test_constructor_setsOwnerAndForwarder() public view {
        assertEq(snap.owner(), OWNER);
        assertEq(snap.forwarder(), FORWARDER);
        assertEq(snap.snapshotCount(), 0);
        assertEq(snap.tokenCount(), 0);
    }

    function test_constructor_rejectsZeroForwarder() public {
        vm.expectRevert(PriceSnapshot.ZeroAddress.selector);
        new PriceSnapshot(address(0));
    }

    function test_supportsInterface() public view {
        assertTrue(snap.supportsInterface(type(IReceiver).interfaceId));
        assertTrue(snap.supportsInterface(type(IERC165).interfaceId));
        assertFalse(snap.supportsInterface(0xdeadbeef));
    }

    // ----- the forwarder check --------------------------------------------

    function test_onReport_revertsForNonForwarder() public {
        ISnapshot.Record memory record = _record("ETH", 1e11, 100, 1_700_000_000);
        bytes memory metadata = _metadata64(WORKFLOW_ID, bytes10(0), WORKFLOW_OWNER, bytes2(0));

        vm.prank(ATTACKER);
        vm.expectRevert(
            abi.encodeWithSelector(
                PriceSnapshot.UnauthorizedForwarder.selector, ATTACKER, FORWARDER
            )
        );
        snap.onReport(metadata, _report(record));

        assertEq(snap.snapshotCount(), 0);
    }

    function test_onReport_revertsForPreviousForwarderAfterUpdate() public {
        vm.prank(OWNER);
        snap.setForwarder(OTHER_FORWARDER);

        ISnapshot.Record memory record = _record("ETH", 1e11, 100, 1_700_000_000);
        vm.prank(FORWARDER);
        vm.expectRevert(
            abi.encodeWithSelector(
                PriceSnapshot.UnauthorizedForwarder.selector, FORWARDER, OTHER_FORWARDER
            )
        );
        snap.onReport(
            _metadata64(WORKFLOW_ID, bytes10(0), WORKFLOW_OWNER, bytes2(0)), _report(record)
        );

        vm.prank(OTHER_FORWARDER);
        snap.onReport(
            _metadata64(WORKFLOW_ID, bytes10(0), WORKFLOW_OWNER, bytes2(0)), _report(record)
        );
        assertEq(snap.snapshotCount(), 1);
    }

    function testFuzz_onReport_onlyForwarderSucceeds(address caller) public {
        vm.assume(caller != FORWARDER);
        ISnapshot.Record memory record = _record("ETH", 1e11, 100, 1_700_000_000);

        vm.prank(caller);
        vm.expectRevert(
            abi.encodeWithSelector(PriceSnapshot.UnauthorizedForwarder.selector, caller, FORWARDER)
        );
        snap.onReport(
            _metadata64(WORKFLOW_ID, bytes10(0), WORKFLOW_OWNER, bytes2(0)), _report(record)
        );
    }

    /// @dev `snapshot` is the ISnapshot entry point, but it must not be a way
    ///      around the forwarder check.
    function test_snapshot_rejectsDirectCalls() public {
        ISnapshot.Record memory record = _record("ETH", 1e11, 100, 1_700_000_000);

        vm.prank(ATTACKER);
        vm.expectRevert(
            abi.encodeWithSelector(PriceSnapshot.DirectSnapshotCallNotAllowed.selector, ATTACKER)
        );
        snap.snapshot(record);

        vm.prank(FORWARDER);
        vm.expectRevert(
            abi.encodeWithSelector(PriceSnapshot.DirectSnapshotCallNotAllowed.selector, FORWARDER)
        );
        snap.snapshot(record);

        vm.prank(OWNER);
        vm.expectRevert(
            abi.encodeWithSelector(PriceSnapshot.DirectSnapshotCallNotAllowed.selector, OWNER)
        );
        snap.snapshot(record);
    }

    // ----- recording -------------------------------------------------------

    function test_onReport_storesRecord() public {
        ISnapshot.Record memory record = _record("ETH", 269_574_660_667, 11_857_693, 1_791_312_240);

        vm.expectEmit(true, false, false, true, address(snap));
        emit SnapshotRecorded("ETH", 269_574_660_667, 11_857_693, 1_791_312_240);
        _deliver(record);

        ISnapshot.Record memory stored = snap.getSnapshot("ETH");
        assertEq(stored.token, "ETH");
        assertEq(stored.price, 269_574_660_667);
        assertEq(stored.blockNumber, 11_857_693);
        assertEq(stored.timestamp, 1_791_312_240);

        assertEq(snap.snapshotCount(), 1);
        assertEq(snap.tokenCount(), 1);
        assertTrue(snap.hasSnapshot("ETH"));
        assertFalse(snap.hasSnapshot("BTC"));

        (string memory token, uint256 price, uint256 blockNumber, uint256 timestamp) =
            snap.latestRecord();
        assertEq(token, "ETH");
        assertEq(price, 269_574_660_667);
        assertEq(blockNumber, 11_857_693);
        assertEq(timestamp, 1_791_312_240);
    }

    function test_onReport_acceptsBoth62And64ByteMetadata() public {
        vm.prank(FORWARDER);
        snap.onReport(
            _metadata62(WORKFLOW_ID, bytes10(0), WORKFLOW_OWNER),
            _report(_record("ETH", 1e11, 100, 1_700_000_000))
        );
        assertEq(snap.snapshotCount(), 1);

        vm.prank(FORWARDER);
        snap.onReport(
            _metadata64(WORKFLOW_ID, bytes10(0), WORKFLOW_OWNER, 0xabcd),
            _report(_record("ETH", 2e11, 200, 1_700_000_100))
        );
        assertEq(snap.snapshotCount(), 2);
    }

    function test_onReport_tracksMultipleTokens() public {
        _deliver(_record("ETH", 1e11, 100, 1_700_000_000));
        _deliver(_record("BTC", 9e12, 101, 1_700_000_010));
        _deliver(_record("LINK", 1e9, 102, 1_700_000_020));

        assertEq(snap.tokenCount(), 3);
        string[] memory tokens = snap.getTokens();
        assertEq(tokens[0], "ETH");
        assertEq(tokens[1], "BTC");
        assertEq(tokens[2], "LINK");

        assertEq(snap.getSnapshot("BTC").price, 9e12);
        assertEq(snap.getSnapshot("LINK").blockNumber, 102);
    }

    function test_onReport_updatesSameTokenWithoutDuplicatingIt() public {
        _deliver(_record("ETH", 1e11, 100, 1_700_000_000));
        _deliver(_record("ETH", 2e11, 150, 1_700_000_600));

        assertEq(snap.tokenCount(), 1);
        assertEq(snap.snapshotCount(), 2);
        assertEq(snap.getSnapshot("ETH").price, 2e11);
        assertEq(snap.getSnapshot("ETH").blockNumber, 150);
    }

    function test_getSnapshot_returnsZeroRecordForUnknownToken() public view {
        ISnapshot.Record memory stored = snap.getSnapshot("NOPE");
        assertEq(stored.price, 0);
        assertEq(stored.timestamp, 0);
        assertEq(bytes(stored.token).length, 0);
    }

    // ----- replay / validation --------------------------------------------

    function test_onReport_rejectsReplayOfOlderRecord() public {
        _deliver(_record("ETH", 2e11, 150, 1_700_000_600));

        ISnapshot.Record memory stale = _record("ETH", 1e11, 100, 1_700_000_000);
        vm.prank(FORWARDER);
        vm.expectRevert(abi.encodeWithSelector(PriceSnapshot.StaleSnapshot.selector, 100, 150));
        snap.onReport(
            _metadata64(WORKFLOW_ID, bytes10(0), WORKFLOW_OWNER, bytes2(0)), _report(stale)
        );

        assertEq(snap.getSnapshot("ETH").price, 2e11);
    }

    function test_onReport_rejectsResubmissionOfSameBlock() public {
        ISnapshot.Record memory record = _record("ETH", 2e11, 150, 1_700_000_600);
        _deliver(record);

        vm.prank(FORWARDER);
        vm.expectRevert(abi.encodeWithSelector(PriceSnapshot.StaleSnapshot.selector, 150, 150));
        snap.onReport(
            _metadata64(WORKFLOW_ID, bytes10(0), WORKFLOW_OWNER, bytes2(0)), _report(record)
        );
    }

    function test_onReport_rejectsEmptyToken() public {
        vm.prank(FORWARDER);
        vm.expectRevert(PriceSnapshot.EmptyToken.selector);
        snap.onReport(
            _metadata64(WORKFLOW_ID, bytes10(0), WORKFLOW_OWNER, bytes2(0)),
            _report(_record("", 1e11, 100, 1_700_000_000))
        );
    }

    function test_onReport_rejectsZeroPrice() public {
        vm.prank(FORWARDER);
        vm.expectRevert(PriceSnapshot.ZeroPrice.selector);
        snap.onReport(
            _metadata64(WORKFLOW_ID, bytes10(0), WORKFLOW_OWNER, bytes2(0)),
            _report(_record("ETH", 0, 100, 1_700_000_000))
        );
    }

    // ----- optional workflow identity checks ------------------------------

    function test_onReport_enforcesExpectedWorkflowOwner() public {
        vm.prank(OWNER);
        snap.setExpectedWorkflowOwner(WORKFLOW_OWNER);

        _deliver(_record("ETH", 1e11, 100, 1_700_000_000));
        assertEq(snap.snapshotCount(), 1);

        address wrongOwner = address(0x9999);
        vm.prank(FORWARDER);
        vm.expectRevert(
            abi.encodeWithSelector(
                PriceSnapshot.UnauthorizedWorkflowOwner.selector, wrongOwner, WORKFLOW_OWNER
            )
        );
        snap.onReport(
            _metadata64(WORKFLOW_ID, bytes10(0), wrongOwner, bytes2(0)),
            _report(_record("ETH", 2e11, 200, 1_700_000_100))
        );
    }

    function test_onReport_enforcesExpectedWorkflowName() public {
        bytes10 name = snap.encodeWorkflowName("price-snapshot-production");

        vm.startPrank(OWNER);
        snap.setExpectedWorkflowOwner(WORKFLOW_OWNER);
        snap.setExpectedWorkflowName(name);
        vm.stopPrank();

        vm.prank(FORWARDER);
        snap.onReport(
            _metadata64(WORKFLOW_ID, name, WORKFLOW_OWNER, bytes2(0)),
            _report(_record("ETH", 1e11, 100, 1_700_000_000))
        );
        assertEq(snap.snapshotCount(), 1);

        bytes10 otherName = snap.encodeWorkflowName("some-other-workflow");
        vm.prank(FORWARDER);
        vm.expectRevert(
            abi.encodeWithSelector(
                PriceSnapshot.UnauthorizedWorkflowName.selector, otherName, name
            )
        );
        snap.onReport(
            _metadata64(WORKFLOW_ID, otherName, WORKFLOW_OWNER, bytes2(0)),
            _report(_record("ETH", 2e11, 200, 1_700_000_100))
        );
    }

    function test_onReport_workflowNameRequiresOwnerCheck() public {
        // Resolve the encoded name before pranking: `encodeWorkflowName` is an
        // external call and would otherwise consume the prank.
        bytes10 name = snap.encodeWorkflowName("price-snapshot-production");
        vm.prank(OWNER);
        snap.setExpectedWorkflowName(name);

        vm.prank(FORWARDER);
        vm.expectRevert(PriceSnapshot.WorkflowNameRequiresOwnerCheck.selector);
        snap.onReport(
            _metadata64(WORKFLOW_ID, bytes10(0), WORKFLOW_OWNER, bytes2(0)),
            _report(_record("ETH", 1e11, 100, 1_700_000_000))
        );
    }

    /// @dev With both identity checks off, metadata is never decoded, which is
    ///      what lets the MockKeystoneForwarder (no metadata) work in simulation.
    function test_onReport_ignoresMetadataWhenChecksDisabled() public {
        vm.prank(FORWARDER);
        snap.onReport("", _report(_record("ETH", 1e11, 100, 1_700_000_000)));
        assertEq(snap.snapshotCount(), 1);
    }

    function test_onReport_rejectsBadMetadataLengthWhenChecksEnabled() public {
        vm.prank(OWNER);
        snap.setExpectedWorkflowOwner(WORKFLOW_OWNER);

        vm.prank(FORWARDER);
        vm.expectRevert(abi.encodeWithSelector(PriceSnapshot.InvalidMetadataLength.selector, 0));
        snap.onReport("", _report(_record("ETH", 1e11, 100, 1_700_000_000)));
    }

    function test_decodeMetadata() public view {
        bytes10 name = snap.encodeWorkflowName("price-snapshot-production");
        (bytes32 id, bytes10 decodedName, address workflowOwner) =
            snap.decodeMetadata(_metadata64(WORKFLOW_ID, name, WORKFLOW_OWNER, 0x1234));

        assertEq(id, WORKFLOW_ID);
        assertEq(decodedName, name);
        assertEq(workflowOwner, WORKFLOW_OWNER);
    }

    /// @dev sha256("my_workflow") -> "b76f3ae1de..." -> first 10 ASCII chars.
    function test_encodeWorkflowName_matchesCreEngine() public view {
        assertEq(snap.encodeWorkflowName("my_workflow"), bytes10(hex"62373666336165316465"));
        assertEq(snap.encodeWorkflowName(""), bytes10(0));
    }

    // ----- administration --------------------------------------------------

    function test_setForwarder_onlyOwner() public {
        vm.prank(ATTACKER);
        vm.expectRevert(abi.encodeWithSelector(PriceSnapshot.NotOwner.selector, ATTACKER));
        snap.setForwarder(OTHER_FORWARDER);

        vm.prank(OWNER);
        snap.setForwarder(OTHER_FORWARDER);
        assertEq(snap.forwarder(), OTHER_FORWARDER);
    }

    /// @dev Zeroing the forwarder would disable the check entirely, so it is
    ///      rejected rather than merely discouraged.
    function test_setForwarder_rejectsZero() public {
        vm.prank(OWNER);
        vm.expectRevert(PriceSnapshot.ZeroAddress.selector);
        snap.setForwarder(address(0));
    }

    function test_setExpectedWorkflowOwner_onlyOwner() public {
        vm.prank(ATTACKER);
        vm.expectRevert(abi.encodeWithSelector(PriceSnapshot.NotOwner.selector, ATTACKER));
        snap.setExpectedWorkflowOwner(WORKFLOW_OWNER);
    }

    function test_setExpectedWorkflowName_onlyOwner() public {
        vm.prank(ATTACKER);
        vm.expectRevert(abi.encodeWithSelector(PriceSnapshot.NotOwner.selector, ATTACKER));
        snap.setExpectedWorkflowName(bytes10("x"));
    }

    function test_transferOwnership() public {
        vm.prank(OWNER);
        snap.transferOwnership(ATTACKER);
        assertEq(snap.owner(), ATTACKER);

        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(PriceSnapshot.NotOwner.selector, OWNER));
        snap.setForwarder(OTHER_FORWARDER);
    }

    function test_transferOwnership_rejectsZero() public {
        vm.prank(OWNER);
        vm.expectRevert(PriceSnapshot.ZeroAddress.selector);
        snap.transferOwnership(address(0));
    }

    // ----- report encoding -------------------------------------------------

    /// @dev Pins the report layout the workflow produces with viem's
    ///      `encodeAbiParameters` on a single tuple parameter. If this changes,
    ///      `abi.decode(report, (Record))` in `onReport` breaks.
    function test_reportEncoding_matchesWorkflowOutput() public pure {
        ISnapshot.Record memory record =
            _record("ETH", 269_574_660_667, 11_857_693, 1_791_312_240);

        bytes memory expected =
            hex"0000000000000000000000000000000000000000000000000000000000000020"
            hex"0000000000000000000000000000000000000000000000000000000000000080"
            hex"0000000000000000000000000000000000000000000000000000003ec3e6e23b"
            hex"0000000000000000000000000000000000000000000000000000000000b4ef1d"
            hex"000000000000000000000000000000000000000000000000000000006ac54170"
            hex"0000000000000000000000000000000000000000000000000000000000000003"
            hex"4554480000000000000000000000000000000000000000000000000000000000";

        assertEq(abi.encode(record), expected);
    }
}
