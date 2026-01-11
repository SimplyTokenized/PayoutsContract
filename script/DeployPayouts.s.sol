// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {Script, console} from "forge-std/Script.sol";
import {PayoutsContract} from "../src/PayoutsContract.sol";
import {Upgrades} from "@openzeppelin-foundry-upgrades/Upgrades.sol";

/**
 * @title DeployPayouts
 * @dev Deployment script for PayoutsContract with proxy
 */
contract DeployPayouts is Script {
    function run() public returns (PayoutsContract payouts) {
        vm.startBroadcast();

        // Get deployment parameters from environment
        address baseToken = vm.envAddress("BASE_TOKEN");
        address admin = vm.envAddress("ADMIN");

        console.log("Deploying PayoutsContract with proxy...");
        console.log("Base Token:", baseToken);
        console.log("Admin:", admin);

        // Deploy transparent proxy
        address proxyAddress = Upgrades.deployTransparentProxy(
            "PayoutsContract.sol",
            admin, // Proxy admin
            abi.encodeCall(
                PayoutsContract.initialize,
                (baseToken, admin)
            )
        );

        payouts = PayoutsContract(payable(proxyAddress));

        console.log("PayoutsContract deployed at:", proxyAddress);
        address implementationAddress = Upgrades.getImplementationAddress(proxyAddress);
        console.log("Implementation address:", implementationAddress);

        vm.stopBroadcast();
    }
}
