// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.25;

import { Script } from "forge-std/Script.sol";

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Upgrades } from "openzeppelin-foundry-upgrades/Upgrades.sol";

import { DMDNames } from "src/DMDNames.sol";
import { DMDRegistrarController } from "src/DMDRegistrarController.sol";
import { DMDRegistry } from "src/DMDRegistry.sol";
import { DMDResolver } from "src/DMDResolver.sol";

contract Deploy is Script {
    struct DeploymentConfig {
        address initialOwner;
        address reinsertPot;
        address dao;
        string baseUri;
    }

    bytes32 public constant ROOT_NODE = bytes32(0);
    bytes32 public constant DMD_LABEL = keccak256("dmd");

    function run() external {
        address initialOwner = vm.envAddress("INITIAL_OWNER_ADDRESS"); // root owner
        address reinsertPot = vm.envAddress("REINSERT_POT_ADDRESS");
        address dao = vm.envAddress("DAO_ADDRESS");
        string memory baseUri = vm.envString("METADATA_BASE_URI");

        bool release = vm.envOr("RELEASE", false);

        DeploymentConfig memory config =
            DeploymentConfig({ initialOwner: initialOwner, reinsertPot: reinsertPot, dao: dao, baseUri: baseUri });

        deploy(config, release);
    }

    function deploy(DeploymentConfig memory cfg, bool release) public {
        vm.startBroadcast();

        address proxyAdminOwner = cfg.initialOwner;
        if (release) {
            proxyAdminOwner = cfg.dao;
        }

        DMDRegistry registry = DMDRegistry(
            Upgrades.deployTransparentProxy(
                "DMDRegistry.sol:DMDRegistry",
                proxyAdminOwner,
                abi.encodeCall(DMDRegistry.initialize, (cfg.initialOwner))
            )
        );

        DMDNames names = DMDNames(
            Upgrades.deployTransparentProxy(
                "DMDNames.sol:DMDNames",
                proxyAdminOwner,
                abi.encodeCall(DMDNames.initialize, (cfg.initialOwner, cfg.baseUri))
            )
        );

        DMDResolver resolver = DMDResolver(
            Upgrades.deployTransparentProxy(
                "DMDResolver.sol:DMDResolver",
                proxyAdminOwner,
                abi.encodeCall(DMDResolver.initialize, (address(registry)))
            )
        );

        DMDRegistrarController controller = DMDRegistrarController(
            Upgrades.deployTransparentProxy(
                "DMDRegistrarController.sol:DMDRegistrarController",
                proxyAdminOwner,
                abi.encodeCall(
                    DMDRegistrarController.initialize,
                    (cfg.initialOwner, cfg.reinsertPot, address(names), address(registry), address(resolver))
                )
            )
        );

        names.setController(address(controller), true);

        registry.setSubnodeOwner(ROOT_NODE, DMD_LABEL, address(controller));

        if (release) {
            registry.setOwner(ROOT_NODE, cfg.dao);

            Ownable(address(names)).transferOwnership(cfg.dao);
            Ownable(address(controller)).transferOwnership(cfg.dao);
        }

        vm.stopBroadcast();
    }
}
