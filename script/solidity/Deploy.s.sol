// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.25;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Options, Upgrades } from "openzeppelin-foundry-upgrades/Upgrades.sol";

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

    uint256 public constant MINTING_FEE = 5 ether;
    bytes32 public constant ROOT_NODE = bytes32(0);
    bytes32 public constant DMD_LABEL = keccak256("dmd");
    bytes32 public constant REVERSE_LABEL = keccak256("reverse");
    bytes32 public constant ADDR_LABEL = keccak256("addr");
    bytes32 public constant REVERSE_NODE = keccak256(abi.encodePacked(ROOT_NODE, REVERSE_LABEL));

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
        uint256 initialTransferFee = MINTING_FEE / 10;

        Options memory opts;

        address proxyAdminOwner = cfg.initialOwner;
        if (release) {
            proxyAdminOwner = cfg.dao;
        }

        opts.unsafeSkipProxyAdminCheck = true;

        vm.startBroadcast();

        DMDRegistry registry = DMDRegistry(
            Upgrades.deployTransparentProxy(
                "DMDRegistry.sol:DMDRegistry",
                proxyAdminOwner,
                abi.encodeCall(DMDRegistry.initialize, (cfg.initialOwner)),
                opts
            )
        );

        DMDNames names = DMDNames(
            Upgrades.deployTransparentProxy(
                "DMDNames.sol:DMDNames",
                proxyAdminOwner,
                abi.encodeCall(
                    DMDNames.initialize, (cfg.initialOwner, cfg.reinsertPot, initialTransferFee, cfg.baseUri)
                ),
                opts
            )
        );

        DMDResolver resolver = DMDResolver(
            Upgrades.deployTransparentProxy(
                "DMDResolver.sol:DMDResolver",
                proxyAdminOwner,
                abi.encodeCall(DMDResolver.initialize, (address(registry))),
                opts
            )
        );

        DMDRegistrarController controller = DMDRegistrarController(
            Upgrades.deployTransparentProxy(
                "DMDRegistrarController.sol:DMDRegistrarController",
                proxyAdminOwner,
                abi.encodeCall(
                    DMDRegistrarController.initialize,
                    (cfg.initialOwner, cfg.reinsertPot, address(names), address(registry), address(resolver))
                ),
                opts
            )
        );

        names.setRegistrar(address(controller));

        // Setup .dmd TLD
        registry.setSubnodeOwner(ROOT_NODE, DMD_LABEL, address(controller));

        // Setup addr.reverse
        registry.setSubnodeOwner(ROOT_NODE, REVERSE_LABEL, cfg.initialOwner);
        registry.setSubnodeOwner(REVERSE_NODE, ADDR_LABEL, address(controller));

        if (release) {
            registry.setSubnodeOwner(ROOT_NODE, REVERSE_LABEL, cfg.dao);
            registry.setOwner(ROOT_NODE, cfg.dao);

            Ownable(address(names)).transferOwnership(cfg.dao);
            Ownable(address(controller)).transferOwnership(cfg.dao);
        }

        vm.stopBroadcast();

        console.log("Registrar: %s", address(controller));
        console.log("Names    : %s", address(names));
        console.log("Registry : %s", address(registry));
        console.log("Resolver : %s", address(resolver));
    }
}
