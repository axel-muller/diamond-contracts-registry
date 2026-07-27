// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.25;

import { Test } from "forge-std/Test.sol";

import { AddressUtils } from "src/lib/AddressUtils.sol";

contract AddressUtilsTest is Test {
    bytes32 public constant ROOT_NODE = bytes32(0);
    bytes32 public constant ADDR_REVERSE_NODE = 0x91d1777781884d03a6757a803996e38de2a42967fb37eeaca72729271025a9e2;

    function _sha3HexAddressRef(address a) private pure returns (bytes32) {
        bytes16 lookup = "0123456789abcdef";
        bytes memory s = new bytes(40);
        uint160 x = uint160(a);

        for (uint256 i = 0; i < 20; ++i) {
            uint8 b = uint8(x >> (8 * (19 - i)));
            s[2 * i] = lookup[b >> 4];
            s[2 * i + 1] = lookup[b & 0x0f];
        }

        return keccak256(s);
    }

    function _reverseNode(address a) private pure returns (bytes32) {
        return keccak256(abi.encodePacked(ADDR_REVERSE_NODE, _sha3HexAddressRef(a)));
    }

    function test_AddrReverseNode_MatchesConstant() public pure {
        assertEq(AddressUtils.ADDR_REVERSE_NODE, ADDR_REVERSE_NODE);
    }

    function test_AddrReverseNode_MatchesNamehashDerivation() public pure {
        bytes32 reverseNode = keccak256(abi.encodePacked(ROOT_NODE, keccak256("reverse")));
        bytes32 derived = keccak256(abi.encodePacked(reverseNode, keccak256("addr")));

        assertEq(AddressUtils.ADDR_REVERSE_NODE, derived);
    }

    function test_Sha3HexAddress_Zero() public pure {
        assertEq(AddressUtils.sha3HexAddress(address(0)), keccak256("0000000000000000000000000000000000000000"));
    }

    function test_Sha3HexAddress_KnownAddress() public pure {
        address a = 0x1234567890AbcdEF1234567890aBcdef12345678;

        assertEq(AddressUtils.sha3HexAddress(a), keccak256("1234567890abcdef1234567890abcdef12345678"));
    }

    function test_Sha3HexAddress_MatchesReference() public pure {
        assertEq(AddressUtils.sha3HexAddress(address(0xBEEF)), _sha3HexAddressRef(address(0xBEEF)));
    }

    function test_Sha3HexAddress_DifferentAddressesDiffer() public pure {
        assertTrue(AddressUtils.sha3HexAddress(address(0x1)) != AddressUtils.sha3HexAddress(address(0x2)));
    }

    function testFuzz_Sha3HexAddress_MatchesReference(address a) public pure {
        assertEq(AddressUtils.sha3HexAddress(a), _sha3HexAddressRef(a));
    }

    function test_ReverseNode_MatchesDerivation() public pure {
        address a = makeAddrLike();

        assertEq(AddressUtils.reverseNode(a), _reverseNode(a));
    }

    function test_ReverseNode_UsesAddrReverseParent() public pure {
        address a = address(0xCAFE);
        bytes32 expected = keccak256(abi.encodePacked(AddressUtils.ADDR_REVERSE_NODE, AddressUtils.sha3HexAddress(a)));

        assertEq(AddressUtils.reverseNode(a), expected);
    }

    function test_ReverseNode_DifferentAddressesDiffer() public pure {
        assertTrue(AddressUtils.reverseNode(address(0x1)) != AddressUtils.reverseNode(address(0x2)));
    }

    function testFuzz_ReverseNode_MatchesDerivation(address a) public pure {
        assertEq(AddressUtils.reverseNode(a), _reverseNode(a));
    }

    function makeAddrLike() private pure returns (address) {
        return 0x00000000000000000000000000000000DeaDBeef;
    }
}
