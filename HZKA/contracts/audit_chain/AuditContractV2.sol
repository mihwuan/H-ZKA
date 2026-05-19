// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "../libraries/Groth16Verifier.sol";
import "./ReputationRegistry.sol";
import "./ClusterManager.sol";

/**
 * @title AuditContractV2 — zkCross Protocol Ψ with MF-PoP + Hierarchical Clustering
 *
 * @notice Extended Protocol Ψ that integrates:
 *   1. MF-PoP reputation-weighted proof acceptance (Ψ.WeightedAudit)
 *   2. Cluster-level aggregated commit pathway   (O(√k) vs O(k))
 *
 * RESEARCH GAPS ADDRESSED:
 *
 *   GAP 1 — Weak Trust Assumption (zkCross §4.1):
 *     Original: "at least one honest committer per ordinary chain" — no enforcement.
 *     A malicious CT submits fake root_new; no on-chain mechanism detects it.
 *     Fix (Ψ.WeightedAudit): Accepts root only when Σ_{i: r_i=r} w_i ≥ 2/3·Σ w_j
 *     where w_i = R²_i (quadratic weight from MF-PoP).
 *     Reference: improvement doc §1.3.4, EdgeTrust-Shard JSA 2026 Theorem 2
 *
 *   GAP 2 — Flat O(k) Audit Topology (zkCross §3.2, §7.2.2):
 *     Original: k chains → 1 audit chain, O(k) proofs per auditor per round.
 *     Fix: M=√k clusters each submit 1 aggregated proof → O(√k) on global chain.
 *     Reference: improvement doc §2, EdgeTrust-Shard JSA 2026 §4
 *
 * PAPER CITATIONS:
 *   [1] zkCross, USENIX Security 2024, §4.1 — Committer incentive mechanism
 *   [2] zkCross, USENIX Security 2024, §5.3 — Protocol Ψ steps
 *   [3] EdgeTrust-Shard, JSA 2026, §3.2  — MF-PoP reputation mechanism
 *   [4] EdgeTrust-Shard, JSA 2026, §4    — Hierarchical Cluster Architecture
 *   [5] zkcross_v2_improvement.pdf, §1.3.4 — Ψ.WeightedAudit algorithm
 *   [6] zkcross_v2_improvement.pdf, §3.1  — Integrated end-to-end flow
 */
