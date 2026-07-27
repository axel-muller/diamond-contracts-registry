// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.25;

import { Test } from "forge-std/Test.sol";

import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import { Upgrades } from "openzeppelin-foundry-upgrades/Upgrades.sol";

import { DateTimeLib } from "solady/utils/DateTimeLib.sol";

import { ValueGuards } from "diamond-contracts-core/lib/ValueGuards.sol";

import { DMDNames } from "src/DMDNames.sol";
import { DMDRegistrarController } from "src/DMDRegistrarController.sol";
import { DMDRegistry } from "src/DMDRegistry.sol";
import { DMDResolver } from "src/DMDResolver.sol";
import { IAddrResolver } from "src/interface/IAddrResolver.sol";
import { INameResolver } from "src/interface/INameResolver.sol";
import { AddressUtils } from "src/lib/AddressUtils.sol";
import { Errors } from "src/lib/Errors.sol";
import { NameBlocklist } from "src/lib/NameBlocklist.sol";
import { NameUtils } from "src/lib/NameUtils.sol";

contract DMDRegistrarControllerTest is Test {
    struct NameValidationTestCase {
        string name;
        bool expected;
    }

    DMDRegistrarController public registrar;
    DMDNames public diamondNames;
    DMDRegistry public registry;
    DMDResolver public resolver;

    address public constant REINSERT_POT = address(0x2000000000000000000000000000000000000001);
    string public constant CONTROLLER_CONTRACT = "DMDRegistrarController.sol:DMDRegistrarController";
    string public constant NAMES_CONTRACT = "DMDNames.sol:DMDNames";
    string public constant REGISTRY_CONTRACT = "DMDRegistry.sol:DMDRegistry";
    string public constant RESOLVER_CONTRACT = "DMDResolver.sol:DMDResolver";
    string public constant BASE_URI = "https://names.bit.diamonds/";

    bytes32 public constant ROOT_NODE = bytes32(0);
    bytes32 public constant DMD_LABEL = keccak256("dmd");
    bytes32 public constant REVERSE_LABEL = keccak256("reverse");
    bytes32 public constant ADDR_LABEL = keccak256("addr");
    bytes32 public constant REVERSE_NODE = keccak256(abi.encodePacked(ROOT_NODE, REVERSE_LABEL));

    uint256 public constant INITIAL_TRANSFER_FEE = 0.5 ether;

    address public owner;
    address public alice;
    address public bob;

    uint256 public mintingFee;

    function setUp() public {
        owner = makeAddr("owner");
        alice = makeAddr("alice");
        bob = makeAddr("bob");

        registry = DMDRegistry(
            Upgrades.deployTransparentProxy(REGISTRY_CONTRACT, owner, abi.encodeCall(DMDRegistry.initialize, (owner)))
        );

        resolver = DMDResolver(
            Upgrades.deployTransparentProxy(
                RESOLVER_CONTRACT, owner, abi.encodeCall(DMDResolver.initialize, (address(registry)))
            )
        );

        diamondNames = DMDNames(
            Upgrades.deployTransparentProxy(
                NAMES_CONTRACT,
                owner,
                abi.encodeCall(DMDNames.initialize, (owner, REINSERT_POT, INITIAL_TRANSFER_FEE, BASE_URI))
            )
        );

        registrar = DMDRegistrarController(
            Upgrades.deployTransparentProxy(
                CONTROLLER_CONTRACT,
                owner,
                abi.encodeCall(
                    DMDRegistrarController.initialize,
                    (owner, REINSERT_POT, address(diamondNames), address(registry), address(resolver))
                )
            )
        );

        mintingFee = registrar.mintingFee();

        vm.prank(owner);
        diamondNames.setRegistrar(address(registrar));

        vm.prank(owner);
        registry.setSubnodeOwner(ROOT_NODE, DMD_LABEL, address(registrar));

        vm.prank(owner);
        registry.setSubnodeOwner(ROOT_NODE, REVERSE_LABEL, owner);

        vm.prank(owner);
        registry.setSubnodeOwner(REVERSE_NODE, ADDR_LABEL, address(registrar));
    }

    function _registerName(address user, string memory name) internal {
        vm.deal(user, mintingFee);
        vm.prank(user);

        registrar.register{ value: mintingFee }(name);
    }

    function _nodeOf(string memory name) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(NameUtils.DMD_NODE, keccak256(bytes(name))));
    }

    function _labelOf(string memory name) internal pure returns (bytes32) {
        return keccak256(bytes(name));
    }

    function _reverseNodeOf(address addr) internal pure returns (bytes32) {
        return AddressUtils.reverseNode(addr);
    }

    function _deployUninitializedController() internal returns (DMDRegistrarController) {
        bytes memory initData;

        return DMDRegistrarController(Upgrades.deployTransparentProxy(CONTROLLER_CONTRACT, owner, initData));
    }

    function test_Initialize_InvalidOwner_Reverts() public {
        DMDRegistrarController _registrar = _deployUninitializedController();

        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableInvalidOwner.selector, address(0)));
        _registrar.initialize(address(0), REINSERT_POT, address(diamondNames), address(registry), address(resolver));
    }

    function test_Initialize_InvalidReinsertPot_Reverts() public {
        DMDRegistrarController _registrar = _deployUninitializedController();

        vm.expectRevert(Errors.InvalidReinsertPot.selector);
        _registrar.initialize(owner, address(0), address(diamondNames), address(registry), address(resolver));
    }

    function test_Initialize_InvalidDiamondNames_Reverts() public {
        DMDRegistrarController _registrar = _deployUninitializedController();

        vm.expectRevert(Errors.InvalidNamesContract.selector);
        _registrar.initialize(owner, REINSERT_POT, address(0), address(registry), address(resolver));
    }

    function test_Initialize_InvalidRegistry_Reverts() public {
        DMDRegistrarController _registrar = _deployUninitializedController();

        vm.expectRevert(Errors.InvalidRegistry.selector);
        _registrar.initialize(owner, REINSERT_POT, address(diamondNames), address(0), address(resolver));
    }

    function test_Initialize_InvalidResolver_Reverts() public {
        DMDRegistrarController _registrar = _deployUninitializedController();

        vm.expectRevert(Errors.InvalidResolver.selector);
        _registrar.initialize(owner, REINSERT_POT, address(diamondNames), address(registry), address(0));
    }

    function test_Initialize_DoubleInitialization_Reverts() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        registrar.initialize(owner, REINSERT_POT, address(diamondNames), address(registry), address(resolver));
    }

    function test_Initialize() public view {
        assertEq(registrar.reinsertPot(), REINSERT_POT);
        assertEq(address(registrar.diamondNames()), address(diamondNames));
        assertEq(address(registrar.registry()), address(registry));
        assertEq(address(registrar.resolver()), address(resolver));
        assertEq(registrar.mintingFee(), registrar.DEFAULT_MINTING_FEE());
        assertEq(registrar.owner(), owner);
    }

    function test_Register_NoFundsSent_Reverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(DMDRegistrarController.InvalidMintingFee.selector, mintingFee, 0));
        registrar.register("alice");
    }

    function test_Register_InsufficientFundsSent_Reverts() public {
        vm.deal(alice, mintingFee);
        vm.prank(alice);

        vm.expectRevert(
            abi.encodeWithSelector(DMDRegistrarController.InvalidMintingFee.selector, mintingFee, mintingFee - 1)
        );
        registrar.register{ value: mintingFee - 1 }("alice");
    }

    function test_Register_RegistrarInactive_Reverts() public {
        vm.prank(owner);
        registry.setSubnodeOwner(ROOT_NODE, DMD_LABEL, owner);

        vm.deal(alice, mintingFee);
        vm.prank(alice);
        vm.expectRevert(DMDRegistrarController.RegistrarInactive.selector);
        registrar.register{ value: mintingFee }("alice");
    }

    function test_Register_TransfersFeeToReinsertPot() public {
        vm.deal(alice, mintingFee);

        uint256 potBalanceBefore = REINSERT_POT.balance;

        vm.prank(alice);
        registrar.register{ value: mintingFee }("alice");

        assertEq(alice.balance, 0);
        assertEq(REINSERT_POT.balance, potBalanceBefore + mintingFee);
    }

    function test_Register_EmitsEvent() public {
        string memory name = "alice";
        bytes32 nameHash = keccak256(bytes(name));
        uint256 expiration = DateTimeLib.addYears(block.timestamp, registrar.EXPIRATION_TIME_YEARS());

        vm.deal(alice, mintingFee);

        vm.expectEmit(true, true, true, true, address(registrar));
        emit DMDRegistrarController.NameRegistered(alice, nameHash, expiration, name);

        vm.prank(alice);
        registrar.register{ value: mintingFee }(name);
    }

    function test_Register_SetRegisteredNameUnavailable() public {
        string memory name = "alice";

        assertTrue(registrar.available(name));

        _registerName(alice, name);

        assertEq(string(registrar.names(alice)), name);
        assertFalse(registrar.available(name));
    }

    function test_Register_MintsNFT() public {
        string memory name = "alice";
        _registerName(alice, name);

        uint256 nameId = uint256(registrar.getHashOfName(name));
        assertEq(diamondNames.ownerOf(nameId), alice);
    }

    function test_Register_SetsRegistryRecord() public {
        string memory name = "alice";
        _registerName(alice, name);

        bytes32 node = _nodeOf(name);

        assertTrue(registry.recordExists(node));
        assertEq(registry.owner(node), address(registrar));
        assertEq(registry.resolver(node), address(resolver));
        assertEq(registry.ttl(node), 0);
    }

    function test_Register_ForwardResolution_ENSPath() public {
        string memory name = "alice";
        _registerName(alice, name);

        bytes32 node = _nodeOf(name);

        address resolverAddr = registry.resolver(node);
        assertEq(resolverAddr, address(resolver));

        assertEq(IAddrResolver(resolverAddr).addr(node), alice);
    }

    function test_Resolver_SupportsAddrInterface() public view {
        assertTrue(resolver.supportsInterface(0x01ffc9a7));
        assertTrue(resolver.supportsInterface(0x3b3b57de));
    }

    function test_Register_BlockedName_Reverts() public {
        string memory name = "blocked-name";

        vm.prank(owner);
        registrar.setNameBlocked(name, true);

        vm.deal(alice, mintingFee);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(NameBlocklist.NameBlocked.selector, name));
        registrar.register{ value: mintingFee }(name);
    }

    function test_Register_UnblockedName_Succeeds() public {
        string memory name = "blocked-name";

        vm.prank(owner);
        registrar.setNameBlocked(name, true);

        vm.prank(owner);
        registrar.setNameBlocked(name, false);

        _registerName(alice, name);

        assertEq(string(registrar.names(alice)), name);
    }

    function test_Register_BlockingExistingName_DoesNotAffectOwner() public {
        string memory name = "alice";
        _registerName(alice, name);

        vm.prank(owner);
        registrar.setNameBlocked(name, true);

        bytes32 node = _nodeOf(name);
        assertEq(string(registrar.names(alice)), name);
        assertEq(registry.owner(node), address(registrar));
        assertEq(resolver.addr(node), alice);
    }

    function test_Register_NameAlreadyTaken_Reverts() public {
        _registerName(alice, "alice");

        vm.deal(bob, mintingFee);
        vm.prank(bob);
        vm.expectRevert(DMDRegistrarController.NotAvailable.selector);
        registrar.register{ value: mintingFee }("alice");
    }

    function _expireName(string memory name) internal {
        uint256 tokenId = uint256(registrar.getHashOfName(name));
        vm.warp(diamondNames.nameExpires(tokenId) + 1);
    }

    function test_Register_ExpiredName_IsAvailable() public {
        _registerName(alice, "alice");
        assertFalse(registrar.available("alice"));

        _expireName("alice");
        assertTrue(registrar.available("alice"));
    }

    function test_Register_ExpiredName_BurnsOldAndRemintsToNewOwner() public {
        _registerName(alice, "alice");
        uint256 tokenId = uint256(registrar.getHashOfName("alice"));
        assertEq(diamondNames.ownerOf(tokenId), alice);

        _expireName("alice");

        _registerName(bob, "alice");

        assertEq(diamondNames.ownerOf(tokenId), bob);
        assertGt(diamondNames.nameExpires(tokenId), block.timestamp);
    }

    function test_Register_ExpiredActiveName_ResetsPreviousOwnerRecords() public {
        _registerName(alice, "alice");
        bytes32 node = _nodeOf("alice");

        assertEq(registrar.namesReverse(_labelOf("alice")), alice);
        assertEq(resolver.name(_reverseNodeOf(alice)), "alice.dmd");

        _expireName("alice");
        _registerName(bob, "alice");

        assertEq(string(registrar.names(alice)), "");
        assertEq(resolver.name(_reverseNodeOf(alice)), "");
        assertEq(registrar.namesReverse(_labelOf("alice")), bob);
        assertEq(registry.owner(node), address(registrar));
        assertEq(resolver.addr(node), bob);
        assertEq(resolver.name(_reverseNodeOf(bob)), "alice.dmd");
    }

    function test_Register_ExpiredName_NewOwnerCanBeBlockedAware() public {
        _registerName(alice, "alice");
        _expireName("alice");

        vm.prank(owner);
        registrar.setNameBlocked("alice", true);

        vm.deal(bob, mintingFee);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(NameBlocklist.NameBlocked.selector, "alice"));
        registrar.register{ value: mintingFee }("alice");
    }

    function test_Register_InvalidName_Reverts() public {
        vm.deal(alice, mintingFee);
        vm.prank(alice);
        vm.expectRevert(DMDRegistrarController.InvalidName.selector);
        registrar.register{ value: mintingFee }("-alice");
    }

    function test_Resolver_SupportsNameInterface() public view {
        assertTrue(resolver.supportsInterface(0x691f3431));
    }

    function test_Register_ReverseResolution_ENSPath() public {
        string memory name = "alice";
        _registerName(alice, name);

        bytes32 reverseNode = _reverseNodeOf(alice);

        address resolverAddr = registry.resolver(reverseNode);
        assertEq(resolverAddr, address(resolver));

        assertEq(INameResolver(resolverAddr).name(reverseNode), "alice.dmd");
    }

    function test_Activate_SwitchPrimary_UpdatesReverseRecord() public {
        _registerName(alice, "alice");

        vm.deal(alice, mintingFee);
        vm.prank(alice);
        registrar.register{ value: mintingFee }("alice2");

        uint256 activationFee = registrar.getActivationFee(alice);
        vm.deal(alice, activationFee);
        vm.prank(alice);
        registrar.activate{ value: activationFee }("alice2");

        bytes32 reverseNode = _reverseNodeOf(alice);
        assertEq(resolver.name(reverseNode), "alice2.dmd");

        assertEq(resolver.addr(_nodeOf("alice2")), alice);
        assertEq(registry.owner(_nodeOf("alice")), address(registrar));
    }

    function test_ModerateName_ClearsReverseRecord() public {
        string memory name = "alice";
        string memory reason = "Scam / phishing impersonation";
        string memory notes = "sent phishing links in discord";

        _registerName(alice, name);

        vm.prank(owner);
        registrar.moderateName(alice, name, reason, notes);

        bytes32 reverseNode = _reverseNodeOf(alice);
        assertEq(resolver.name(reverseNode), "");
        assertEq(registry.resolver(reverseNode), address(0));
    }

    function test_TransferFee_InitialFeeIsTenPercentOfMintingFee() public view {
        assertEq(diamondNames.transferFee(), INITIAL_TRANSFER_FEE);
        assertEq(diamondNames.transferFee(), mintingFee / 10);
    }

    function test_TransferFee_RequiredOnUserTransfer() public {
        _registerName(alice, "alice");
        uint256 tokenId = uint256(registrar.getHashOfName("alice"));
        uint256 fee = diamondNames.transferFee();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(DMDNames.InvalidTransferFee.selector, fee, 0));
        diamondNames.transferFrom(alice, bob, tokenId);
    }

    function test_TransferFee_WrongFeeReverts() public {
        _registerName(alice, "alice");
        uint256 tokenId = uint256(registrar.getHashOfName("alice"));
        uint256 fee = diamondNames.transferFee();

        vm.deal(alice, fee);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(DMDNames.InvalidTransferFee.selector, fee, fee - 1));
        diamondNames.transferFrom{ value: fee - 1 }(alice, bob, tokenId);
    }

    function test_TransferFee_CorrectFeeSucceedsAndForwardsToPot() public {
        _registerName(alice, "alice");
        uint256 tokenId = uint256(registrar.getHashOfName("alice"));
        uint256 fee = diamondNames.transferFee();

        uint256 potBefore = REINSERT_POT.balance;

        vm.deal(alice, fee);
        vm.prank(alice);
        diamondNames.transferFrom{ value: fee }(alice, bob, tokenId);

        assertEq(diamondNames.ownerOf(tokenId), bob);
        assertEq(REINSERT_POT.balance, potBefore + fee);
        assertEq(alice.balance, 0);
    }

    function test_TransferFee_ControllerExemptFromFee() public {
        _registerName(alice, "alice");
        uint256 tokenId = uint256(registrar.getHashOfName("alice"));

        vm.prank(alice);
        diamondNames.approve(address(registrar), tokenId);

        uint256 potBefore = REINSERT_POT.balance;

        vm.prank(address(registrar));
        diamondNames.transferFrom(alice, bob, tokenId);

        assertEq(diamondNames.ownerOf(tokenId), bob);
        assertEq(REINSERT_POT.balance, potBefore);
    }

    function test_Transfer_ResetsActiveNameRecords() public {
        _registerName(alice, "alice");
        uint256 tokenId = uint256(registrar.getHashOfName("alice"));
        bytes32 node = _nodeOf("alice");
        uint256 fee = diamondNames.transferFee();

        vm.deal(alice, fee);
        vm.prank(alice);
        diamondNames.transferFrom{ value: fee }(alice, bob, tokenId);

        assertEq(diamondNames.ownerOf(tokenId), bob);

        assertEq(registry.owner(node), address(registrar));
        assertEq(resolver.addr(node), address(0));
        assertEq(registry.resolver(node), address(0));

        bytes32 reverseNode = _reverseNodeOf(alice);
        assertEq(resolver.name(reverseNode), "");
        assertEq(registry.resolver(reverseNode), address(0));

        assertEq(registrar.names(alice).length, 0);
    }

    function test_Transfer_NewOwnerMustActivate() public {
        _registerName(alice, "alice");
        uint256 tokenId = uint256(registrar.getHashOfName("alice"));
        bytes32 node = _nodeOf("alice");
        uint256 fee = diamondNames.transferFee();

        vm.deal(alice, fee);
        vm.prank(alice);
        diamondNames.transferFrom{ value: fee }(alice, bob, tokenId);

        assertEq(registrar.getActivationFee(bob), 0);

        vm.prank(bob);
        registrar.activate("alice");

        assertEq(registry.owner(node), address(registrar));
        assertEq(registrar.namesReverse(_labelOf("alice")), bob);
        assertEq(resolver.addr(node), bob);
        assertEq(resolver.name(_reverseNodeOf(bob)), "alice.dmd");
        assertEq(string(registrar.names(bob)), "alice");
    }

    function test_Transfer_InactiveName_DoesNotResetActiveName() public {
        _registerName(alice, "alice");

        vm.deal(alice, mintingFee);
        vm.prank(alice);
        registrar.register{ value: mintingFee }("alice2");

        uint256 inactiveTokenId = uint256(registrar.getHashOfName("alice2"));
        uint256 fee = diamondNames.transferFee();

        vm.deal(alice, fee);
        vm.prank(alice);
        diamondNames.transferFrom{ value: fee }(alice, bob, inactiveTokenId);

        bytes32 activeNode = _nodeOf("alice");
        assertEq(registry.owner(activeNode), address(registrar));
        assertEq(registrar.namesReverse(_labelOf("alice")), alice);
        assertEq(resolver.addr(activeNode), alice);
        assertEq(resolver.name(_reverseNodeOf(alice)), "alice.dmd");
        assertEq(string(registrar.names(alice)), "alice");
    }

    function test_ResetRecordsOnTransfer_OnlyCallableByNames() public {
        _registerName(alice, "alice");
        uint256 tokenId = uint256(registrar.getHashOfName("alice"));

        vm.prank(alice);
        vm.expectRevert(Errors.Unauthorised.selector);
        registrar.resetRecordsOnTransfer(alice, tokenId);
    }

    function test_SetMintingFee() public {
        uint256 newFee = mintingFee * 2;

        vm.prank(owner);

        vm.expectEmit(true, false, false, false, address(registrar));
        emit DMDRegistrarController.SetMintingFee(newFee);
        registrar.setMintingFee(newFee);

        assertEq(registrar.mintingFee(), newFee);
    }

    function test_SetMintingFee_SyncsTransferFee() public {
        uint256 newFee = mintingFee * 2;

        vm.prank(owner);
        registrar.setMintingFee(newFee);

        assertEq(diamondNames.transferFee(), newFee / 10);
    }

    function test_SetMintingFee_ValueOutOfRange_Reverts() public {
        uint256 outOfRange = mintingFee / 4;

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ValueGuards.NewValueOutOfRange.selector, outOfRange));
        registrar.setMintingFee(outOfRange);
    }

    function test_SetMintingFee_UnauthorizedCaller_Reverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, alice));
        registrar.setMintingFee(mintingFee * 2);
    }

    function fixtureNames() public pure returns (NameValidationTestCase[] memory) {
        NameValidationTestCase[] memory cases = new NameValidationTestCase[](20);

        cases[0] = NameValidationTestCase({ name: "!123", expected: false });
        cases[1] = NameValidationTestCase({ name: unicode"★★★", expected: false });
        cases[2] = NameValidationTestCase({ name: "a", expected: false });
        cases[3] = NameValidationTestCase({ name: "abc~", expected: false });
        cases[4] = NameValidationTestCase({ name: "abc,abc", expected: false });
        cases[5] = NameValidationTestCase({ name: "abcabc,", expected: false });
        cases[6] = NameValidationTestCase({ name: ",abcabc", expected: false });
        cases[7] = NameValidationTestCase({ name: "abc abc", expected: false });
        cases[8] = NameValidationTestCase({ name: "abc_abc", expected: false });
        cases[9] = NameValidationTestCase({ name: "-adasdasd", expected: false });
        cases[10] = NameValidationTestCase({ name: "asdadas-", expected: false });
        cases[11] = NameValidationTestCase({ name: "a-b-c--d", expected: false });
        cases[12] = NameValidationTestCase({ name: "abcdEf", expected: false });
        cases[13] = NameValidationTestCase({ name: "alice", expected: true });
        cases[14] = NameValidationTestCase({ name: "1alice", expected: true });
        cases[15] = NameValidationTestCase({ name: "1337", expected: true });
        cases[16] = NameValidationTestCase({ name: "alice-bob", expected: true });
        cases[17] = NameValidationTestCase({ name: "alice-bob-dan", expected: true });
        cases[18] = NameValidationTestCase({ name: _repeat("a", 3), expected: true });
        cases[19] = NameValidationTestCase({ name: _repeat("a", 63), expected: true });

        return cases;
    }

    function tableValidTests(NameValidationTestCase memory names) public view {
        assertEq(registrar.valid(names.name), names.expected);
    }

    function _repeat(string memory char, uint256 count) private pure returns (string memory result) {
        for (uint256 i = 0; i < count; ++i) {
            result = string.concat(result, char);
        }
    }
}
