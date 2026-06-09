// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.25;

import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import { IENS } from "./interface/IENS.sol";

contract DMDRegistry is Initializable, OwnableUpgradeable, IENS {
    /**
     * @custom:oz-upgrades-unsafe-allow constructor
     */
    constructor() {
        _disableInitializers();
    }

    function initialize(address _initialOwner) external initializer {
        __Ownable_init(_initialOwner);
    }

    function setRecord(bytes32 node, address owner, address resolver, uint64 ttl) external override { }

    function setSubnodeRecord(
        bytes32 node,
        bytes32 label,
        address owner,
        address resolver,
        uint64 ttl
    ) external override { }

    function setSubnodeOwner(bytes32 node, bytes32 label, address owner) external override returns (bytes32) { }

    function setResolver(bytes32 node, address resolver) external override { }

    function setOwner(bytes32 node, address owner) external override { }

    function setTTL(bytes32 node, uint64 ttl) external override { }

    function setApprovalForAll(address operator, bool approved) external override { }

    function owner(bytes32 node) external view override returns (address) { }

    function resolver(bytes32 node) external view override returns (address) { }

    function ttl(bytes32 node) external view override returns (uint64) { }

    function recordExists(bytes32 node) external view override returns (bool) { }

    function isApprovedForAll(address owner, address operator) external view override returns (bool) { }
}
