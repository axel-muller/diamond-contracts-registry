// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.25;

import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import { DateTimeLib } from "solady/utils/DateTimeLib.sol";
import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";

import { ValueGuards } from "diamond-contracts-core/lib/ValueGuards.sol";

import { IDMDNames } from "./interface/IDMDNames.sol";
import { IDMDRegistrarController } from "./interface/IDMDRegistrarController.sol";
import { IENS } from "./interface/IENS.sol";
import { IResolver } from "./interface/IResolver.sol";
import { AddressUtils } from "./lib/AddressUtils.sol";
import { ByteUtils } from "./lib/ByteUtils.sol";
import { Errors } from "./lib/Errors.sol";
import { NameBlocklist } from "./lib/NameBlocklist.sol";
import { NameUtils } from "./lib/NameUtils.sol";
import { TransferUtils } from "./lib/TransferUtils.sol";

/// @dev A registrar controller for registering, activating and renewing names.
contract DMDRegistrarController is
    Initializable,
    OwnableUpgradeable,
    NameBlocklist,
    ValueGuards,
    IDMDRegistrarController
{
    using ByteUtils for bytes1;

    /// @notice DMD top-level domain suffix.
    string public constant DMD_TLD = ".dmd";

    uint256 public constant MIN_NAME_LENGTH = 2;
    uint256 public constant MAX_NAME_LENGTH = 63;

    uint256 public constant DEFAULT_MINTING_FEE = 5 ether;
    uint256 public constant BASE_MINTING_FEE = 78_125_000 gwei; // 0.078125 DMD

    /// @notice Registration/renewal term length in years.
    uint256 public constant EXPIRATION_TIME_YEARS = 10;

    /// @notice Maximum numerator for the activation fee (3+ activations = 30% if minting fee).
    uint256 public constant MAX_ACTIVATION_FEE_NUMERATOR = 3;
    uint256 public constant ACTIVATION_FEE_DENOMINATOR = 10;

    uint256 public constant TRANSFER_FEE_NUMERATOR = 10; // 10%
    uint256 public constant TRANSFER_FEE_DENOMINATOR = 100;

    /// @notice Active name per address.
    mapping(address => bytes) public names;

    /// @notice Reverse index from a name's label hash to the address.
    mapping(bytes32 => address) public namesReverse;

    /// @notice Number of activations done by an address.
    mapping(address => uint256) public activations;

    /// @notice The ERC-721 name token contract.
    IDMDNames public diamondNames;

    /// @notice The ENS-compatible registry.
    IENS public registry;

    /// @notice The ENS-compatible resolver.
    IResolver public resolver;

    /// @notice Minting and activation fees collector address.
    address public reinsertPot;

    /// @notice Current cost to register a name.
    uint256 public mintingFee;

    /// @notice Thrown when `register` is called with an incorrect fee.
    error InvalidMintingFee(uint256 want, uint256 sent);
    /// @notice Thrown when a name fails validation rules.
    error InvalidName();
    /// @notice Thrown when registering a name that is already taken.
    error NotAvailable();
    /// @notice Thrown when activating an expired name.
    error NameExpired();
    /// @notice Thrown if current registrar controller is inactive.
    error RegistrarInactive();
    /// @notice Thrown when the expected owner does not match the active registrant.
    error NameOwnerMismatch(address expected, address actual);
    /// @notice Thrown when the caller does not own the name token.
    error NotNameOwner();
    /// @notice Thrown when `activate` is called with an incorrect fee.
    error InvalidActivationFee(uint256 want, uint256 sent);
    /// @notice Thrown when activating a name that is already the caller's primary.
    error AlreadyActive();

    /// @notice Emitted when a name is registered.
    event NameRegistered(address indexed node, bytes32 indexed labelHash, uint256 indexed expiration, string name);

    /// @notice Emitted when a name was activated as primary.
    event NameActivated(address indexed owner, bytes32 indexed labelHash, string name);

    /// @notice Emitted when a name's records are cleared.
    event NameDeactivated(address indexed owner, bytes32 indexed labelHash, string name);

    /// @notice Emitted when a name's registration term is extended.
    event NameRenewed(address indexed owner, bytes32 indexed labelHash, uint256 indexed expiration, string name);

    /// @notice Emitted when name was blocked by governance voting.
    event NameModerated(address indexed owmer, bytes32 indexed labelHash, string reason, string note);

    /// @notice Emitted when the minting fee is updated.
    event SetMintingFee(uint256 indexed value);

    /// @dev Reverts unless the controller currently owns the `.dmd` node.
    modifier activeRegistrar() {
        _checkRegistrar();
        _;
    }

    modifier notBlocked(string memory _name) {
        _checkNameBlock(_name);
        _;
    }

    /// @notice Prevents initialization of the implementation contract.
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the controller.
    /// @param _initialOwner The owner of the contract
    /// @param _reinsertPot Fee collector address
    /// @param _diamondNames The ERC-721 name token contract
    /// @param _registry The ENS-compatible registry
    /// @param _resolver The ENS-compatible resolver
    function initialize(
        address _initialOwner,
        address _reinsertPot,
        address _diamondNames,
        address _registry,
        address _resolver
    ) external initializer {
        if (_reinsertPot == address(0)) {
            revert Errors.InvalidReinsertPot();
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
        __NameBlocklist_init();

        diamondNames = IDMDNames(_diamondNames);
        registry = IENS(_registry);
        resolver = IResolver(_resolver);
        reinsertPot = _reinsertPot;

        mintingFee = DEFAULT_MINTING_FEE;

        __initAllowedChangeableParameter(
            this.setMintingFee.selector, this.mintingFee.selector, _mintingFeeAllowedValues()
        );
    }

    /// @notice Updates the minting and token transfer fee.
    /// @dev Restricted to the owner; the value must be within the allowed range.
    /// @param _value The new minting fee
    function setMintingFee(uint256 _value) public onlyOwner withinAllowedRange(_value) {
        uint256 transferFee = _value * TRANSFER_FEE_NUMERATOR / TRANSFER_FEE_DENOMINATOR;

        mintingFee = _value;

        emit SetMintingFee(_value);

        diamondNames.setTransferFee(transferFee);
    }

    /// @notice Blocks a name and deactivates it if it is currently active.
    /// @param _name The name to block
    /// @param _owner Current active registrant of the name
    function moderateName(
        address _owner,
        string calldata _name,
        string calldata reason,
        string calldata notes
    ) external activeRegistrar onlyOwner {
        bytes32 labelHash = NameUtils.labelHash(_name);
        address registrant = namesReverse[labelHash];

        if (registrant != _owner) {
            revert NameOwnerMismatch(registrant, _owner);
        }

        if (registrant != address(0)) {
            _deactivateName(registrant, bytes(_name));
        }

        _setNameBlocked(_name, true);

        emit NameModerated(_owner, labelHash, reason, notes);
    }

    /// @notice Registers a `.dmd` name, minting its token to the caller.
    /// @param _name The label to register (without the `.dmd` suffix)
    function register(string calldata _name) external payable activeRegistrar notBlocked(_name) {
        if (msg.value != mintingFee) {
            revert InvalidMintingFee(mintingFee, msg.value);
        }

        if (!valid(_name)) {
            revert InvalidName();
        }

        if (!available(_name)) {
            revert NotAvailable();
        }

        bytes32 labelHash = NameUtils.labelHash(_name);
        uint256 tokenId = uint256(labelHash);

        if (diamondNames.exists(tokenId)) {
            _resetExpiredName(labelHash, bytes(_name));
            diamondNames.burn(tokenId);
        }

        uint256 expirationTimestamp = DateTimeLib.addYears(block.timestamp, EXPIRATION_TIME_YEARS);

        diamondNames.register(tokenId, msg.sender, expirationTimestamp);

        if (names[msg.sender].length == 0) {
            _activate(msg.sender, bytes(_name));
        }

        TransferUtils.transferNative(reinsertPot, msg.value);

        emit NameRegistered(msg.sender, labelHash, expirationTimestamp, _name);
    }

    /// @notice Activates a name as the caller's primary name, configures forward/reverse resolver records
    /// The first activation per address is free; subsequent ones cost a fee
    /// @param _name The name to activate (without the `.dmd` suffix)
    function activate(string calldata _name) external payable activeRegistrar notBlocked(_name) {
        bytes32 labelHash = NameUtils.labelHash(_name);
        uint256 tokenId = uint256(labelHash);

        if (diamondNames.ownerOf(tokenId) != msg.sender) {
            revert NotNameOwner();
        }

        if (diamondNames.expired(tokenId)) {
            revert NameExpired();
        }

        bytes memory current = names[msg.sender];
        if (current.length != 0 && NameUtils.labelHash(current) == labelHash) {
            revert AlreadyActive();
        }

        uint256 fee = getActivationFee(msg.sender);
        if (msg.value != fee) {
            revert InvalidActivationFee(fee, msg.value);
        }

        _activate(msg.sender, bytes(_name));

        if (msg.value != 0) {
            TransferUtils.transferNative(reinsertPot, msg.value);
        }
    }

    /// @notice Extends the registration term of an owned name.
    /// @param _name The label to renew (without the `.dmd` suffix)
    function renew(string calldata _name) external activeRegistrar notBlocked(_name) {
        bytes32 labelHash = NameUtils.labelHash(_name);
        uint256 tokenId = uint256(labelHash);

        if (diamondNames.ownerOf(tokenId) != msg.sender) {
            revert NotNameOwner();
        }

        uint256 expirationTimestamp = DateTimeLib.addYears(block.timestamp, EXPIRATION_TIME_YEARS);

        diamondNames.renew(tokenId, expirationTimestamp);

        emit NameRenewed(msg.sender, labelHash, expirationTimestamp, _name);
    }

    /// @notice Returns whether a name can be registered.
    /// A name is available only if it is not blocked and the token is free or expired.
    /// @param _name The label to check (without the `.dmd` suffix)
    /// @return True if the name can be registered
    function available(string calldata _name) public view returns (bool) {
        bytes32 labelHash = NameUtils.labelHash(_name);

        return !isNameBlocked(_name) && diamondNames.available(uint256(labelHash));
    }

    /// @notice Returns the fee an address must pay for its next activation.
    /// Fee scales 10% per prior activation, capped at 30% of the minting fee:
    /// 0 -> free, 1 -> 10%, 2 -> 20%, 3+ -> 30%.
    /// @param _who The address whose next activation fee to get
    /// @return The activation fee in native token
    function getActivationFee(address _who) public view returns (uint256) {
        uint256 numerator = FixedPointMathLib.min(activations[_who], MAX_ACTIVATION_FEE_NUMERATOR);

        return mintingFee * numerator / ACTIVATION_FEE_DENOMINATOR;
    }

    /// @notice Returns the label hash of a name.
    /// @param _name The label (without the `.dmd` suffix)
    /// @return The keccak256 label hash
    function getHashOfName(string memory _name) public pure returns (bytes32) {
        return NameUtils.labelHash(_name);
    }

    /// @notice Validate the name against the current rules.
    /// @param _name The label to validate (without the `.dmd` suffix)
    /// @return True if the name is valid
    function valid(string memory _name) public pure returns (bool) {
        bytes memory nameBytes = bytes(_name);
        uint256 byteLength = nameBytes.length;

        // Name length must be in range [MIN_NAME_LENGTH, MAX_NAME_LENGTH]
        if (byteLength < MIN_NAME_LENGTH || byteLength > MAX_NAME_LENGTH) {
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

    /// @dev Configures forward and reverse records for `_user`'s new primary name,
    /// deactivating any previous primary first.
    /// @param _user The address activating the name
    /// @param _name The label being activated (without the `.dmd` suffix)
    function _activate(address _user, bytes memory _name) private {
        bytes32 labelHash = NameUtils.labelHash(_name);
        bytes32 node = NameUtils.nodeHash(labelHash);

        bytes memory current = names[_user];
        if (current.length != 0) {
            _deactivateName(_user, current);
        }

        names[_user] = _name;
        namesReverse[labelHash] = _user;

        // Forward resolution: name -> address.
        registry.setSubnodeRecord(NameUtils.DMD_NODE, labelHash, address(this), address(resolver), 0);
        resolver.setAddr(node, _user);

        // Reverse resolution: address -> name
        bytes32 reverseLabel = AddressUtils.sha3HexAddress(_user);
        bytes32 reverseNode = AddressUtils.reverseNode(_user);
        registry.setSubnodeRecord(AddressUtils.ADDR_REVERSE_NODE, reverseLabel, address(this), address(resolver), 0);
        resolver.setName(reverseNode, _fullName(_name));

        activations[_user] += 1;

        emit NameActivated(_user, labelHash, string(_name));
    }

    /// @inheritdoc IDMDRegistrarController
    function resetRecordsOnTransfer(address _from, uint256 _tokenId) external override {
        if (msg.sender != address(diamondNames)) {
            revert Errors.Unauthorised();
        }

        bytes32 labelHash = bytes32(_tokenId);

        if (namesReverse[labelHash] == _from) {
            _deactivateName(_from, names[_from]);
        }
    }

    /// @dev Clears the forward and reverse records of `_owner` active name and removes
    /// entries from controller's mapping. The registry node remains owned by the controller.
    /// @param _owner The address whose active name is being cleared.
    /// @param _name The label being deactivated (without the `.dmd` suffix).
    function _deactivateName(address _owner, bytes memory _name) private {
        bytes32 labelHash = NameUtils.labelHash(_name);
        bytes32 node = NameUtils.nodeHash(labelHash);

        resolver.setAddr(node, address(0));
        registry.setResolver(node, address(0));

        bytes32 reverseNode = AddressUtils.reverseNode(_owner);
        resolver.setName(reverseNode, "");
        registry.setResolver(reverseNode, address(0));

        delete names[_owner];
        delete namesReverse[labelHash];

        emit NameDeactivated(_owner, labelHash, string(_name));
    }

    /// @dev Clears any live records of an expired name before it is re-minted, if it is
    /// still recorded as someone's active name.
    /// @param _labelHash The label hash of the expired name
    /// @param _name The label of the expired name (without the `.dmd` suffix)
    function _resetExpiredName(bytes32 _labelHash, bytes memory _name) private {
        address previousOwner = namesReverse[_labelHash];

        if (previousOwner != address(0)) {
            _deactivateName(previousOwner, _name);
        }
    }

    /// @dev Get a fully-qualified name for label (with .dmd suffix).
    /// @param _label The label bytes
    /// @return The fully-qualified name (e.g. `alice.dmd`)
    function _fullName(bytes memory _label) private pure returns (string memory) {
        return string(abi.encodePacked(_label, DMD_TLD));
    }

    /// @dev Reverts unless the controller currently owns the `.dmd` registry node.
    function _checkRegistrar() private view {
        if (registry.owner(NameUtils.DMD_NODE) != address(this)) {
            revert RegistrarInactive();
        }
    }

    function _checkNameBlock(string memory _name) private view {
        if (isNameBlocked(_name)) {
            revert NameBlocked(_name);
        }
    }

    function _mintingFeeAllowedValues() private pure returns (uint256[] memory) {
        uint256[] memory values = new uint256[](10);

        values[0] = BASE_MINTING_FEE;

        for (uint256 i = 1; i < values.length; ++i) {
            values[i] = values[i - 1] * 2;
        }

        return values;
    }
}
