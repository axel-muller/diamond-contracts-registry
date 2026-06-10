// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.25;

import { Test } from "forge-std/Test.sol";

import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import { Upgrades } from "openzeppelin-foundry-upgrades/Upgrades.sol";

import { ValueGuards } from "diamond-contracts-core/lib/ValueGuards.sol";

import { DMDNames } from "src/DMDNames.sol";
import { DMDRegistrarController } from "src/DMDRegistrarController.sol";
import { DMDRegistry } from "src/DMDRegistry.sol";
import { DMDResolver } from "src/DMDResolver.sol";
import { IAddrResolver } from "src/interface/IAddrResolver.sol";
import { Errors } from "src/lib/Errors.sol";

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
                NAMES_CONTRACT, owner, abi.encodeCall(DMDNames.initialize, (owner, BASE_URI))
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
        diamondNames.setController(address(registrar), true);

        vm.prank(owner);
        registry.setSubnodeOwner(ROOT_NODE, DMD_LABEL, address(registrar));
    }

    function _registerName(address user, string memory name) internal {
        vm.deal(user, mintingFee);
        vm.prank(user);

        registrar.register{ value: mintingFee }(name);
    }

    function _nodeOf(string memory name) internal view returns (bytes32) {
        return keccak256(abi.encodePacked(registrar.DMD_NODE(), keccak256(bytes(name))));
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

        vm.expectRevert(Errors.InvalidReinsertPotAddress.selector);
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
        assertEq(registrar.reinsertPotAddress(), REINSERT_POT);
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
        // root owner takes the dmd node back from the controller
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

        vm.deal(alice, mintingFee);

        vm.expectEmit(true, false, false, true, address(registrar));
        emit DMDRegistrarController.NameRegistered(alice, nameHash, name);

        vm.prank(alice);
        registrar.register{ value: mintingFee }(name);
    }

    function test_Register_SetRegisteredNameUnavailable() public {
        string memory name = "alice";

        assertTrue(registrar.available(name));

        _registerName(alice, name);

        assertEq(registrar.name(alice), name);
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
        assertEq(registry.owner(node), alice);
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
        assertTrue(resolver.supportsInterface(0x01ffc9a7)); // ERC-165
        assertTrue(resolver.supportsInterface(0x3b3b57de)); // addr(bytes32)
    }

    function test_Register_NameAlreadyTaken_Reverts() public {
        _registerName(alice, "alice");

        vm.deal(bob, mintingFee);
        vm.prank(bob);
        vm.expectRevert(DMDRegistrarController.NotAvailable.selector);
        registrar.register{ value: mintingFee }("alice");
    }

    function test_Register_InvalidName_Reverts() public {
        vm.deal(alice, mintingFee);
        vm.prank(alice);
        vm.expectRevert(DMDRegistrarController.InvalidName.selector);
        registrar.register{ value: mintingFee }("-alice");
    }

    function test_GetAddressOfName_ReturnsOwner() public {
        string memory name = "just-another-name";
        _registerName(alice, name);

        assertEq(registrar.getAddressOfName(name), alice);
    }

    function test_SetMintingFee() public {
        uint256 newFee = mintingFee * 2; // allowed increase

        vm.prank(owner);

        vm.expectEmit(true, false, false, false, address(registrar));
        emit DMDRegistrarController.SetMintingFee(newFee);
        registrar.setMintingFee(newFee);

        assertEq(registrar.mintingFee(), newFee);
    }

    function test_SetMintingFee_ValueOutOfRange_Reverts() public {
        uint256 outOfRange = mintingFee / 4; // not allowed decrease (2 steps)

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
