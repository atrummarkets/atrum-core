// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {IPyth, PythPrice, PythPriceFeed} from "../../src/interfaces/IPyth.sol";

/// @dev Stand-in for Pyth. Models the parts `PythResolver` depends on and nothing else.
///
///      It deliberately DOES enforce the publish-time window and DOES charge the fee, because
///      a mock that waves those through would let a resolver bug pass unnoticed -- the two
///      things most worth asserting are that the resolver respects the window it committed to
///      and pays exactly the fee it was quoted.
contract MockPyth is IPyth {
    uint256 public fee = 1 wei;

    PythPrice internal stored;
    bytes32 internal storedId;

    /// @notice Set to make the next parse return a feed id that was not requested, for the
    ///         defence-in-depth check in the resolver.
    bytes32 public overrideReturnedId;

    /// @notice Set to make the next parse return an empty array.
    bool public returnEmpty;

    /// @notice Last window the resolver asked for, so tests can assert it was not widened.
    uint64 public lastMinPublishTime;
    uint64 public lastMaxPublishTime;
    uint256 public lastValueReceived;

    function setFee(uint256 fee_) external {
        fee = fee_;
    }

    function setPrice(bytes32 id, int64 price, uint64 conf, int32 expo, uint256 publishTime) external {
        storedId = id;
        stored = PythPrice({price: price, conf: conf, expo: expo, publishTime: publishTime});
    }

    function setOverrideReturnedId(bytes32 id) external {
        overrideReturnedId = id;
    }

    function setReturnEmpty(bool v) external {
        returnEmpty = v;
    }

    function getUpdateFee(bytes[] calldata) external view returns (uint256) {
        return fee;
    }

    function parsePriceFeedUpdatesUnique(
        bytes[] calldata,
        bytes32[] calldata priceIds,
        uint64 minPublishTime,
        uint64 maxPublishTime
    ) external payable returns (PythPriceFeed[] memory feeds) {
        require(msg.value >= fee, "MockPyth: fee");
        lastValueReceived = msg.value;
        lastMinPublishTime = minPublishTime;
        lastMaxPublishTime = maxPublishTime;

        // Real Pyth reverts when nothing lands in range. Modelled, because the resolver's
        // whole liveness story depends on it happening rather than a stale price coming back.
        require(
            stored.publishTime >= minPublishTime && stored.publishTime <= maxPublishTime, "PriceFeedNotFoundWithinRange"
        );

        if (returnEmpty) return new PythPriceFeed[](0);

        feeds = new PythPriceFeed[](1);
        feeds[0] = PythPriceFeed({
            id: overrideReturnedId == bytes32(0) ? priceIds[0] : overrideReturnedId, price: stored, emaPrice: stored
        });
    }

    function parsePriceFeedUpdates(bytes[] calldata, bytes32[] calldata, uint64, uint64)
        external
        payable
        returns (PythPriceFeed[] memory)
    {
        revert("MockPyth: resolver must use the Unique variant");
    }

    function getPriceNoOlderThan(bytes32, uint256) external view returns (PythPrice memory) {
        return stored;
    }

    function getValidTimePeriod() external pure returns (uint256) {
        return 60;
    }
}
