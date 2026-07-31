// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

/// @title INullifierSet
/// @notice The double-spend guard, behind an interface so the two candidate designs
///         can be measured against each other under the real ShieldedPool path.
///
/// @dev `atrum-build-plan.md` §7 specifies an indexed nullifier TREE, to keep on-chain
///      state root-only. `MEASUREMENTS.md` §1b measured a plain mapping at 28,945 gas
///      against 690,733 for a depth-20 tree insertion -- 661,788 gas per bet, which on
///      its own is the difference between fitting the 2,000,000 action envelope and
///      not.
///
///      That measurement compared bare insertion costs in isolation. This interface
///      exists so the comparison can be made where it actually matters: inside a real
///      action, alongside a Groth16 verify and a pool update. See
///      `test/NullifierSet.t.sol`.
///
///      The gas gap is only half the argument. The other half is in
///      `TreeNullifierSet` -- read its notice before choosing.
interface INullifierSet {
    /// @notice Has this nullifier hash already been spent?
    /// @dev MUST be answerable on-chain. An implementation that cannot answer it
    ///      forces the check into the circuit as a non-membership proof, which is a
    ///      different and much larger design.
    function isSpent(uint256 nullifierHash) external view returns (bool);

    /// @notice Record `nullifierHash` as spent. Reverts if already spent.
    /// @dev Callable only by the bound pool.
    function spend(uint256 nullifierHash) external;

    /// @notice True if `isSpent` is a real answer rather than a stub.
    /// @dev Lets the pool refuse to deploy against a set that cannot enforce
    ///      double-spend prevention on-chain, instead of discovering it in production.
    function enforcesOnChain() external view returns (bool);
}
