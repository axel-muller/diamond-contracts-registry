// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.25;

import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { ERC721Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";

import { Controllable } from "./lib/Controllable.sol";

contract DMDNames is OwnableUpgradeable, ERC721Upgradeable, Controllable {
    string public baseURI;

    mapping(uint256 => uint256) private _expires;

    error NotAvailable(uint256 id);

    /**
     * @custom:oz-upgrades-unsafe-allow constructor
     */
    constructor() {
        _disableInitializers();
    }

    function initialize(address _initialOwner, string calldata _baseUri) external initializer {
        __Ownable_init(_initialOwner);
        __Controllable_init();
        __ERC721_init("DMD Name Service", "DNS");

        baseURI = _baseUri;
    }

    function register(uint256 id, address owner, uint256 expiration) external onlyController {
        _expires[id] = expiration;

        _mint(owner, id);
    }

    function available(uint256 id) public view returns (bool) {
        return _expires[id] < block.timestamp;
    }

    function nameExpires(uint256 id) public view returns (uint256) {
        return _expires[id];
    }

    function _baseURI() internal view override returns (string memory) {
        return baseURI;
    }
}
