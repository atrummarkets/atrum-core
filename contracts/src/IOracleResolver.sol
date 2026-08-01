// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Vault} from "./Vault.sol";

/// @title IOracleResolver
/// @notice What every oracle adapter must look like from the market's side.
///
/// @dev WHY THE MARKET NEEDS THIS AT ALL
///
///      `Vault.resolver` is a single immutable address that may flip the outcome. Today that
///      is a human. A human resolver is fine for markets the operator creates and settles
///      honestly, and completely unacceptable the moment ANYONE can create a market -- because
///      the creator names the resolver, so a malicious creator is a malicious resolver who
///      resolves their own market wrongly and takes the pool.
///
///      So permissionless market creation is blocked on this interface, not on a permission
///      check. Point `Vault.resolver` at an adapter instead of a person and the outcome stops
///      being a decision and becomes a computation.
///
///      THE TWO ORACLE SHAPES IT HAS TO COVER
///
///      - PULL (Pyth, Chainlink Data Streams, Stork): nothing is on-chain until someone pays
///        to put it there. The caller supplies signed data, the adapter verifies it, and
///        there is a FEE. This is why `resolve` is payable and takes `oracleData`.
///      - PUSH (Chainlink Price Feeds, Chronicle): the value is already on-chain. The adapter
///        ignores `oracleData` and pays no fee.
///
///      An interface that only fits one shape is not modular, it is a Pyth binding with extra
///      steps -- so both are accommodated even though v1 ships only the Pyth adapter.
///
///      WHY IT IS PERMISSIONLESS
///
///      Implementations MUST let anyone call `resolve`. That is not laxity, it is the point:
///      if the answer is a computation over signed data bound to a committed question, then
///      whoever calls it cannot influence the result, and anyone being able to call it means
///      the market cannot be held hostage by an operator who simply never resolves.
///
///      The discretion an adapter must NOT have:
///        - choosing WHICH question is being answered -- pinned by `Vault.resolutionSpecHash`
///        - choosing WHEN the price is read from -- pinned inside the spec
///        - choosing whether to resolve at all -- anyone can call
interface IOracleResolver {
    /// @notice Resolve `vault` from oracle data. Anyone may call.
    ///
    /// @param vault       the market to resolve. Its `resolver` must be this contract.
    /// @param spec        the encoded question. MUST hash to `vault.resolutionSpecHash()`.
    /// @param oracleData  provider-specific signed data. Empty for push oracles.
    ///
    /// @dev Overpayment MUST be refunded: the correct fee is only knowable at call time, so
    ///      callers necessarily over-send, and an adapter that keeps the difference is a
    ///      silent toll on every resolution.
    function resolve(Vault vault, bytes calldata spec, bytes[] calldata oracleData) external payable;

    /// @notice Fee in wei that `resolve` requires for this `oracleData`. Zero for push oracles.
    function resolutionFee(bytes[] calldata oracleData) external view returns (uint256);

    /// @notice Hash of an encoded spec, for binding into `Vault.resolutionSpecHash` at
    ///         market creation.
    /// @dev Domain-separated per adapter, so a spec meant for one oracle cannot be replayed
    ///      against another that happens to share a field layout.
    function specHash(bytes calldata spec) external pure returns (bytes32);
}