contract AuditContractV2 {

    // ==========================================
    // Data Structures
    // ==========================================

    struct ChainInfo {
        uint256 chainId;
        bytes32 latestStateRoot;
        uint256 lastUpdateBlock;
        uint256 totalCommits;
        bool    isActive;
    }

    /// @notice Enhanced commit record with reputation snapshot and cluster info
    /// @dev Extends zkCross §5.3 CommitRecord with reputation metadata for MF-PoP
    struct CommitRecord {
        address  committer;
        uint256  chainId;
        uint256  clusterId;          // Which cluster submitted this (0 = direct)
        bytes32  oldStateRoot;
        bytes32  newStateRoot;
        uint256  timestamp;
        bool     isVerified;
        uint256  reputationAtSubmit; // R_i at time of submission (fixed-point ×1e18)
    }

    /// @notice Weighted submission for Ψ.WeightedAudit cross-reference pools
    /// @dev w_i = R²_i tracked per committer submission; see improvement doc §1.3.4
    struct WeightedSubmission {
        address  committer;
        bytes32  submittedRoot;
        uint256  weight;             // R²_i / PRECISION at submission time
    }

    // ==========================================
    // State Variables
    // ==========================================

    Groth16Verifier.VerifyingKey private vk_psi;

    /// @notice If true, skip actual ZKP verification (for testing with mock proofs)
    bool public useMockVerifier = false;

    mapping(uint256 => ChainInfo)   public chains;
    uint256[]                       public chainList;

    mapping(bytes32 => CommitRecord)          public commits;
    bytes32[]                                 public commitIds;

    /// @notice Weighted commit pools: groupId => array of weighted submissions
    /// groupId = keccak256(abi.encode(chainId, blockStart, blockEnd))
    /// Enables Ψ.WeightedAudit cross-reference (improvement doc §1.3.4)
    mapping(bytes32 => WeightedSubmission[])  public commitGroups;

    ReputationRegistry public immutable reputationRegistry;
    ClusterManager     public immutable clusterManager;

    uint256 public rewardPerCommit     = 0.001 ether;
    uint256 public constant MIN_STAKE  = 1 ether;

    mapping(address => uint256) public committerStakes;
    mapping(address => bool)    public auditors;
    uint256                     public auditorCount;
    address                     public owner;

    // ==========================================
    // Events
    // ==========================================

    event ChainRegistered(uint256 indexed chainId, bytes32 initialRoot);
    event CommitterStaked(address indexed committer, uint256 amount);
    event CommitSubmitted(
        bytes32 indexed commitId,
        address indexed committer,
        uint256 indexed chainId,
        bytes32 oldRoot,
        bytes32 newRoot,
        uint256 reputationSnapshot
    );
    event CommitVerified(bytes32 indexed commitId, address indexed committer, uint256 reward);
    event WeightedAuditAccepted(bytes32 indexed groupId, bytes32 acceptedRoot, uint256 totalWeight, uint256 acceptedWeight);
    event ClusterCommitAccepted(bytes32 indexed clusterCommitId, uint256 indexed clusterId, uint256 chainsCount);

    // ==========================================
    // Constructor
    // ==========================================

    constructor(address _reputationRegistry, address _clusterManager) {
        owner                = msg.sender;
        auditors[msg.sender] = true;
        auditorCount         = 1;
        reputationRegistry   = ReputationRegistry(_reputationRegistry);
        clusterManager       = ClusterManager(_clusterManager);
    }

    // ==========================================
    // Chain & Committer Management
    // ==========================================

    function registerChain(uint256 chainId, bytes32 initialRoot) external {
        require(msg.sender == owner, "Not owner");
        require(!chains[chainId].isActive, "Already registered");
        chains[chainId] = ChainInfo({
            chainId:         chainId,
            latestStateRoot: initialRoot,
            lastUpdateBlock: block.number,
            totalCommits:    0,
            isActive:        true
        });
        chainList.push(chainId);
        emit ChainRegistered(chainId, initialRoot);
    }

    function stake() external payable {
        require(msg.value >= MIN_STAKE, "Insufficient stake");
        committerStakes[msg.sender] += msg.value;
        emit CommitterStaked(msg.sender, msg.value);
    }

    function addAuditor(address auditor) external {
        require(msg.sender == owner, "Not owner");
        if (!auditors[auditor]) {
            auditors[auditor] = true;
            auditorCount++;
        }
    }

    // ==========================================
    // Ψ.Commit — Enhanced Single Committer Submission
    // ==========================================

    /**
     * @notice Submit a commit for an ordinary chain (Ψ.Commit, zkCross §5.3).
     *
     * Enhancement over original AuditContract:
     *   - Records quadratic reputation weight (R²_i) at submission time
     *   - Groups commits by (chainId, blockRange) for Ψ.WeightedAudit pool
     *
     * @param chainId    Ordinary chain being audited
     * @param oldRoot    State root before audited range (root_old, zkCross §5.3)
     * @param newRoot    State root after audited range  (root_new, zkCross §5.3)
     * @param blockStart First block in audited range
     * @param blockEnd   Last block in audited range
     */
    function submitCommit(
        uint256 chainId,
        bytes32 oldRoot,
        bytes32 newRoot,
        uint256 blockStart,
        uint256 blockEnd
    ) external returns (bytes32 commitId) {
        require(chains[chainId].isActive, "Chain not registered");
        require(committerStakes[msg.sender] >= MIN_STAKE, "Insufficient stake");

        require(reputationRegistry.isCommitterRegistered(msg.sender), "Not a registered committer");

        // Quadratic weight snapshot: w_i = R²_i / PRECISION (improvement doc §1.3.4)
        uint256 qWeight   = reputationRegistry.getQuadraticWeight(msg.sender);
        uint256 repSnap   = reputationRegistry.getReputation(msg.sender);
        uint256 clusterID = clusterManager.chainToCluster(chainId);

        commitId = keccak256(abi.encode(msg.sender, chainId, oldRoot, newRoot, block.timestamp));
        commits[commitId] = CommitRecord({
            committer:          msg.sender,
            chainId:            chainId,
            clusterId:          clusterID,
            oldStateRoot:       oldRoot,
            newStateRoot:       newRoot,
            timestamp:          block.timestamp,
            isVerified:         false,
            reputationAtSubmit: repSnap
        });
        commitIds.push(commitId);

        // Add to weighted group pool for this chain×blockRange
        bytes32 groupId = keccak256(abi.encode(chainId, blockStart, blockEnd));
        commitGroups[groupId].push(WeightedSubmission({
            committer:     msg.sender,
            submittedRoot: newRoot,
            weight:        qWeight
        }));

        chains[chainId].totalCommits++;
        emit CommitSubmitted(commitId, msg.sender, chainId, oldRoot, newRoot, repSnap);
    }

    // ==========================================
    // Ψ.WeightedAudit — NEW Cross-Reference + ZKP Verify
    // ==========================================

    /**
     * @notice Accept a chain root using quadratic-reputation-weighted majority vote.
     *
     * Algorithm (Ψ.WeightedAudit, improvement doc §1.3.4):
     *   1. Compute total weight: W_total = Σ_j w_j = Σ_j R²_j / PREC
     *   2. For each candidate root r: W_r = Σ_{i: r_i=r} w_i
     *   3. Accept r* = argmax{ W_r : W_r × 3 ≥ W_total × 2 }   (≥ 2/3 majority)
     *   4. Verify Groth16 proof for (old_root → r*)
     *   5. Update reputation: consistent[i] = (r_i == r*), alive[i] = true
     *
     * Security (Theorem 2, EdgeTrust-Shard JSA 2026 adapted):
     *   Pr[Byzantine root accepted] ≤ f·R²_min / ((1−f)·(Q*_h)²) ≈ 0.00014
     *   (f=0.3, R_min=0.01, Q*_h=0.6)
     *
     * @param groupId  Commit group ID = keccak256(abi.encode(chainId, blockStart, blockEnd))
     * @param chainId  Chain being audited
     * @param proofA   Groth16 proof element A (G1)
     * @param proofB   Groth16 proof element B (G2)
     * @param proofC   Groth16 proof element C (G1)
     */
    function weightedAuditAccept(
        bytes32           groupId,
        uint256           chainId,
        uint256[2]        calldata proofA,
        uint256[2][2]     calldata proofB,
        uint256[2]        calldata proofC
    ) external {
        require(auditors[msg.sender], "Not auditor");
        require(chains[chainId].isActive, "Chain not registered");

        WeightedSubmission[] storage group = commitGroups[groupId];
        require(group.length > 0, "Empty commit group");

        // Step 1: Compute total quadratic weight
        uint256 totalWeight = 0;
        for (uint256 i = 0; i < group.length; i++) {
            totalWeight += group[i].weight;
        }
        require(totalWeight > 0, "Zero total weight");

        // Steps 2-3: Find root with ≥ 2/3 of total weight
        bytes32 acceptedRoot  = bytes32(0);
        uint256 acceptedWeight = 0;
        for (uint256 i = 0; i < group.length; i++) {
            bytes32 candidate    = group[i].submittedRoot;
            uint256 candWeight   = 0;
            for (uint256 j = 0; j < group.length; j++) {
                if (group[j].submittedRoot == candidate) {
                    candWeight += group[j].weight;
                }
            }
            if (candWeight * 3 >= totalWeight * 2 && candWeight > acceptedWeight) {
                acceptedRoot   = candidate;
                acceptedWeight = candWeight;
            }
        }
        require(acceptedRoot != bytes32(0), "No 2/3 weighted majority");

        // Step 4: Groth16 proof verification (same as original Protocol Ψ)
        Groth16Verifier.Proof memory proof = Groth16Verifier.Proof({
            a: Groth16Verifier.G1Point(proofA[0], proofA[1]),
            b: Groth16Verifier.G2Point(proofB[0], proofB[1]),
            c: Groth16Verifier.G1Point(proofC[0], proofC[1])
        });
        uint256[] memory pubInputs = new uint256[](2);
        pubInputs[0] = uint256(chains[chainId].latestStateRoot);
        pubInputs[1] = uint256(acceptedRoot);
        require(useMockVerifier || Groth16Verifier.verify(vk_psi, proof, pubInputs), "ZKP verification failed");

        // Update chain state root
        chains[chainId].latestStateRoot = acceptedRoot;
        chains[chainId].lastUpdateBlock = block.number;

        // Step 5: Update MF-PoP reputation for all submitters in this group
        for (uint256 i = 0; i < group.length; i++) {
            bool consistent = (group[i].submittedRoot == acceptedRoot);
            reputationRegistry.updateReputation(group[i].committer, consistent, true);
        }

        emit WeightedAuditAccepted(groupId, acceptedRoot, totalWeight, acceptedWeight);
    }

    // ==========================================
    // Ψ.SingleAudit — Backward Compat (single committer path)
    // ==========================================

    /**
     * @notice Standard single-committer audit path (zkCross §5.3 original Ψ.Audit).
     * @dev Used when only one committer monitors a chain (no cross-reference pool).
     *   Always updates reputation as consistent=true, alive=true.
     */
    function verifyCommit(
        bytes32           commitId,
        uint256[2]        calldata proofA,
        uint256[2][2]     calldata proofB,
        uint256[2]        calldata proofC
    ) external {
        require(auditors[msg.sender], "Not auditor");
        CommitRecord storage rec = commits[commitId];
        require(!rec.isVerified, "Already verified");
        require(chains[rec.chainId].isActive, "Chain not active");
        require(rec.oldStateRoot == chains[rec.chainId].latestStateRoot, "Old root mismatch");

        Groth16Verifier.Proof memory proof = Groth16Verifier.Proof({
            a: Groth16Verifier.G1Point(proofA[0], proofA[1]),
            b: Groth16Verifier.G2Point(proofB[0], proofB[1]),
            c: Groth16Verifier.G1Point(proofC[0], proofC[1])
        });
        uint256[] memory pubInputs = new uint256[](2);
        pubInputs[0] = uint256(rec.oldStateRoot);
        pubInputs[1] = uint256(rec.newStateRoot);
        require(useMockVerifier || Groth16Verifier.verify(vk_psi, proof, pubInputs), "ZKP verification failed");

        rec.isVerified = true;
        chains[rec.chainId].latestStateRoot = rec.newStateRoot;
        chains[rec.chainId].lastUpdateBlock  = block.number;

        reputationRegistry.updateReputation(rec.committer, true, true);

        if (address(this).balance >= rewardPerCommit) {
            payable(rec.committer).transfer(rewardPerCommit);
        }
        emit CommitVerified(commitId, rec.committer, rewardPerCommit);
    }

    // ==========================================
    // Cluster-Level Commit  (O(√k) path)
    // ==========================================

    /**
     * @notice Accept cluster-aggregated commits from ClusterManager (O(√k) path).
     *
     * @dev Implements the O(√k) proof submission described in improvement doc §2:
     *   Cluster head (elected by quadratic VRF) aggregates √k individual chain roots
     *   into a Merkle root and submits ONE proof instead of √k proofs.
     *   At k=100 chains with M=10 clusters: 10 proofs reach global chain vs 100.
     *   Reduction factor = √k.
     *
     * @param clusterCommitId  Commit ID from ClusterManager.submitClusterCommit()
     * @param chainIds         Chain IDs covered by this cluster commit (in order)
     * @param newRoots         New state roots for each chain (matches aggregated root)
     */
    function acceptClusterCommit(
        bytes32           clusterCommitId,
        uint256[] calldata chainIds,
        bytes32[] calldata newRoots
    ) external {
        require(auditors[msg.sender], "Not auditor");
        require(chainIds.length == newRoots.length, "Length mismatch");
        require(chainIds.length > 0, "Empty cluster commit");

        // Retrieve scalar fields from ClusterManager (bytes32[] not returned by getter)
        (uint256 clusterId, address clusterHead, bytes32 aggRoot, bool isVerified)
            = clusterManager.getClusterCommitInfo(clusterCommitId);

        require(clusterHead != address(0), "Invalid cluster commit");
        require(!isVerified, "Already verified");

        // SECURITY: Verify that all chainIds actually belong to this cluster
        uint256[] memory clusterChainIds = clusterManager.getClusterChains(clusterId);
        require(chainIds.length == clusterChainIds.length, "Chain count mismatch");
        for (uint256 i = 0; i < chainIds.length; i++) {
            bool found = false;
            for (uint256 j = 0; j < clusterChainIds.length; j++) {
                if (chainIds[i] == clusterChainIds[j]) {
                    found = true;
                    break;
                }
            }
            require(found, "Chain not in cluster");
        }

        // Verify that the supplied roots match the aggregated Merkle root
        bytes32 computedAgg = _merkleRoot(newRoots);
        require(computedAgg == aggRoot, "Aggregated root mismatch");

        // Update all chains in the cluster
        for (uint256 i = 0; i < chainIds.length; i++) {
            require(chains[chainIds[i]].isActive, "Chain not registered");
            chains[chainIds[i]].latestStateRoot = newRoots[i];
            chains[chainIds[i]].lastUpdateBlock  = block.number;
        }

        // Mark cluster commit as verified (updates cluster head reputation in ClusterManager)
        clusterManager.verifyClusterCommit(clusterCommitId);

        emit ClusterCommitAccepted(clusterCommitId, clusterId, chainIds.length);
    }

    // ==========================================
    // Mock Verifier Mode (for testing without real zk-SNARK proofs)
    // ==========================================

    /// @notice Enable mock verifier mode (skip actual ZKP verification)
    /// @dev MUST be called after deployment for testing. In production, set real VK via setVerifyingKey()
    function enableMockVerifier() external {
        require(msg.sender == owner, "Not owner");
        useMockVerifier = true;
    }

    // ==========================================
    // Verifying Key Setup
    // ==========================================

    /// @notice Set Groth16 verifying key for Circuit Λ_Ψ (zkCross §6).
    function setVerifyingKey(
        uint256[2]    calldata alpha,
        uint256[2][2] calldata beta,
        uint256[2][2] calldata gamma,
        uint256[2][2] calldata delta,
        uint256[][]   calldata ic
    ) external {
        require(msg.sender == owner, "Not owner");
        vk_psi.alpha = Groth16Verifier.G1Point(alpha[0], alpha[1]);
        vk_psi.beta  = Groth16Verifier.G2Point(beta[0],  beta[1]);
        vk_psi.gamma = Groth16Verifier.G2Point(gamma[0], gamma[1]);
        vk_psi.delta = Groth16Verifier.G2Point(delta[0], delta[1]);
        delete vk_psi.ic;
        for (uint256 i = 0; i < ic.length; i++) {
            vk_psi.ic.push(Groth16Verifier.G1Point(ic[i][0], ic[i][1]));
        }
    }

    // ==========================================
    // View Helpers
    // ==========================================

    function getChainRoot(uint256 chainId) external view returns (bytes32) {
        return chains[chainId].latestStateRoot;
    }

    function getCommitCount() external view returns (uint256) {
        return commitIds.length;
    }

    function getGroupSize(bytes32 groupId) external view returns (uint256) {
        return commitGroups[groupId].length;
    }

    // ==========================================
    // Internal
    // ==========================================

    function _merkleRoot(bytes32[] memory leaves) internal pure returns (bytes32) {
        if (leaves.length == 0) return bytes32(0);
        if (leaves.length == 1) return leaves[0];
        bytes32[] memory layer = leaves;
        while (layer.length > 1) {
            uint256 half = (layer.length + 1) / 2;
            bytes32[] memory next = new bytes32[](half);
            for (uint256 i = 0; i < half; i++) {
                uint256 l = i * 2;
                uint256 r = l + 1 < layer.length ? l + 1 : l;
                next[i] = keccak256(abi.encode(layer[l], layer[r]));
            }
            layer = next;
        }
        return layer[0];
    }

    

    fallback() external payable {}
    receive() external payable {}
    
}
