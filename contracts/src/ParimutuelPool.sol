// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

/// @title ParimutuelPool
/// @notice Public per-market stake totals and pro-rata settlement.
///
/// @dev Parimutuel is forced, not chosen. Additive ElGamal does addition and nothing
///      else -- no comparison, no multiplication -- so no matching engine can exist
///      over encrypted stakes. The market design follows from the cryptography.
///
///      In Phase 1 these totals are PUBLIC, which is the honest limit of the milestone:
///      positions are shielded, the pool is not. Phase 2 replaces `yesUnits`/`noUnits`
///      with ElGamal ciphertexts summed by two point additions and never decrypted
///      on-chain. The arithmetic below is written so that swap changes the storage type
///      and nothing else.
///
///      Consequences of parimutuel worth stating, because they shape the product:
///        - Exit needs no counterparty: betting the other side is an exact hedge.
///        - There is no mark-to-market P&L. A position is always worth its stake under
///          market-implied probability, so "cash out at fair value" IS "refund stake".
///        - Zero price impact, so the usual slippage argument for limit orders does not
///          apply.
///        - Capital is committed until resolution. That one is irreducible.
contract ParimutuelPool {
    /// @notice The only contract allowed to move stake. Set once, at construction.
    address public immutable pool;

    struct Market {
        uint128 yesUnits;
        uint128 noUnits;
    }

    /// @dev Packed into one slot: both sides are read and written together on every
    ///      bet, and Monad charges 8,100 for a cold SLOAD -- four times Ethereum. Two
    ///      separate uint256 mappings would double the cold reads on the hot path.
    mapping(uint32 => Market) public markets;

    event StakeAdded(uint32 indexed marketId, uint8 outcome, uint256 units);

    error NotPool();
    error InvalidOutcome();
    error UnitsOverflow();
    error NoWinningStake();

    modifier onlyPool() {
        if (msg.sender != pool) revert NotPool();
        _;
    }

    constructor(address pool_) {
        pool = pool_;
    }

    /// @notice Add `units` to one side of `marketId`.
    /// @param outcome 1 = YES, 2 = NO. 0 is rejected: unbet collateral is not stake and
    ///        must not move the published odds.
    function addStake(uint32 marketId, uint8 outcome, uint256 units) external onlyPool {
        if (outcome != 1 && outcome != 2) revert InvalidOutcome();
        if (units > type(uint128).max) revert UnitsOverflow();

        Market storage m = markets[marketId];
        if (outcome == 1) {
            m.yesUnits += uint128(units);
        } else {
            m.noUnits += uint128(units);
        }

        emit StakeAdded(marketId, outcome, units);
    }

    /// @notice Total staked across both sides.
    function totalUnits(uint32 marketId) public view returns (uint256) {
        Market memory m = markets[marketId];
        return uint256(m.yesUnits) + uint256(m.noUnits);
    }

    /// @notice Implied probability of YES, in basis points.
    /// @dev This is the number the market publishes. Under parimutuel it is exactly the
    ///      share of stake on YES -- there is no order book to derive a price from, and
    ///      no price impact, so the pool ratio IS the odds.
    function yesProbabilityBps(uint32 marketId) external view returns (uint256) {
        uint256 total = totalUnits(marketId);
        if (total == 0) return 0;
        return uint256(markets[marketId].yesUnits) * 10_000 / total;
    }

    /// @notice Units of collateral owed to a winning position of `units`.
    ///
    /// @dev `units * total / winning`. Winners divide the entire staked pool, including
    ///      the losing side, in proportion to their own stake.
    ///
    ///      Solvency: summed over every winning position this is
    ///      `winning * total / winning == total`, exactly the staked collateral held.
    ///      Integer division truncates each payout down, so the sum can only come in
    ///      under `total`, never over -- the pool cannot be drained past what it holds.
    ///      The truncated remainder stays in the contract as dust rather than being
    ///      distributed, which is deliberate: distributing it would need an ordering
    ///      over redemptions, and any such ordering leaks information about who
    ///      redeemed when.
    function payoutUnits(uint32 marketId, uint8 winningOutcome, uint256 units) external view returns (uint256) {
        if (winningOutcome != 1 && winningOutcome != 2) revert InvalidOutcome();

        Market memory m = markets[marketId];
        uint256 winning = winningOutcome == 1 ? uint256(m.yesUnits) : uint256(m.noUnits);
        if (winning == 0) revert NoWinningStake();

        uint256 total = uint256(m.yesUnits) + uint256(m.noUnits);
        return units * total / winning;
    }
}
