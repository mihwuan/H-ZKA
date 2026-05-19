// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "../libraries/Groth16Verifier.sol";
import "../libraries/Denomination.sol";

/**
 * @title zkCross Exchange Contract (Protocol Φ - HTLC with ZKP)
 * @notice Implements privacy-preserving cross-chain atomic exchange
 * @dev Deployed on each ordinary chain. Handles TxLock, TxUnlock, and TxRefund.
 * 
 * Protocol Φ Flow:
 *   1. Φ.Prepare:  Off-chain - S creates independent hash locks with ZKP
 *   2. Φ.Lock:     S_I locks v_S on Chain I, R_II locks v_R on Chain II
 *   3. Φ.Unlock:   S_II unlocks on Chain II (reveals sn_II), R_I unlocks on Chain I
 *   4. Φ.Refund:   If unlock fails before timeout, assets refunded
 * 
 * Key Innovation: Independent preimages (pre_I, pre_II) instead of shared preimage
 *   - Standard HTLC: same preimage on both chains → linkable
 *   - zkCross: independent preimages linked via sn_II = sn_I XOR Z_256
 * 
 * Reference: zkCross paper Section 5.2 - Protocol Φ
 */
contract ExchangeContract {
    using Groth16Verifier for *;

    // ==========================================
    // Data Structures
    // ==========================================

    /// @notice Lock record for HTLC exchange
    struct LockRecord {
        address locker;         // Who locked the funds (S or R)
        uint256 amount;         // Amount locked (denomination)
        bytes32 hashLock;       // h(pre, sn) - hash lock
        uint256 timeLock;       // T1 or T2 deadline
        bool isUnlocked;        // True if successfully unlocked
        bool isRefunded;        // True if refunded after timeout
    }

    // ==========================================
    // State Variables
    // ==========================================

    /// @notice Verification key for off-chain prepare circuit Λ^off_Φ
    Groth16Verifier.VerifyingKey private vk_phi_off;

    /// @notice Verification key for on-chain unlock circuit Λ^on_Φ
    Groth16Verifier.VerifyingKey private vk_phi_on;

    /// @notice Mapping from lock ID to lock record
    mapping(bytes32 => LockRecord) public locks;

    /// @notice Mapping of used serial numbers (prevent double-unlock)
    mapping(bytes32 => bool) public usedSerialNumbers;

    /// @notice Array of lock IDs for enumeration
    bytes32[] public lockIds;

    /// @notice Contract owner
    address public owner;

    /// @notice Time lock for sender's chain (T1 > T2)
    uint256 public constant TIMELOCK_T1 = 2 hours;

    /// @notice Time lock for receiver's chain (T2 < T1)
    uint256 public constant TIMELOCK_T2 = 1 hours;

    // ==========================================
    // Events
    // ==========================================

    event Locked(
        bytes32 indexed lockId,
        address indexed locker,
        uint256 amount,
        bytes32 hashLock,
        uint256 timeLock
    );

    event Unlocked(
        bytes32 indexed lockId,
        bytes32 indexed serialNumber,
        address indexed unlocker,
        uint256 amount
    );

    event Refunded(
        bytes32 indexed lockId,
        address indexed locker,
        uint256 amount
    );

    event PrepareVerified(
        bytes32 indexed hashLock_I,
        bytes32 indexed hashLock_II,
        bool verified
    );

    // ==========================================
    // Constructor
    // ==========================================

    constructor() {
        owner = msg.sender;
    }

    // ==========================================
    // Admin Functions
    // ==========================================

    /**
     * @notice Set verification keys for Φ circuits
     */
    function setVerifyingKeys(
        // Off-chain prepare VK
        uint256[2] memory alpha_off,
        uint256[2][2] memory beta_off,
        uint256[2][2] memory gamma_off,
        uint256[2][2] memory delta_off,
        uint256[2][] memory ic_off,
        // On-chain unlock VK
        uint256[2] memory alpha_on,
        uint256[2][2] memory beta_on,
        uint256[2][2] memory gamma_on,
        uint256[2][2] memory delta_on,
        uint256[2][] memory ic_on
    ) external {
        require(msg.sender == owner, "Only owner");

        // Set off-chain VK
        vk_phi_off.alpha = Groth16Verifier.G1Point(alpha_off[0], alpha_off[1]);
        vk_phi_off.beta = Groth16Verifier.G2Point(beta_off[0], beta_off[1]);
        vk_phi_off.gamma = Groth16Verifier.G2Point(gamma_off[0], gamma_off[1]);
        vk_phi_off.delta = Groth16Verifier.G2Point(delta_off[0], delta_off[1]);
        delete vk_phi_off.ic;
        for (uint256 i = 0; i < ic_off.length; i++) {
            vk_phi_off.ic.push(Groth16Verifier.G1Point(ic_off[i][0], ic_off[i][1]));
        }

        // Set on-chain VK
        vk_phi_on.alpha = Groth16Verifier.G1Point(alpha_on[0], alpha_on[1]);
        vk_phi_on.beta = Groth16Verifier.G2Point(beta_on[0], beta_on[1]);
        vk_phi_on.gamma = Groth16Verifier.G2Point(gamma_on[0], gamma_on[1]);
        vk_phi_on.delta = Groth16Verifier.G2Point(delta_on[0], delta_on[1]);
        delete vk_phi_on.ic;
        for (uint256 i = 0; i < ic_on.length; i++) {
            vk_phi_on.ic.push(Groth16Verifier.G1Point(ic_on[i][0], ic_on[i][1]));
        }
    }

    // ==========================================
    // Φ.Prepare Verification (Off-chain proof check)
    // ==========================================

    /**
     * @notice Verify the off-chain prepare proof (optional on-chain verification)
     * @param hashLock_I Hash lock for Chain I: h(pre_I, sn_I)
     * @param hashLock_II Hash lock for Chain II: h(pre_II, sn_II)
     * @param pre_I Preimage for Chain I
     * @param pre_II Preimage for Chain II
     * @param Z_256 XOR linking value
     * @param proofA Proof element A
     * @param proofB Proof element B
     * @param proofC Proof element C
     * 
     * @dev Verifies Λ^off_Φ proving:
     *   1. sn_II = sn_I XOR Z_256
     *   2. h(pre_I, sn_I) is correctly computed
     *   3. h(pre_II, sn_II) is correctly computed
     */
    function verifyPrepare(
        bytes32 hashLock_I,
        bytes32 hashLock_II,
        bytes32 pre_I,
        bytes32 pre_II,
        bytes32 Z_256,
        uint256[2] memory proofA,
        uint256[2][2] memory proofB,
        uint256[2] memory proofC
    ) external view returns (bool) {
        Groth16Verifier.Proof memory proof = Groth16Verifier.Proof({
            a: Groth16Verifier.G1Point(proofA[0], proofA[1]),
            b: Groth16Verifier.G2Point(proofB[0], proofB[1]),
            c: Groth16Verifier.G1Point(proofC[0], proofC[1])
        });

        // Public inputs: pre_I, pre_II, Z_256, h(pre_I, sn_I), h(pre_II, sn_II)
        uint256[] memory publicInputs = new uint256[](5);
        publicInputs[0] = uint256(pre_I);
        publicInputs[1] = uint256(pre_II);
        publicInputs[2] = uint256(Z_256);
        publicInputs[3] = uint256(hashLock_I);
        publicInputs[4] = uint256(hashLock_II);

        return Groth16Verifier.verify(vk_phi_off, proof, publicInputs);
    }

    // ==========================================
    // Φ.Lock - Lock assets with hash lock
    // ==========================================

    /**
     * @notice Lock assets for cross-chain exchange
     * @param hashLock h(pre, sn) - the hash lock
     * @param timeLockDuration Duration of timelock in seconds
     * 
     * @dev TxLock = (From: S/R, To: ξ, v, h(pre, sn))
     *      Note: v2 improvement simplifies hash lock to h(pre, sn) (without v) for efficiency.
     *      Original paper defined TxLock = (v, h(pre, sn, v)).
     * 
     * Time lock rules:
     *   - On sender's chain (Chain I): uses T1 (longer)
     *   - On receiver's chain (Chain II): uses T2 (shorter, T2 < T1)
     *   This ensures R cannot lock S's funds indefinitely
     */
    function lock(
        bytes32 hashLock,
        uint256 timeLockDuration
    ) external payable {
        require(msg.value > 0, "Must send ETH");
        require(Denomination.isValidDenomination(msg.value), "Invalid denomination");
        require(timeLockDuration > 0, "Invalid timelock");

        bytes32 lockId = keccak256(abi.encodePacked(
            msg.sender, hashLock, block.number, lockIds.length
        ));

        require(locks[lockId].amount == 0, "Lock ID collision");

        locks[lockId] = LockRecord({
            locker: msg.sender,
            amount: msg.value,
            hashLock: hashLock,
            timeLock: block.timestamp + timeLockDuration,
            isUnlocked: false,
            isRefunded: false
        });

        lockIds.push(lockId);

        emit Locked(lockId, msg.sender, msg.value, hashLock, locks[lockId].timeLock);
    }

    // ==========================================
    // Φ.Unlock - Unlock with ZKP
    // ==========================================

    /**
     * @notice Unlock locked assets using ZKP proof
     * @param lockId The lock to unlock
     * @param serialNumber sn (revealed during unlock)
     * @param merkleRoot Root of block containing TxLock
     * @param proofA Proof element A
     * @param proofB Proof element B
     * @param proofC Proof element C
     * 
     * @dev TxUnlock = (From: S/R, To: ξ, π, sn, v, root_Lock)
     * 
     * The ZKP proves:
     *   1. TxLock exists in the block (Merkle proof)
     *   2. Preimage corresponds to hash lock
     *   3. The unlock is legitimate
     * 
     * When S_II unlocks on Chain II:
     *   - sn_II is revealed
     *   - R_II observes sn_II and computes sn_I = sn_II XOR Z_256
     *   - R_I can then unlock on Chain I using sn_I
     */
    function unlock(
        bytes32 lockId,
        bytes32 serialNumber,
        bytes32 merkleRoot,
        uint256[2] memory proofA,
        uint256[2][2] memory proofB,
        uint256[2] memory proofC
    ) external {
        LockRecord storage record = locks[lockId];

        require(record.amount > 0, "Lock not found");
        require(!record.isUnlocked, "Already unlocked");
        require(!record.isRefunded, "Already refunded");
        require(block.timestamp <= record.timeLock, "Time lock expired");
        require(!usedSerialNumbers[serialNumber], "Serial number already used");

        // Construct proof
        Groth16Verifier.Proof memory proof = Groth16Verifier.Proof({
            a: Groth16Verifier.G1Point(proofA[0], proofA[1]),
            b: Groth16Verifier.G2Point(proofB[0], proofB[1]),
            c: Groth16Verifier.G1Point(proofC[0], proofC[1])
        });

        // Public inputs: sn, v, root_Lock
        uint256[] memory publicInputs = new uint256[](3);
        publicInputs[0] = uint256(serialNumber);
        publicInputs[1] = record.amount;
        publicInputs[2] = uint256(merkleRoot);

        // Verify ZKP
        require(
            Groth16Verifier.verify(vk_phi_on, proof, publicInputs),
            "ZKP verification failed"
        );

        // Mark as unlocked
        record.isUnlocked = true;
        usedSerialNumbers[serialNumber] = true;

        // Transfer funds to unlocker
        (bool success, ) = payable(msg.sender).call{value: record.amount}("");
        require(success, "Transfer failed");

        emit Unlocked(lockId, serialNumber, msg.sender, record.amount);
    }

    // ==========================================
    // Φ.Refund - Reclaim after timeout
    // ==========================================

    /**
     * @notice Refund locked assets after time lock expires
     * @param lockId The lock to refund
     * 
     * @dev If S_II fails to unlock within T2, R_II cannot calculate sn_I,
     *      so both chains refund locked assets after their respective timeouts.
     */
    function refund(bytes32 lockId) external {
        LockRecord storage record = locks[lockId];

        require(record.amount > 0, "Lock not found");
        require(record.locker == msg.sender, "Not the locker");
        require(block.timestamp > record.timeLock, "Time lock not expired");
        require(!record.isUnlocked, "Already unlocked");
        require(!record.isRefunded, "Already refunded");

        record.isRefunded = true;

        (bool success, ) = payable(msg.sender).call{value: record.amount}("");
        require(success, "Transfer failed");

        emit Refunded(lockId, msg.sender, record.amount);
    }

    // ==========================================
    // View Functions
    // ==========================================

    function getLockCount() external view returns (uint256) {
        return lockIds.length;
    }

    function getLockRecord(bytes32 lockId) external view returns (
        address locker, uint256 amount, bytes32 hashLock,
        uint256 timeLock, bool isUnlocked, bool isRefunded
    ) {
        LockRecord memory record = locks[lockId];
        return (record.locker, record.amount, record.hashLock,
                record.timeLock, record.isUnlocked, record.isRefunded);
    }

    function isSerialNumberUsed(bytes32 sn) external view returns (bool) {
        return usedSerialNumbers[sn];
    }

    receive() external payable {}
}
