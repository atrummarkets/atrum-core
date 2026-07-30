// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

/// @dev Minimal ERC20 surface. Only what the Vault actually calls.
interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function decimals() external view returns (uint8);
}
