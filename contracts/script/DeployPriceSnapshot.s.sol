// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {PriceSnapshot} from "../src/PriceSnapshot.sol";

/// @notice Deploys `PriceSnapshot` with the forwarder it should trust.
/// @dev Reads `FORWARDER_ADDRESS` from the environment. Use the Ethereum
///      Sepolia MockKeystoneForwarder to exercise the contract with
///      `cre workflow simulate --broadcast`, or the production KeystoneForwarder
///      for a deployed workflow. See the README for both addresses.
contract DeployPriceSnapshot is Script {
    function run() external returns (PriceSnapshot snapshot) {
        address forwarder = vm.envAddress("FORWARDER_ADDRESS");

        vm.startBroadcast();
        snapshot = new PriceSnapshot(forwarder);
        vm.stopBroadcast();

        console2.log("PriceSnapshot deployed at:", address(snapshot));
        console2.log("Trusted forwarder:        ", forwarder);
        console2.log("Owner:                    ", snapshot.owner());
    }
}
