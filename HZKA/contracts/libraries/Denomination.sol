// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title Denomination Library for zkCross
 * @notice Manages fixed-denomination transfers for privacy preservation
 * @dev Transfer amounts are split into fixed denominations to prevent
 *      amount-based linkability attacks. All sub-transactions have the 
 *      same amount, increasing the anonymity set.
 * 
 * Reference: zkCross paper Section 5.1 - Denomination mechanism
 */
library Denomination {
    /// @notice Supported denominations in wei
    /// @dev Using powers of 10 for simplicity. In production, these would be
    ///      chosen based on expected transaction volume for each denomination tier.
    uint256 constant DENOM_1   = 0.001 ether;  // 1e15 wei
    uint256 constant DENOM_2   = 0.01 ether;   // 1e16 wei
    uint256 constant DENOM_3   = 0.1 ether;    // 1e17 wei
    uint256 constant DENOM_4   = 1 ether;      // 1e18 wei
    uint256 constant DENOM_5   = 10 ether;     // 1e19 wei
    uint256 constant DENOM_6   = 100 ether;    // 1e20 wei

    uint256 constant NUM_DENOMINATIONS = 6;

    /**
     * @notice Decompose an amount into fixed denominations
     * @param amount The total amount to decompose
     * @return denomCounts Array of counts for each denomination tier
     * @return remainder Amount that couldn't be decomposed (should be 0)
     */
    function decompose(uint256 amount) 
        internal pure returns (uint256[6] memory denomCounts, uint256 remainder) 
    {
        remainder = amount;

        // Greedy decomposition from largest to smallest
        denomCounts[5] = remainder / DENOM_6;
        remainder -= denomCounts[5] * DENOM_6;

        denomCounts[4] = remainder / DENOM_5;
        remainder -= denomCounts[4] * DENOM_5;

        denomCounts[3] = remainder / DENOM_4;
        remainder -= denomCounts[3] * DENOM_4;

        denomCounts[2] = remainder / DENOM_3;
        remainder -= denomCounts[2] * DENOM_3;

        denomCounts[1] = remainder / DENOM_2;
        remainder -= denomCounts[1] * DENOM_2;

        denomCounts[0] = remainder / DENOM_1;
        remainder -= denomCounts[0] * DENOM_1;
    }

    /**
     * @notice Check if an amount is a valid denomination
     * @param amount The amount to check
     * @return True if the amount is one of the supported denominations
     */
    function isValidDenomination(uint256 amount) internal pure returns (bool) {
        return (amount == DENOM_1 || amount == DENOM_2 || amount == DENOM_3 ||
                amount == DENOM_4 || amount == DENOM_5 || amount == DENOM_6);
    }

    /**
     * @notice Get denomination value by index
     */
    function getDenomination(uint256 index) internal pure returns (uint256) {
        if (index == 0) return DENOM_1;
        if (index == 1) return DENOM_2;
        if (index == 2) return DENOM_3;
        if (index == 3) return DENOM_4;
        if (index == 4) return DENOM_5;
        if (index == 5) return DENOM_6;
        revert("Invalid denomination index");
    }

    /**
     * @notice Compute the total number of sub-transfers needed for an amount
     * @dev Per paper Section 5.2.1 / Theorem 1: arbitrary amounts are split into
     *      multiple fixed-denomination transfers to ensure unlinkability.
     *      E.g. 6 ETH → 6 × 1 ETH transfers; 15.23 ETH → 1×10 + 5×1 + 2×0.1 + 3×0.01
     * @param amount The total amount to split
     * @return count Total number of sub-transfers (sum of decomposition counts)
     */
    function totalSubTransfers(uint256 amount) internal pure returns (uint256 count) {
        (uint256[6] memory denomCounts, ) = decompose(amount);
        for (uint256 i = 0; i < 6; i++) {
            count += denomCounts[i];
        }
    }

    /**
     * @notice Get the list of denomination values for an amount decomposition
     * @dev Returns an array of denomination amounts, one per sub-transfer.
     *      Caller must provide a sufficiently large maxCount.
     * @param amount The total amount to decompose
     * @param maxCount Maximum expected sub-transfers (to size the return array)
     * @return values Array of denomination values for each sub-transfer
     * @return actualCount Actual number of sub-transfers
     */
    function listSubTransfers(uint256 amount, uint256 maxCount)
        internal pure returns (uint256[] memory values, uint256 actualCount)
    {
        (uint256[6] memory denomCounts, ) = decompose(amount);
        values = new uint256[](maxCount);
        actualCount = 0;

        // Iterate from largest to smallest denomination
        for (uint256 tier = 6; tier > 0; tier--) {
            uint256 idx = tier - 1;
            uint256 denomValue = getDenomination(idx);
            for (uint256 j = 0; j < denomCounts[idx]; j++) {
                require(actualCount < maxCount, "Too many sub-transfers");
                values[actualCount] = denomValue;
                actualCount++;
            }
        }
    }
}
