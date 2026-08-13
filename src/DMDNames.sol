// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.25;

import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import { IDMDRegistrarController } from "./interface/IDMDRegistrarController.sol";
import { ERC721Base } from "./lib/ERC721Base.sol";
import { Errors } from "./lib/Errors.sol";
import { TransferUtils } from "./lib/TransferUtils.sol";

/// @notice Contract represents ownership of a DMD name. Each token id is the
/// label hash of the name uint256(keccak256(label)). The token is a source
/// of truth for name ownership.
contract DMDNames is Initializable, OwnableUpgradeable, ERC721Base {
    /// @notice Transfer fees collector address.
    address public reinsertPot;

    string public baseURI;

    /// @notice Mandatory fee payed for token transfers.
    uint256 public transferFee;

    /// @notice The registrar controller authorised to mint, renew and burn name tokens.
    IDMDRegistrarController public registrar;

    /// @dev Token expiration timestamps.
    mapping(uint256 => uint256) private _expires;

    /// @notice Thrown when attempting to perform an operation on expired token.
    error Expired(uint256 id);

    /// @notice Thrown when a user transfer is sent with invalid fee value.
    error InvalidTransferFee(uint256 expected, uint256 provided);

    /// @notice Emitted when the transfer fee is updated.
    event SetTransferFee(uint256 indexed fee);

    /// @notice Emitted when the registrar address is updated.
    event SetRegistrar(address indexed registrar);

    /// @notice Emitted when metadata URI is updated.
    event SetBaseURI(string _uri);

    /// @notice Emitted when a token's expiration is extended.
    event Renew(uint256 indexed id, uint256 indexed expiration);

    /// @dev Restricts a call to the configured registrar.
    modifier onlyRegistrar() {
        _checkRegistrar();
        _;
    }

    /// @dev Prevents initialization of the implementation contract.
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the name token contract.
    /// @param _initialOwner The owner of the contract
    /// @param _reinsertPot The destination for collected transfer fees
    /// @param _transferFee The initial user transfer fee
    /// @param _baseUri The initial base URI for token metadata
    function initialize(
        address _initialOwner,
        address _reinsertPot,
        uint256 _transferFee,
        string calldata _baseUri
    ) external initializer {
        if (_reinsertPot == address(0)) {
            revert Errors.InvalidReinsertPot();
        }

        __Ownable_init(_initialOwner);
        __ERC721_init("DMD Name Service", "DNS");

        reinsertPot = _reinsertPot;
        baseURI = _baseUri;
        transferFee = _transferFee;
    }

    /// @notice Sets the registrar authorised to mint, renew and burn names.
    /// @param _registrar The registrar controller address
    function setRegistrar(address _registrar) external onlyOwner {
        registrar = IDMDRegistrarController(_registrar);

        emit SetRegistrar(_registrar);
    }

    /// @notice Sets token metadata base URI.
    /// @param _baseUri The new base URI
    function setBaseURI(string calldata _baseUri) external onlyOwner {
        baseURI = _baseUri;

        emit SetBaseURI(_baseUri);
    }

    /// @notice Updates the fee required for user-initiated transfers.
    /// @param _transferFee The new transfer fee value
    function setTransferFee(uint256 _transferFee) external onlyRegistrar {
        transferFee = _transferFee;

        emit SetTransferFee(_transferFee);
    }

    /// @notice Mints a name token with an expiration.
    /// @param id The token id (name label hash)
    /// @param owner The recipient of the token
    /// @param expiration The expiration timestamp of the name
    function register(uint256 id, address owner, uint256 expiration) external onlyRegistrar {
        _expires[id] = expiration;

        _mint(owner, id);
    }

    /// @notice Extends the expiration of an existing, non-expired name.
    /// @param id Id of the token to renew
    /// @param expiration The new expiration timestamp
    function renew(uint256 id, uint256 expiration) external onlyRegistrar {
        _requireOwned(id);

        if (_expires[id] < block.timestamp) {
            revert Expired(id);
        }

        _expires[id] = expiration;

        emit Renew(id, expiration);
    }

    /// @notice Burns a name token and clears its expiration.
    /// @param id The token id to burn.
    function burn(uint256 id) external onlyRegistrar {
        delete _expires[id];

        _burn(id);
    }

    /// @notice Transfers a name token, charging the transfer fee for user transfers and
    ///         resetting the name's resolver records.
    /// @param from Token current owner
    /// @param to Token recipient
    /// @param tokenId The token id to transfer
    function transferFrom(address from, address to, uint256 tokenId) public payable override {
        if (msg.sender != address(registrar) && msg.value != transferFee) {
            revert InvalidTransferFee(transferFee, msg.value);
        }

        super.transferFrom(from, to, tokenId);

        // Reset any live ENS/resolver records so the new owner must re-activate.
        if (address(registrar) != address(0)) {
            registrar.resetRecordsOnTransfer(from, tokenId);
        }

        if (msg.value != 0) {
            TransferUtils.transferNative(reinsertPot, msg.value);
        }
    }

    /// @notice Returns whether a name can be registered (never minted or expired).
    /// @param id The token id to check
    /// @return True if the name is available, false otherwise
    function available(uint256 id) public view returns (bool) {
        return !exists(id) || expired(id);
    }

    /// @notice Returns whether a name is expired.
    /// @param id The token id to check
    /// @return True if the current time is past the expiration, false otherwise
    function expired(uint256 id) public view returns (bool) {
        return _expires[id] < block.timestamp;
    }

    /// @notice Returns whether a token currently exists (was minted).
    /// @param id The token id to check
    /// @return True if the token exists, false otherwise
    function exists(uint256 id) public view returns (bool) {
        return _ownerOf(id) != address(0);
    }

    /// @notice Returns the expiration timestamp of a name.
    /// @param id The token id to check
    /// @return The expiration timestamp
    function nameExpires(uint256 id) public view returns (uint256) {
        return _expires[id];
    }

    /// @inheritdoc ERC721Base
    function _baseURI() internal view override returns (string memory) {
        return baseURI;
    }

    /// @dev Reverts if the caller is not the configured registrar.
    function _checkRegistrar() private view {
        if (msg.sender != address(registrar)) {
            revert Errors.Unauthorised();
        }
    }
}
