// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.25;

interface IDMDNames {
    function register(uint256 id, address owner, uint256 expiration) external;
}
