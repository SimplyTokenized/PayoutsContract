// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {Script, console} from "forge-std/Script.sol";
import {PayoutsContract} from "../src/PayoutsContract.sol";
import {Upgrades} from "@openzeppelin-foundry-upgrades/Upgrades.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/**
 * @title DeployPayouts
 * @dev Deploys one PayoutsContract behind a transparent proxy.
 *
 * @notice One deployment serves a whole tenant: the payout asset is chosen per
 * distribution, so a second contract is never needed for a second offering or a second
 * token. In production this contract is deployed by the platform's own reserve/confirm
 * flow, which records the addresses against the tenant; this script covers local runs,
 * testnets, and anything deployed by hand.
 *
 * Environment:
 *   ADMIN                - operates, funds and guards payouts (required)
 *   APPROVER             - the second pair of eyes; MUST differ from ADMIN (required)
 *   PROXY_ADMIN_OWNER    - upgrade authority; defaults to ADMIN if unset
 *   UPGRADE_TIMELOCK_DELAY - seconds; when set, a TimelockController with this minimum
 *                          delay is deployed and made the upgrade authority, so every
 *                          upgrade is scheduled on-chain — publicly visible — before it
 *                          can execute. PROXY_ADMIN_OWNER becomes its proposer/executor.
 *   TRUSTED_FORWARDER    - ERC-2771 forwarder for gasless claiming; omit for recipient-pays
 */
contract DeployPayouts is Script {
    function run() public returns (PayoutsContract payouts) {
        address admin = vm.envAddress("ADMIN");
        address approver = vm.envAddress("APPROVER");
        address proxyAdminOwner = vm.envOr("PROXY_ADMIN_OWNER", admin);
        uint256 timelockDelay = vm.envOr("UPGRADE_TIMELOCK_DELAY", uint256(0));
        address trustedForwarder = vm.envOr("TRUSTED_FORWARDER", address(0));

        require(admin != address(0), "DeployPayouts: ADMIN is required");
        require(approver != address(0) && approver != admin, "DeployPayouts: APPROVER must differ from ADMIN");

        console.log("Admin (operates, funds, guards):", admin);
        console.log("Approver (second pair of eyes):", approver);
        console.log(
            trustedForwarder == address(0)
                ? "Gas model: recipient pays to claim"
                : "Gas model: gasless claiming via trusted forwarder"
        );
        if (trustedForwarder != address(0)) {
            console.log("Trusted forwarder:", trustedForwarder);
        }

        vm.startBroadcast();

        address upgradeAuthority = proxyAdminOwner;
        if (timelockDelay > 0) {
            address[] memory controllers = new address[](1);
            controllers[0] = proxyAdminOwner;
            // No optional admin: the timelock governs itself, so even changing its own
            // rules takes the delay.
            TimelockController timelock = new TimelockController(timelockDelay, controllers, controllers, address(0));
            upgradeAuthority = address(timelock);
            console.log("Upgrade timelock:", upgradeAuthority);
            console.log("Upgrade delay (seconds):", timelockDelay);
        }

        address proxy = Upgrades.deployTransparentProxy(
            "PayoutsContract.sol",
            upgradeAuthority,
            abi.encodeCall(PayoutsContract.initialize, (admin, approver, trustedForwarder))
        );

        vm.stopBroadcast();

        payouts = PayoutsContract(payable(proxy));

        console.log("PayoutsContract (proxy):", proxy);
        console.log("Implementation:", Upgrades.getImplementationAddress(proxy));
        console.log("Upgrade authority (ProxyAdmin owner):", upgradeAuthority);
    }
}
