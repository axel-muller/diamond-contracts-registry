// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.25;

import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import { IAddrResolver } from "./IAddrResolver.sol";

interface IResolver is IERC165, IAddrResolver {
    function setAddr(bytes32 node, address addr) external;
}
