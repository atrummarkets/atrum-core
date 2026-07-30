// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {INullifierSet} from "./INullifierSet.sol";

/// @title MappingNullifierSet
/// @notice One storage slot per spent nullifier. Measured at 28,945 gas on Monad.
///
/// @dev The accepted tradeoff is unbounded state growth: one slot per nullifier,
///      forever, never reclaimed. That is a real cost and it is the reason
///      `atrum-build-plan.md` reached for a tree instead. It is accepted here because
///      Monad has no state rent, and 661,788 gas per bet is a certain, immediate cost
///      against a speculative future one. Revisit if state rent ever appears.
contract MappingNullifierSet is INullifierSet {
    mapping(uint256 => bool) private _spent;

    address public immutable deployer;
    address public pool;

    error AlreadySpent();
    error NotPool();
    error PoolAlreadyBound();
    error NotDeployer();
    error InvalidPool();

    constructor() {
        deployer = msg.sender;
    }

    /// @notice Bind the one contract allowed to spend, once.
    /// @dev Two-step rather than constructor injection because the pool needs this
    ///      contract's address to be constructed, and this contract needs the pool's --
    ///      a cycle. Binding is irreversible, so the window is exactly one call by the
    ///      deployer and there is no ongoing privileged role.
    function bindPool(address pool_) external {
        if (msg.sender != deployer) revert NotDeployer();
        if (pool != address(0)) revert PoolAlreadyBound();
        if (pool_ == address(0)) revert InvalidPool();
        pool = pool_;
    }

    function isSpent(uint256 nullifierHash) external view returns (bool) {
        return _spent[nullifierHash];
    }

    function enforcesOnChain() external pure returns (bool) {
        return true;
    }

    function spend(uint256 nullifierHash) external {
        if (msg.sender != pool) revert NotPool();
        if (_spent[nullifierHash]) revert AlreadySpent();
        _spent[nullifierHash] = true;
    }
}
