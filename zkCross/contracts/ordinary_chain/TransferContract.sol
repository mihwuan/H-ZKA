// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "../libraries/Groth16Verifier.sol";
import "../libraries/Denomination.sol";

/**
 * @title zkCross Transfer Contract (Protocol Θ - Burn-Mint)
 * @notice Implements privacy-preserving cross-chain transfers using zk-SNARKs
 * @dev Deployed on each ordinary chain. Handles TxBurn, TxMint, and TxRedeem.
 * 
 * Protocol Θ Flow:
 *   1. Θ.Burn:    Sender locks (burns) assets on Chain I
 *   2. Θ.Transmit: Sender sends Merkle proof to receiver off-chain
 *   3. Θ.Mint:    Receiver claims (mints) assets on Chain II with ZKP
 *   4. Θ.Redeem:  Sender reclaims if mint fails (after timeout T3)
 * 
 * Privacy: Receiver address is hidden inside h(fpk_R, r, sn)
 * Unlinkability: Different chains see different identities
 * 
 * Reference: zkCross paper Section 5.1 - Protocol Θ
 */
contract TransferContract {
    using Groth16Verifier for *;

    // ==========================================
    // Data Structures
    // ==========================================

    /// @notice Burn record: assets locked by sender on source chain
    struct BurnRecord {
        address sender;         // Sender address on this chain
        uint256 amount;         // Denomination amount locked
        bytes32 hashCommitment; // h(fpk_R, r, sn) - hides receiver identity
        uint256 timeLock;       // T3: deadline for receiver to mint
        bool isRedeemed;        // True if sender reclaimed the funds
        bool isClaimed;         // True if receiver minted successfully
    }

    /// @notice Mint record: assets claimed by receiver on destination chain
    struct MintRecord {
        bytes32 serialNumber;   // sn - prevents double-spending
        address receiver;       // Receiver address on this chain
        uint256 amount;         // Amount minted
        uint256 timestamp;      // When the mint occurred
    }

    // ==========================================
    // State Variables
    // ==========================================

    /// @notice Verification key for Circuit Λ_Θ (Mint mode)
    /// @dev Mint: fpk_R is public, fpk_S is private
    Groth16Verifier.VerifyingKey private vk_theta_mint;

    /// @notice Verification key for Circuit Λ_Θ (Redeem mode)
    /// @dev Redeem: fpk_S is public, fpk_R is private (swapped vs Mint)
    ///      Per paper: these are separate circuit instances with different
    ///      public/private input assignments, thus different VKs.
    Groth16Verifier.VerifyingKey private vk_theta_redeem;

    /// @notice Mapping from burn ID to burn record
    mapping(bytes32 => BurnRecord) public burns;

    /// @notice Mapping from serial number to mint status (prevents double-mint)
    mapping(bytes32 => bool) public mintedSerialNumbers;

    /// @notice Mapping from serial number to mint record
    mapping(bytes32 => MintRecord) public mints;

    /// @notice Array of burn IDs for enumeration
    bytes32[] public burnIds;

    /// @notice Contract owner (for admin functions)
    address public owner;

    /// @notice Default time lock duration (e.g., 1 hour)
    uint256 public constant DEFAULT_TIMELOCK = 1 hours;

    // ==========================================
    // Events
    // ==========================================

    event Burned(
        bytes32 indexed burnId,
        address indexed sender,
        uint256 amount,
        bytes32 hashCommitment,
        uint256 timeLock
    );

    event Minted(
        bytes32 indexed serialNumber,
        address indexed receiver,
        uint256 amount
    );

    event Redeemed(
        bytes32 indexed burnId,
        address indexed sender,
        uint256 amount
    );

    // ==========================================
    // Constructor
    // ==========================================

    constructor() {
        owner = msg.sender;
        // Verification key would be set during deployment or via setVerifyingKey
    }

    // ==========================================
    // Admin Functions
    // ==========================================

    /**
     * @notice Set the verification key for Circuit Λ_Θ (Mint mode)
     * @dev Mint mode: fpk_R is public input, fpk_S is private
     */
    function setMintVerifyingKey(
        uint256[2] memory alpha,
        uint256[2][2] memory beta,
        uint256[2][2] memory gamma,
        uint256[2][2] memory delta,
        uint256[2][] memory ic
    ) external {
        require(msg.sender == owner, "Only owner");

        vk_theta_mint.alpha = Groth16Verifier.G1Point(alpha[0], alpha[1]);
        vk_theta_mint.beta = Groth16Verifier.G2Point(beta[0], beta[1]);
        vk_theta_mint.gamma = Groth16Verifier.G2Point(gamma[0], gamma[1]);
        vk_theta_mint.delta = Groth16Verifier.G2Point(delta[0], delta[1]);

        delete vk_theta_mint.ic;
        for (uint256 i = 0; i < ic.length; i++) {
            vk_theta_mint.ic.push(Groth16Verifier.G1Point(ic[i][0], ic[i][1]));
        }
    }

    /**
     * @notice Set the verification key for Circuit Λ_Θ (Redeem mode)
     * @dev Redeem mode: fpk_S is public input, fpk_R is private
     *      This is a DIFFERENT circuit from Mint (different public/private
     *      assignment means different R1CS and verification key).
     */
    function setRedeemVerifyingKey(
        uint256[2] memory alpha,
        uint256[2][2] memory beta,
        uint256[2][2] memory gamma,
        uint256[2][2] memory delta,
        uint256[2][] memory ic
    ) external {
        require(msg.sender == owner, "Only owner");

        vk_theta_redeem.alpha = Groth16Verifier.G1Point(alpha[0], alpha[1]);
        vk_theta_redeem.beta = Groth16Verifier.G2Point(beta[0], beta[1]);
        vk_theta_redeem.gamma = Groth16Verifier.G2Point(gamma[0], gamma[1]);
        vk_theta_redeem.delta = Groth16Verifier.G2Point(delta[0], delta[1]);

        delete vk_theta_redeem.ic;
        for (uint256 i = 0; i < ic.length; i++) {
            vk_theta_redeem.ic.push(Groth16Verifier.G1Point(ic[i][0], ic[i][1]));
        }
    }

    // ==========================================
    // Protocol Θ.Burn - Lock assets on source chain
    // ==========================================

    /**
     * @notice Burn (lock) assets for cross-chain transfer
     * @param hashCommitment h(fpk_R, r, sn) - commitment hiding receiver identity
     * @dev TxBurn = (From: S, To: ξ, v_S, h(fpk_R, r, sn))
     * 
     * The sender locks denomination amount with a hash commitment.
     * The hash hides the receiver's public key, preventing CLE attacks.
     */
    function burn(bytes32 hashCommitment) external payable {
        require(msg.value > 0, "Must send ETH");
        require(Denomination.isValidDenomination(msg.value), "Invalid denomination");

        // Generate unique burn ID
        bytes32 burnId = keccak256(abi.encodePacked(
            msg.sender, hashCommitment, block.number, burnIds.length
        ));

        require(burns[burnId].amount == 0, "Burn ID collision");

        // Create burn record
        burns[burnId] = BurnRecord({
            sender: msg.sender,
            amount: msg.value,
            hashCommitment: hashCommitment,
            timeLock: block.timestamp + DEFAULT_TIMELOCK,
            isRedeemed: false,
            isClaimed: false
        });

        burnIds.push(burnId);

        emit Burned(burnId, msg.sender, msg.value, hashCommitment, burns[burnId].timeLock);
    }

    /**
     * @notice Burn an arbitrary amount by splitting into fixed-denomination sub-burns
     * @param hashCommitments Array of h(fpk_R, r_i, sn_i) — one per sub-transfer
     * @dev Per paper Section 5.2.1 / Theorem 1: to preserve unlinkability, arbitrary
     *      amounts are decomposed into multiple fixed-denomination transfers.
     *      E.g. 6 ETH → 6 × burn(1 ETH), each with a unique (r_i, sn_i).
     *      This ensures every burn has the same denomination as others in its tier,
     *      maximizing the anonymity set.
     *
     * The caller must:
     *   1. Call Denomination.decompose(amount) off-chain to know the split
     *   2. Generate a unique (r_i, sn_i) pair for each sub-transfer
     *   3. Compute h(fpk_R, r_i, sn_i) for each sub-transfer
     *   4. Pass the ordered hashCommitments matching the denomination order
     *
     * Returns burnIds array so the sender can transmit them to the receiver.
     */
    function burnSplit(bytes32[] calldata hashCommitments) external payable returns (bytes32[] memory) {
        require(msg.value > 0, "Must send ETH");

        // Decompose the total amount into fixed denominations
        (uint256[6] memory denomCounts, uint256 remainder) = Denomination.decompose(msg.value);
        require(remainder == 0, "Amount not decomposable into supported denominations");

        // Count total sub-transfers
        uint256 totalSubs = 0;
        for (uint256 i = 0; i < 6; i++) {
            totalSubs += denomCounts[i];
        }
        require(hashCommitments.length == totalSubs, "Incorrect number of hash commitments");

        bytes32[] memory newBurnIds = new bytes32[](totalSubs);
        uint256 subIndex = 0;

        // Create individual burns from largest to smallest denomination
        for (uint256 tier = 6; tier > 0; tier--) {
            uint256 idx = tier - 1;
            for (uint256 j = 0; j < denomCounts[idx]; j++) {
                newBurnIds[subIndex] = _createBurn(
                    hashCommitments[subIndex],
                    Denomination.getDenomination(idx)
                );
                subIndex++;
            }
        }

        return newBurnIds;
    }

    /// @dev Internal helper for burnSplit to avoid stack-too-deep
    function _createBurn(bytes32 hashCommitment, uint256 denomValue) internal returns (bytes32) {
        bytes32 burnId = keccak256(abi.encodePacked(
            msg.sender, hashCommitment, block.number, burnIds.length
        ));
        require(burns[burnId].amount == 0, "Burn ID collision");

        burns[burnId] = BurnRecord({
            sender: msg.sender,
            amount: denomValue,
            hashCommitment: hashCommitment,
            timeLock: block.timestamp + DEFAULT_TIMELOCK,
            isRedeemed: false,
            isClaimed: false
        });

        burnIds.push(burnId);
        emit Burned(burnId, msg.sender, denomValue, hashCommitment, block.timestamp + DEFAULT_TIMELOCK);
        return burnId;
    }

    // ==========================================
    // Protocol Θ.Mint - Claim assets on destination chain
    // ==========================================

    /**
     * @notice Mint (claim) assets on destination chain with ZKP
     * @param serialNumber sn - unique serial number (prevents double-spending)
     * @param amount Transfer amount (must match burned amount)
     * @param merkleRoot Root of the block containing TxBurn on source chain
     * @param proofA Proof element A (G1 point)
     * @param proofB Proof element B (G2 point)
     * @param proofC Proof element C (G1 point)
     * 
     * @dev TxMint = (From: R, To: ξ, π, fpk_R, sn, v, root_Burn)
     * 
     * The ZKP proves:
     *   1. h(fpk_R, r, sn) is correctly formed
     *   2. TxBurn exists in the block (Merkle proof)
     *   3. Amount is consistent
     * Without revealing: fpk_S, addr_ξ, r, Merkle path
     */
    function mint(
        bytes32 serialNumber,
        uint256 amount,
        bytes32 merkleRoot,
        uint256[2] memory proofA,
        uint256[2][2] memory proofB,
        uint256[2] memory proofC
    ) external {
        require(!mintedSerialNumbers[serialNumber], "Serial number already used");
        require(Denomination.isValidDenomination(amount), "Invalid denomination");
        require(address(this).balance >= amount, "Insufficient contract balance");

        // Construct ZKP proof
        Groth16Verifier.Proof memory proof = Groth16Verifier.Proof({
            a: Groth16Verifier.G1Point(proofA[0], proofA[1]),
            b: Groth16Verifier.G2Point(proofB[0], proofB[1]),
            c: Groth16Verifier.G1Point(proofC[0], proofC[1])
        });

        // Public inputs: fpk_R (as uint256), sn, v_S, root_Burn
        uint256[] memory publicInputs = new uint256[](4);
        publicInputs[0] = uint256(uint160(msg.sender)); // fpk_R (simplified to address)
        publicInputs[1] = uint256(serialNumber);
        publicInputs[2] = amount;
        publicInputs[3] = uint256(merkleRoot);

        // Verify ZKP: Π.Verify(vk_θ_mint, x, π)
        // Mint mode: fpk_R is public (receiver proves they're entitled to claim)
        require(
            Groth16Verifier.verify(vk_theta_mint, proof, publicInputs),
            "ZKP verification failed"
        );

        // Mark serial number as used (prevent double-mint)
        mintedSerialNumbers[serialNumber] = true;

        // Record mint
        mints[serialNumber] = MintRecord({
            serialNumber: serialNumber,
            receiver: msg.sender,
            amount: amount,
            timestamp: block.timestamp
        });

        // Transfer funds to receiver
        (bool success, ) = payable(msg.sender).call{value: amount}("");
        require(success, "Transfer failed");

        emit Minted(serialNumber, msg.sender, amount);
    }

    // ==========================================
    // Protocol Θ.Redeem - Reclaim after timeout
    // ==========================================

    /**
     * @notice Redeem (reclaim) assets if mint did not occur before timeout
     * @param burnId The burn ID to redeem
     * @param serialNumber sn used in the original burn
     * @param proofA Proof element A
     * @param proofB Proof element B
     * @param proofC Proof element C
     * 
     * @dev TxRedeem = (From: S, To: ξ, π, fpk_S, sn, v, root_Burn)
     * 
     * Same circuit Λ_Θ but with swapped public/private:
     *   Public: fpk_S (sender), sn, v, root_Burn
     *   Private: fpk_R (receiver), addr_ξ, r, Merkle path
     */
    function redeem(
        bytes32 burnId,
        bytes32 serialNumber,
        uint256[2] memory proofA,
        uint256[2][2] memory proofB,
        uint256[2] memory proofC
    ) external {
        BurnRecord storage record = burns[burnId];
        
        require(record.amount > 0, "Burn not found");
        require(record.sender == msg.sender, "Not the sender");
        require(block.timestamp > record.timeLock, "Time lock not expired");
        require(!record.isRedeemed, "Already redeemed");
        require(!record.isClaimed, "Already claimed");

        // Construct ZKP proof (same circuit, different public/private assignment)
        Groth16Verifier.Proof memory proof = Groth16Verifier.Proof({
            a: Groth16Verifier.G1Point(proofA[0], proofA[1]),
            b: Groth16Verifier.G2Point(proofB[0], proofB[1]),
            c: Groth16Verifier.G1Point(proofC[0], proofC[1])
        });

        // Public inputs for Redeem: fpk_S is public, fpk_R is private
        // (OPPOSITE of Mint mode, per paper Section 5.1)
        uint256[] memory publicInputs = new uint256[](4);
        publicInputs[0] = uint256(uint160(msg.sender)); // fpk_S (sender)
        publicInputs[1] = uint256(serialNumber);
        publicInputs[2] = record.amount;
        publicInputs[3] = uint256(record.hashCommitment); // root reference

        // Verify ZKP: Π.Verify(vk_θ_redeem, x, π)
        // Redeem mode uses SEPARATE VK because public/private inputs are swapped
        require(
            Groth16Verifier.verify(vk_theta_redeem, proof, publicInputs),
            "ZKP verification failed"
        );

        // Mark as redeemed
        record.isRedeemed = true;

        // Return funds to sender
        (bool success, ) = payable(msg.sender).call{value: record.amount}("");
        require(success, "Transfer failed");

        emit Redeemed(burnId, msg.sender, record.amount);
    }

    // ==========================================
    // View Functions
    // ==========================================

    /// @notice Get total number of burn records
    function getBurnCount() external view returns (uint256) {
        return burnIds.length;
    }

    /// @notice Check if a serial number has been minted
    function isSerialNumberUsed(bytes32 sn) external view returns (bool) {
        return mintedSerialNumbers[sn];
    }

    /// @notice Get burn record by ID
    function getBurnRecord(bytes32 burnId) external view returns (
        address sender, uint256 amount, bytes32 hashCommitment,
        uint256 timeLock, bool isRedeemed, bool isClaimed
    ) {
        BurnRecord memory record = burns[burnId];
        return (record.sender, record.amount, record.hashCommitment,
                record.timeLock, record.isRedeemed, record.isClaimed);
    }

    /// @notice Allow contract to receive ETH (for staking/funding)
    receive() external payable {}
}
