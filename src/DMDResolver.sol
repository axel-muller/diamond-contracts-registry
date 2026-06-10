// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.25;

import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { ERC165Upgradeable } from "@openzeppelin/contracts-upgradeable/utils/introspection/ERC165Upgradeable.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import { IENS } from "./interface/IENS.sol";
import { IAddrResolver, IResolver } from "./interface/IResolver.sol";

import { Errors } from "./lib/Errors.sol";

contract DMDResolver is Initializable, ERC165Upgradeable, IResolver {
    IENS public registry;

    mapping(bytes32 => address) addresses;

    modifier authorised(bytes32 node) {
        address owner = registry.owner(node);

        if (msg.sender != owner && !registry.isApprovedForAll(owner, msg.sender)) {
            revert Errors.Unauthorised();
        }
        _;
    }

    /**
     * @custom:oz-upgrades-unsafe-allow constructor
     */
    constructor() {
        _disableInitializers();
    }

    function initialize(address _registry) external initializer {
        if (_registry == address(0)) {
            revert Errors.InvalidRegistry();
        }

        __ERC165_init();

        registry = IENS(_registry);
    }

    function setAddr(bytes32 node, address a) external authorised(node) {
        addresses[node] = a;

        emit AddrChanged(node, a);
    }

    function addr(bytes32 node) external view override returns (address payable) {
        return payable(addresses[node]);
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(ERC165Upgradeable, IERC165)
        returns (bool)
    {
        return interfaceId == type(IAddrResolver).interfaceId || super.supportsInterface(interfaceId);
    }
}
