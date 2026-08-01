// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

/// @notice A Pyth aggregate price.
/// @dev The real value is `price * 10**expo`. `expo` is normally negative (-8 for BTC/USD),
///      and it is NOT constant across feeds or guaranteed constant over time -- which is why
///      every comparison against it must normalise rather than assume a scale.
struct PythPrice {
    /// @dev Signed. Rare in practice, but oil futures went negative in 2020 and the type
    ///      allows it, so nothing here may assume positivity.
    int64 price;
    /// @dev Aggregate confidence interval. The price is roughly `price ± conf`.
    uint64 conf;
    int32 expo;
    uint256 publishTime;
}

struct PythPriceFeed {
    bytes32 id;
    PythPrice price;
    PythPrice emaPrice;
}

/// @notice The subset of Pyth's interface this repo uses.
///
/// @dev Hand-written rather than pulled in as a dependency, matching how every other
///      external surface in this repo is declared: a narrow interface is auditable in one
///      screen, and a fat SDK brings transitive code into a contract that holds collateral.
///
///      Verified live on Monad testnet at `0x2880aB155794e7179c9eE2e38200202908C17B43`:
///      `getValidTimePeriod()` returns 60 and `getPriceUnsafe` returns a real BTC/USD
///      aggregate.
interface IPyth {
    /// @notice Fee, in wei, required to submit `updateData`.
    function getUpdateFee(bytes[] calldata updateData) external view returns (uint256);

    /// @notice Verify signed price updates and return the FIRST feed at or after
    ///         `minPublishTime`, proving no earlier one exists in the window.
    ///
    /// @dev USE THIS, NOT `parsePriceFeedUpdates`. Both verify Pyth's signatures and both
    ///      enforce the window, but only this one pins WHICH update is used:
    ///
    ///          prevPublishTime < minPublishTime <= publishTime <= maxPublishTime
    ///
    ///      The plain variant accepts ANY update inside the window, and the caller is the one
    ///      who chooses what to submit. Pyth publishes roughly every 400ms, so a 60-second
    ///      window holds ~150 candidates; a caller can fetch them all, keep the one that
    ///      makes their side win, and submit only that. Resolution is permissionless, so the
    ///      caller can be a bettor. This variant removes the choice entirely.
    function parsePriceFeedUpdatesUnique(
        bytes[] calldata updateData,
        bytes32[] calldata priceIds,
        uint64 minPublishTime,
        uint64 maxPublishTime
    ) external payable returns (PythPriceFeed[] memory priceFeeds);

    /// @notice Any update inside the window. NOT used for resolution -- see above.
    function parsePriceFeedUpdates(
        bytes[] calldata updateData,
        bytes32[] calldata priceIds,
        uint64 minPublishTime,
        uint64 maxPublishTime
    ) external payable returns (PythPriceFeed[] memory priceFeeds);

    /// @notice Latest price, reverting if older than `getValidTimePeriod()`.
    function getPriceNoOlderThan(bytes32 id, uint256 age) external view returns (PythPrice memory);

    function getValidTimePeriod() external view returns (uint256);
}
