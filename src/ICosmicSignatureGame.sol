// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/// @notice Minimal read-only view of the CosmicSignatureGame contract
/// (proxy 0x6a714Ae7B5b6eA520F6BCA23d2E609C4Fd5863F2 on Arbitrum One).
/// Only the three getters the market needs for creation and resolution.
interface ICosmicSignatureGame {
    /// @notice Bidding round counter. Starts at 0 and increments when a round's
    /// main prize is claimed, which is the moment a round ends for good.
    function roundNum() external view returns (uint256);

    /// @notice Auto-generated getter of `mapping(uint256 => BidderAddresses)`.
    /// Returns the struct's `numItems` member: the total number of bids
    /// ("gestures") placed in the given round so far. Once the round is over
    /// (roundNum advanced past it), this value is final.
    function bidderAddresses(uint256 roundNum) external view returns (uint256 numItems);

    /// @notice The CosmicSignatureToken (CST) contract address.
    function token() external view returns (address);
}
