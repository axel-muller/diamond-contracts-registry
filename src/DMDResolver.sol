// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.25;

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { ERC165Upgradeable } from "@openzeppelin/contracts-upgradeable/utils/introspection/ERC165Upgradeable.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import { IAddrResolver } from "./interface/IAddrResolver.sol";
import { IENS } from "./interface/IENS.sol";
import { IExtendedResolver } from "./interface/IExtendedResolver.sol";
import { INameResolver } from "./interface/INameResolver.sol";
import { IResolver } from "./interface/IResolver.sol";

import { Errors } from "./lib/Errors.sol";

/// @notice ENS-compatible resolver that stores the records of the DMD naming
/// system for forward (node -> address) and reverse (node -> name) resolution.
contract DMDResolver is Initializable, ERC165Upgradeable, IResolver, IExtendedResolver {
    IENS public registry;

    /// @notice Forward records: node namehash -> resolved address.
    mapping(bytes32 => address) public addresses;

    /// @notice Reverse records: node namehash -> human-readable name.
    mapping(bytes32 => string) public names;

    /// @notice Thrown when `resolve` is called with an unsupported selector.
    error UnsupportedResolverFunc(bytes4 selector);

    /// @dev Restricts a write to the owner of `node` or one of its approved operators
    /// @param node The node whose record is being written.
    modifier authorised(bytes32 node) {
        address owner = registry.owner(node);

        if (msg.sender != owner && !registry.isApprovedForAll(owner, msg.sender)) {
            revert Errors.Unauthorised();
        }
        _;
    }

    /// @dev Prevents initialization of the implementation contract.
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the resolver contract.
    /// @param _registry The address of the {DMDRegistry}.
    function initialize(address _registry) external initializer {
        if (_registry == address(0)) {
            revert Errors.InvalidRegistry();
        }

        __ERC165_init();

        registry = IENS(_registry);
    }

    /// @notice Sets the forward (address) record for a node.
    /// @param node The node to update
    /// @param a The address the node resolves to
    function setAddr(bytes32 node, address a) external authorised(node) {
        addresses[node] = a;

        emit AddrChanged(node, a);
    }

    /// @notice Sets the reverse (name) record for a node.
    /// @param node The reverse node to update - namehash(`<hexaddr>.addr.reverse`)
    /// @param newName The human-readable name the node resolves to
    function setName(bytes32 node, string calldata newName) external authorised(node) {
        names[node] = newName;

        emit NameChanged(node, newName);
    }

    /// @notice Returns the address a node resolves to.
    /// @param node The node to query
    /// @return The resolved address, address(0) otherwise
    function addr(bytes32 node) external view override returns (address payable) {
        return payable(addresses[node]);
    }

    /// @notice Returns the name a node resolves to.
    /// @param node The reverse node to query
    /// @return The resolved name, empty string otherwise
    function name(bytes32 node) external view override returns (string memory) {
        return names[node];
    }

    /// @notice Resolves an ABI-encoded resolver call for a DNS-encoded name (ENSIP-10).
    /// @param data The ABI-encoded inner resolver call (e.g. `addr(bytes32)`).
    /// @return The ABI-encoded result of the inner call.
    function resolve(bytes calldata, bytes calldata data) external view override returns (bytes memory) {
        bytes4 selector = bytes4(data);
        if (selector != IAddrResolver.addr.selector && selector != INameResolver.name.selector) {
            revert UnsupportedResolverFunc(selector);
        }

        // 4 bytes selector + 32 bytes hash
        if (data.length != 36) {
            revert UnsupportedResolverFunc(selector);
        }

        (bool success, bytes memory result) = address(this).staticcall(data);

        if (success) {
            return result;
        } else {
            // Revert with the reason provided by the call
            assembly ("memory-safe") {
                revert(add(result, 0x20), mload(result))
            }
        }
    }

    /// @inheritdoc ERC165Upgradeable
    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(ERC165Upgradeable, IERC165)
        returns (bool)
    {
        return interfaceId == type(IAddrResolver).interfaceId || interfaceId == type(INameResolver).interfaceId
            || interfaceId == type(IExtendedResolver).interfaceId || super.supportsInterface(interfaceId);
    }
}
