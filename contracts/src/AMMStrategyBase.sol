// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAMMStrategy, TradeInfo} from "./IAMMStrategy.sol";

/// @title AMM Strategy Base Contract
/// @notice Base contract that all user strategies must inherit from
/// @dev Provides fixed storage slots, helper functions, and fee clamping
abstract contract AMMStrategyBase is IAMMStrategy {
    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice 1e18 - represents 100% in WAD precision
    uint256 public constant WAD = 1e18;

    /// @notice Maximum allowed fee: 10% (1e17)
    uint256 public constant MAX_FEE = WAD / 10;

    /// @notice Minimum allowed fee: 0
    uint256 public constant MIN_FEE = 0;

    /// @notice 1 basis point in WAD (0.01% = 0.0001 = 1e14)
    uint256 public constant BPS = 1e14;

    /*//////////////////////////////////////////////////////////////
                            STORAGE SLOTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Fixed storage array - strategies can only use these 32 slots
    /// @dev This provides 1KB of persistent storage per strategy
    /// @dev Slot access is validated at the EVM level (array bounds)
    uint256[32] public slots;

    /*//////////////////////////////////////////////////////////////
                            HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Multiply two WAD values
    /// @param x First value (WAD)
    /// @param y Second value (WAD)
    /// @return Result in WAD precision
    function wmul(uint256 x, uint256 y) internal pure returns (uint256) {
        return (x * y) / WAD;
    }

    /// @notice Divide two WAD values
    /// @param x Numerator (WAD)
    /// @param y Denominator (WAD)
    /// @return Result in WAD precision
    function wdiv(uint256 x, uint256 y) internal pure returns (uint256) {
        return (x * WAD) / y;
    }

    /// @notice Clamp a value between min and max
    /// @param value Value to clamp
    /// @param minVal Minimum value
    /// @param maxVal Maximum value
    /// @return Clamped value
    function clamp(uint256 value, uint256 minVal, uint256 maxVal) internal pure returns (uint256) {
        if (value < minVal) return minVal;
        if (value > maxVal) return maxVal;
        return value;
    }

    /// @notice Convert basis points to WAD
    /// @param bps Basis points (1 bps = 0.01%)
    /// @return WAD value
    function bpsToWad(uint256 bps) internal pure returns (uint256) {
        return bps * BPS;
    }

    /// @notice Convert WAD to basis points
    /// @param wadValue WAD value
    /// @return Basis points
    function wadToBps(uint256 wadValue) internal pure returns (uint256) {
        return wadValue / BPS;
    }

    /// @notice Clamp fee to valid range [0, MAX_FEE]
    /// @param fee Fee value to clamp
    /// @return Clamped fee value
    function clampFee(uint256 fee) internal pure returns (uint256) {
        return clamp(fee, MIN_FEE, MAX_FEE);
    }

    /// @notice Calculate absolute difference between two values
    /// @param a First value
    /// @param b Second value
    /// @return Absolute difference
    function absDiff(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : b - a;
    }

    /// @notice Simple integer square root (Babylonian method)
    /// @param x Value to take sqrt of
    /// @return y Square root
    function sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }

    /*//////////////////////////////////////////////////////////////
                          SLOT HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Read a slot value
    /// @param index Slot index (0-31)
    /// @return Value stored in the slot
    function readSlot(uint256 index) internal view returns (uint256) {
        require(index < 32, "Slot index out of bounds");
        return slots[index];
    }

    /// @notice Write a value to a slot
    /// @param index Slot index (0-31)
    /// @param value Value to store
    function writeSlot(uint256 index, uint256 value) internal {
        require(index < 32, "Slot index out of bounds");
        slots[index] = value;
    }
}
