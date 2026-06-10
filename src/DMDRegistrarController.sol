// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.25;

import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import { DateTimeLib } from "solady/utils/DateTimeLib.sol";

import { ValueGuards } from "diamond-contracts-core/lib/ValueGuards.sol";

import { IDMDNames } from "./interface/IDMDNames.sol";
import { IENS } from "./interface/IENS.sol";
import { IResolver } from "./interface/IResolver.sol";
import { ByteUtils } from "./lib/ByteUtils.sol";
import { Errors } from "./lib/Errors.sol";
import { TransferUtils } from "./lib/TransferUtils.sol";

contract DMDRegistrarController is Initializable, OwnableUpgradeable, ValueGuards {
    using ByteUtils for bytes1;

    // keccak256(abi.encodePacked(bytes32(0), keccak256("dmd")))
    bytes32 public constant DMD_NODE = 0x9904bf4b5751e3b6a8b75d14c49424160de1a8fa8a90fd5c9fccdeac0503e612;

    uint256 public constant MIN_NAME_LENGTH = 2;
    uint256 public constant MAX_NAME_LENGHT = 63;

    uint256 public constant DEFAULT_MINTING_FEE = 5 ether;
    uint256 public constant BASE_MINTING_FEE = 78_125_000 gwei; // 0.078125 DMD

    uint256 public constant EXPIRATION_TIME_YEARS = 10;

    /**
     * mapping between address and the current name.
     */
    mapping(address => bytes) public names;

    /**
     * mapping between the hash of the name and the address that owns it
     */
    mapping(bytes32 => address) public namesReverse;

    mapping(address => uint256) public activations;

    IDMDNames public diamondNames;

    IENS public registry;

    IResolver public resolver;

    /**
     * Minting/activation fees are sent to the reinsert pot.
     */
    address public reinsertPotAddress;

    /**
     * current cost for setting the name.
     */
    uint256 public mintingFee;

    error InvalidMintingFee(uint256 want, uint256 sent);
    error InvalidName();
    error NotAvailable();
    error RegistrarInactive();

    event NameRegistered(address indexed node, bytes32 indexed nameHash, string name);

    event SetMintingFee(uint256 indexed value);

    modifier activeRegistrar() {
        if (registry.owner(DMD_NODE) != address(this)) {
            revert RegistrarInactive();
        }

        _;
    }

    /**
     * @custom:oz-upgrades-unsafe-allow constructor
     */
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _initialOwner,
        address _reinsertPotAddress,
        address _diamondNames,
        address _registry,
        address _resolver
    ) external initializer {
        if (_reinsertPotAddress == address(0)) {
            revert Errors.InvalidReinsertPotAddress();
        }

        if (_diamondNames == address(0)) {
            revert Errors.InvalidNamesContract();
        }

        if (_registry == address(0)) {
            revert Errors.InvalidRegistry();
        }

        if (_resolver == address(0)) {
            revert Errors.InvalidResolver();
        }

        __Ownable_init(_initialOwner);

        diamondNames = IDMDNames(_diamondNames);
        registry = IENS(_registry);
        resolver = IResolver(_resolver);
        reinsertPotAddress = _reinsertPotAddress;

        mintingFee = DEFAULT_MINTING_FEE;

        __initAllowedChangeableParameter(
            this.setMintingFee.selector, this.mintingFee.selector, _mintingFeeAllowedValues()
        );
    }

    function setMintingFee(uint256 _value) public onlyOwner withinAllowedRange(_value) {
        mintingFee = _value;

        emit SetMintingFee(_value);
    }

    function register(string calldata _name) external payable activeRegistrar {
        if (msg.value != mintingFee) {
            revert InvalidMintingFee(mintingFee, msg.value);
        }

        if (!valid(_name)) {
            revert InvalidName();
        }

        if (!available(_name)) {
            revert NotAvailable();
        }

        bytes32 labelHash = getHashOfName(_name);
        uint256 labelId = uint256(labelHash);
        bytes32 node = keccak256(abi.encodePacked(DMD_NODE, labelHash));

        bytes storage originalString = names[msg.sender];

        // if there is already a name stored, we can delete it.
        if (originalString.length != 0) {
            bytes32 original_nameHash = getHashOfNameBytes(originalString);
            delete namesReverse[original_nameHash];
        }

        names[msg.sender] = bytes(_name);
        namesReverse[labelHash] = msg.sender;

        uint256 expirationTimestamp = DateTimeLib.addYears(block.timestamp, EXPIRATION_TIME_YEARS);

        diamondNames.register(labelId, msg.sender, expirationTimestamp);

        registry.setSubnodeRecord(DMD_NODE, labelHash, address(this), address(resolver), 0);
        resolver.setAddr(node, msg.sender);
        registry.setOwner(node, msg.sender);

        TransferUtils.transferNative(reinsertPotAddress, msg.value);

        emit NameRegistered(msg.sender, labelHash, _name);
    }

    function activate() external activeRegistrar { }

    function getAddressOfName(string calldata _name) external view returns (address) {
        bytes32 nameHash = getHashOfName(_name);
        return namesReverse[nameHash];
    }

    function name(address node) external view returns (string memory) {
        return string(names[node]);
    }

    function available(string calldata _name) public view returns (bool) {
        bytes32 nameHash = getHashOfName(_name);

        // this could also be a hash collison. bad luck, we don't care about this case.
        return namesReverse[nameHash] == address(0);
    }

    function getHashOfName(string calldata _name) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(_name));
    }

    function getHashOfNameBytes(bytes memory _name) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(_name));
    }

    function valid(string calldata _name) public pure returns (bool) {
        bytes memory nameBytes = bytes(_name);
        uint256 byteLength = nameBytes.length;

        // Name length must be in range [MIN_NAME_LENTGH, MAX_NAME_LENGTH]
        if (byteLength < MIN_NAME_LENGTH || byteLength > MAX_NAME_LENGHT) {
            return false;
        }

        // Name must begin and end with alphabetic character or digit
        if (!nameBytes[0].isAlphaNum() || !nameBytes[byteLength - 1].isAlphaNum()) {
            return false;
        }

        for (uint256 i = 1; i < byteLength; ++i) {
            bytes1 previousByte = nameBytes[i - 1];
            bytes1 b = nameBytes[i];

            if (!b.isAlphaNum() && !b.isHyphen()) {
                return false;
            }

            // repeated use of hyphen '-' not allowed
            if (previousByte.isHyphen() && b.isHyphen()) {
                return false;
            }
        }

        return true;
    }

    function _activate(string memory _name) private { }

    function _mintingFeeAllowedValues() private pure returns (uint256[] memory) {
        uint256[] memory values = new uint256[](10);

        values[0] = BASE_MINTING_FEE;

        for (uint256 i = 1; i < values.length; ++i) {
            values[i] = values[i - 1] * 2;
        }

        return values;
    }
}
