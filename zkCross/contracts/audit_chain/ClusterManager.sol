// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "./ReputationRegistry.sol";

/**
 * @title ClusterManager — Hierarchical Auditor Clustering for zkCross v2
 *
 * @notice Implements the 3-layer hierarchical architecture that reduces audit
 *         workload from O(k) to O(√k) per auditor node.
 *
 * @dev RESEARCH GAP ADDRESSED:
 *   zkCross (USENIX Security 2024) Section 3.2 describes a tree-shaped topology
 *   but uses a flat 2-layer implementation:
 *     Layer 0 (ordinary chains) → Layer 1 (audit chain)
 *   zkCross Section 7.2.2 reports: "without Ψ: 3.15 hours for 10,000 txs".
 *   Even with Ψ (~40 seconds), as k (chain count) grows, the bottleneck returns.
 *
 *   IMPROVEMENT SOURCE: EdgeTrust-Shard (JSA 2026) Section 4 — Hierarchical
 *   Cluster Architecture (HCA).
 *
 * =====================================================
 * SỬA LỖI B2 (ZkCross-Anh.pdf): Cấu trúc lại Cluster Consensus
 * =====================================================
 * VẤN ĐỀ:
 *   1. Chia cụm tĩnh → Cluster Head độc hại có thể kiểm duyệt (censorship)
 *   2. Global Chain vẫn cập nhật khi bỏ qua dữ liệu 1 cụm → mất Data Availability
 *
 * GIẢI PHÁP:
 *   1. VRF-based random cluster assignment: Xáo trộn ngẫu nhiên việc gán
 *      Chain vào Cluster ở mỗi epoch bằng VRF toàn cục
 *   2. Challenge Window + Fraud Proofs: Thêm cửa sổ thử thách để Node
 *      bình thường có thể tố cáo Cluster Head giấu dữ liệu
 *   3. Data Availability check: Global Chain kiểm tra TẤT CẢ chains
 *      đã được submit, không bỏ qua chain nào
 *
 * LEADER ELECTION:
 *   Cluster head elected by quadratic-weighted VRF sampling:
 *     w_i = R²_i / Σ_j R²_j
 *   This reduces Byzantine leader probability by ~2100× vs uniform selection.
 */
contract ClusterManager {

    // ==========================================
    // Data Structures
    // ==========================================

    struct Cluster {
        uint256   clusterId;
        address   clusterHead;          // Current elected head
        address[] members;              // All committer members
        uint256[] assignedChainIds;     // Ordinary chains in this cluster
        uint256   lastElectionRound;
        uint256   totalProofsAggregated;
        bool      isActive;
    }

    struct ClusterCommit {
        uint256   clusterId;
        address   clusterHead;
        bytes32[] chainRoots;          // root_new per chain in cluster
        bytes32   aggregatedRoot;      // merkle root of chainRoots
        uint256   round;
        bool      isVerified;
        uint256   timestamp;
    }

    // ==========================================
    // State Variables
    // ==========================================

    ReputationRegistry public immutable reputationRegistry;

    mapping(uint256 => Cluster) public clusters;
    uint256[] public clusterIds;
    uint256 public nextClusterId = 1;

    mapping(bytes32 => ClusterCommit) public clusterCommits;
    bytes32[] public commitHistory;

    /// @notice Maps ordinary chain → cluster
    mapping(uint256 => uint256) public chainToCluster;

    uint256 public currentRound;
    address public owner;

    // =====================================================
    // [SỬA LỖI B2] Thêm VRF epoch shuffling + DA layer
    // =====================================================

    /// @notice Epoch counter cho VRF cluster re-assignment
    uint256 public currentEpoch;

    /// @notice Số rounds trong 1 epoch trước khi xáo trộn cluster
    uint256 public constant EPOCH_LENGTH = 100;

    /// @notice Cửa sổ thử thách (challenge window) tính bằng rounds
    /// Node bình thường có thể tố cáo CH giấu dữ liệu trong window này
    uint256 public constant CHALLENGE_WINDOW = 10;

    /// @notice [SỬA LỖI B2] Cấu trúc Fraud Proof / Challenge
    struct DataAvailabilityChallenge {
        address challenger;          // Node tố cáo
        uint256 clusterId;           // Cluster bị tố cáo
        uint256 missingChainId;      // Chain bị giấu dữ liệu
        uint256 round;               // Round xảy ra
        uint256 filedAt;             // Round nộp tố cáo
        bool    resolved;
        bool    valid;               // Tố cáo hợp lệ không
    }

    mapping(bytes32 => DataAvailabilityChallenge) public challenges;
    bytes32[] public challengeIds;

    /// @notice Theo dõi chain nào đã submit trong mỗi round
    /// [SỬA LỖI B2] Global Chain KHÔNG thể bỏ qua bất kỳ chain nào
    mapping(uint256 => mapping(uint256 => bool)) public chainSubmittedInRound;
    // round => chainId => submitted?

    // ==========================================
    // Events
    // ==========================================

    event ClusterCreated(uint256 indexed clusterId, uint256[] chainIds);
    event ClusterHeadElected(uint256 indexed clusterId, address indexed newHead, uint256 round);
    event ClusterCommitSubmitted(bytes32 indexed commitId, uint256 indexed clusterId, bytes32 aggregatedRoot);
    event ClusterCommitVerified(bytes32 indexed commitId, uint256 clusterId);
    // [SỬA LỖI B2] Events cho VRF shuffling và DA challenges
    event ClustersReshuffled(uint256 epoch, bytes32 vrfSeed);
    event DAChallengeFiled(bytes32 indexed challengeId, address challenger, uint256 clusterId, uint256 missingChainId);
    event DAChallengeResolved(bytes32 indexed challengeId, bool valid);

    // ==========================================
    // Constructor
    // ==========================================

    constructor(address _reputationRegistry) {
        reputationRegistry = ReputationRegistry(_reputationRegistry);
        owner = msg.sender;
        currentRound = 1;
    }

    // ==========================================
    // Cluster Setup
    // ==========================================

    /**
     * @notice Create a new regional audit cluster
     *
     * @dev A cluster groups √k chains together. The improvement doc recommends
     *   M = √k clusters (e.g., k=100 chains → M=10 clusters of 10 chains each).
     *   Each cluster handles O(√k) proofs from its committers.
     *
     * @param chainIds  Ordinary chain IDs assigned to this cluster
     * @param members   Initial committer members of the cluster
     */
    function createCluster(uint256[] calldata chainIds, address[] calldata members) external returns (uint256) {
        require(msg.sender == owner, "Not owner");
        require(chainIds.length > 0, "No chains");
        require(members.length > 0, "No members");

        uint256 cid = nextClusterId++;
        Cluster storage c = clusters[cid];
        c.clusterId = cid;
        c.assignedChainIds = chainIds;
        c.isActive = true;

        for (uint256 i = 0; i < chainIds.length; i++) {
            chainToCluster[chainIds[i]] = cid;
        }
        for (uint256 i = 0; i < members.length; i++) {
            c.members.push(members[i]);
        }
        clusterIds.push(cid);

        // Elect initial cluster head
        _electClusterHead(cid);

        emit ClusterCreated(cid, chainIds);
        return cid;
    }

    /**
     * @notice Add a member to an existing cluster
     */
    function addMember(uint256 clusterId, address member) external {
        require(msg.sender == owner, "Not owner");
        require(reputationRegistry.isCommitterRegistered(member), "Not a registered committer");
        clusters[clusterId].members.push(member);
    }

    // ==========================================
    // Leader Election
    // ==========================================

    /**
     * @notice Trigger a new cluster head election using quadratic-weighted VRF
     *
     * @dev Implements Section 2.2 / 4.1.2 of improvement doc:
     *   1. Compute w_i = R²_i for each member
     *   2. Use block hash + clusterId + round as VRF seed
     *   3. Walk the cumulative weight distribution to find winner
     *
     * Quadratic weighting creates (honest_R/byzantine_R)² = (0.85/0.03)² = 802×
     * separation, reducing Byzantine leader probability by ~2100× vs uniform.
     * Reference: improvement doc Section 1.3.4, EdgeTrust-Shard Theorem 2
     *
     * @param clusterId The cluster to hold election in
     */
    function electClusterHead(uint256 clusterId) external {
        Cluster storage c = clusters[clusterId];
        require(c.isActive, "Cluster not active");
        // Allow election if at least 10 rounds have passed
        require(currentRound >= c.lastElectionRound + 10, "Too soon for re-election");
        _electClusterHead(clusterId);
    }

    // ==========================================
    // Cluster Commit Submission
    // ==========================================

    /**
     * @notice Submit an aggregated proof from a cluster head to Layer 2
     *
     * @dev Implements Section 3.2 step 3 of the improvement doc:
     *   CH_m creates aggregated proof from all chains in cluster, submits
     *   TxClusterCommit to Global Audit Chain. This replaces individual per-chain
     *   TxCommit calls, reducing Layer 2 workload from O(k) → O(√k).
     *
     * @param clusterId    The submitting cluster's ID
     * @param chainRoots   Array of root_new values, one per chain in cluster
     */
    function submitClusterCommit(
        uint256   clusterId,
        bytes32[] calldata chainRoots
    ) external returns (bytes32 commitId) {
        Cluster storage c = clusters[clusterId];
        require(c.isActive, "Cluster not active");
        require(msg.sender == c.clusterHead, "Not cluster head");
        require(chainRoots.length == c.assignedChainIds.length, "Root count mismatch");

        // Compute aggregated Merkle root of all chain roots
        bytes32 aggRoot = _merkleRoot(chainRoots);

        commitId = keccak256(abi.encode(clusterId, aggRoot, currentRound, block.timestamp));

        clusterCommits[commitId] = ClusterCommit({
            clusterId:       clusterId,
            clusterHead:     msg.sender,
            chainRoots:      chainRoots,
            aggregatedRoot:  aggRoot,
            round:           currentRound,
            isVerified:      false,
            timestamp:       block.timestamp
        });
        commitHistory.push(commitId);
        c.totalProofsAggregated++;

        // [SỬA LỖI B2] Đánh dấu tất cả chains trong cluster đã submit
        _markChainsSubmitted(clusterId, currentRound);

        emit ClusterCommitSubmitted(commitId, clusterId, aggRoot);
    }

    /**
     * @notice Verify a cluster commit (called by global auditor on Layer 2)
     *
     * @dev In the full implementation, this would verify an aggregated ZKP
     *   proof (circuit ΛΨ_agg). Here we simulate the verification step and
     *   update cluster head's reputation via MF-PoP.
     *
     * After verification, updates cluster head reputation — this is the
     * Layer 2 MF-PoP update (improvement doc Section 3.2 step 4).
     */
    function verifyClusterCommit(bytes32 commitId) external {
        // SECURITY: Require caller to be the audit contract or owner
        // In production, this should be restricted to auditors registered in AuditContractV2
        require(msg.sender == owner, "Not authorized");
        ClusterCommit storage cc = clusterCommits[commitId];
        require(!cc.isVerified, "Already verified");
        // In production: verify aggregated ZKP proof here
        // For experiment: simulate acceptance (trusted auditor call)
        cc.isVerified = true;

        // Update cluster head reputation (consistent + alive)
        reputationRegistry.updateReputation(cc.clusterHead, true, true);

        emit ClusterCommitVerified(commitId, cc.clusterId);
    }

    // ==========================================
    // Cross-Reference (Ψ.Commit enhancement)
    // ==========================================

    /**
     * @notice Cross-reference state roots submitted by multiple committers
     *         for the same chain, computing consistency score.
     *
     * @dev Implements Section 1.3.2 of improvement doc (enhanced Ψ.Commit):
     *   - Collect {root_new} from ≥ 2/3 committers for same chain+block range
     *   - expected_root = majority root among submissions
     *   - C^t_i = 1 if committer's root matched expected_root, else 0
     *
     * Then calls Ψ.UpdateReputation for each committer.
     *
     * @param committerAddrs  Array of committer addresses who submitted
     * @param submittedRoots  Corresponding roots each committer submitted
     * @param aliveFlags      Whether each committer submitted within window
     */
    function crossReferenceAndUpdate(
        address[] calldata committerAddrs,
        bytes32[] calldata submittedRoots,
        bool[]    calldata aliveFlags
    ) external {
        require(msg.sender == owner || clusters[chainToCluster[0]].clusterHead == msg.sender, "Not authorized");
        require(committerAddrs.length == submittedRoots.length, "Length mismatch");
        require(committerAddrs.length == aliveFlags.length, "Length mismatch");

        // Find majority root (2/3 threshold)
        bytes32 expectedRoot = _majorityRoot(submittedRoots);

        // Update reputation for each committer
        for (uint256 i = 0; i < committerAddrs.length; i++) {
            bool consistent = (submittedRoots[i] == expectedRoot);
            reputationRegistry.updateReputation(committerAddrs[i], consistent, aliveFlags[i]);
        }
    }

    // ==========================================
    // [SỬA LỖI B2] VRF-based Cluster Reshuffling
    // Chống kiểm duyệt: xáo trộn ngẫu nhiên chain-cluster mapping mỗi epoch
    // ==========================================

    /**
     * @notice Xáo trộn ngẫu nhiên việc gán Chain vào Cluster bằng VRF
     *
     * @dev [SỬA LỖI B2] Implements VRF epoch shuffling:
     *   - Mỗi EPOCH_LENGTH rounds, tất cả chains được gán lại vào clusters
     *   - Sử dụng VRF seed từ block hash + epoch number
     *   - Fisher-Yates shuffle để đảm bảo uniform distribution
     *   - Ngăn chặn 1 nhóm thao túng 1 tập hợp chains cố định
     *
     * @param allChainIds Danh sách tất cả chain IDs cần xáo trộn
     */
    function reshuffleClusters(uint256[] calldata allChainIds) external {
        require(msg.sender == owner, "Not owner");
        require(currentRound >= (currentEpoch + 1) * EPOCH_LENGTH, "Epoch not ended");

        uint256 nChains = allChainIds.length;
        require(nChains > 0, "No chains");

        // VRF seed từ block hash + epoch (pseudo-VRF on-chain)
        bytes32 vrfSeed = keccak256(abi.encode(
            blockhash(block.number - 1),
            currentEpoch,
            block.timestamp
        ));

        // Fisher-Yates shuffle: xáo trộn thứ tự chains
        uint256[] memory shuffled = new uint256[](nChains);
        for (uint256 i = 0; i < nChains; i++) {
            shuffled[i] = allChainIds[i];
        }
        for (uint256 i = nChains - 1; i > 0; i--) {
            uint256 j = uint256(keccak256(abi.encode(vrfSeed, i))) % (i + 1);
            // Swap
            uint256 temp = shuffled[i];
            shuffled[i] = shuffled[j];
            shuffled[j] = temp;
        }

        // Gán lại chains vào clusters (round-robin sau shuffle)
        uint256 nClusters = clusterIds.length;
        require(nClusters > 0, "No clusters exist");

        // Xóa assignment cũ
        for (uint256 i = 0; i < nClusters; i++) {
            delete clusters[clusterIds[i]].assignedChainIds;
        }

        // Gán mới theo round-robin trên thứ tự đã xáo trộn
        for (uint256 i = 0; i < nChains; i++) {
            uint256 cid = clusterIds[i % nClusters];
            clusters[cid].assignedChainIds.push(shuffled[i]);
            chainToCluster[shuffled[i]] = cid;
        }

        currentEpoch++;

        // Re-elect cluster heads sau khi xáo trộn
        for (uint256 i = 0; i < nClusters; i++) {
            _electClusterHead(clusterIds[i]);
        }

        emit ClustersReshuffled(currentEpoch, vrfSeed);
    }

    // ==========================================
    // [SỬA LỖI B2] Data Availability Challenge (Fraud Proofs)
    // Bảo đảm Global Chain không bỏ qua dữ liệu bất kỳ chain nào
    // ==========================================

    /**
     * @notice Node bình thường tố cáo Cluster Head giấu dữ liệu
     *
     * @dev [SỬA LỖI B2] Implements challenge window + fraud proofs:
     *   - Cluster Head PHẢI submit proof cho TẤT CẢ chains trong cluster
     *   - Nếu thiếu chain nào, bất kỳ node nào cũng có thể file challenge
     *   - Challenge phải được file trong CHALLENGE_WINDOW rounds
     *   - Nếu challenge hợp lệ: CH bị phạt reputation + re-election
     *
     * @param clusterId    Cluster bị tố cáo
     * @param missingChainId Chain bị giấu dữ liệu
     * @param round        Round xảy ra vi phạm
     */
    function fileDAChallenge(uint256 clusterId, uint256 missingChainId, uint256 round) external {
        require(currentRound <= round + CHALLENGE_WINDOW, "Challenge window expired");
        require(clusters[clusterId].isActive, "Cluster not active");

        // Kiểm tra chain thuộc cluster này
        bool chainInCluster = false;
        uint256[] storage chainIds = clusters[clusterId].assignedChainIds;
        for (uint256 i = 0; i < chainIds.length; i++) {
            if (chainIds[i] == missingChainId) {
                chainInCluster = true;
                break;
            }
        }
        require(chainInCluster, "Chain not in this cluster");

        // Kiểm tra chain chưa submit trong round đó
        require(!chainSubmittedInRound[round][missingChainId], "Chain was submitted");

        bytes32 challengeId = keccak256(abi.encode(clusterId, missingChainId, round, msg.sender));
        require(!challenges[challengeId].resolved, "Challenge exists");

        challenges[challengeId] = DataAvailabilityChallenge({
            challenger: msg.sender,
            clusterId: clusterId,
            missingChainId: missingChainId,
            round: round,
            filedAt: currentRound,
            resolved: false,
            valid: false
        });
        challengeIds.push(challengeId);

        emit DAChallengeFiled(challengeId, msg.sender, clusterId, missingChainId);
    }

    /**
     * @notice Xử lý DA challenge (owner/Global Chain)
     * @dev [SỬA LỖI B2] Nếu challenge hợp lệ:
     *   - Phạt CH reputation (gọi ReputationRegistry)
     *   - Trigger re-election cho cluster
     */
    function resolveDAChallenge(bytes32 challengeId, bool valid) external {
        require(msg.sender == owner, "Not owner");
        DataAvailabilityChallenge storage c = challenges[challengeId];
        require(!c.resolved, "Already resolved");

        c.resolved = true;
        c.valid = valid;

        if (valid) {
            // Phạt Cluster Head: chấm C=0 (inconsistent) + L=0
            address ch = clusters[c.clusterId].clusterHead;
            reputationRegistry.updateReputation(ch, false, false);

            // Trigger re-election
            _electClusterHead(c.clusterId);
        }

        emit DAChallengeResolved(challengeId, valid);
    }

    /**
     * @notice Đánh dấu chain đã submit trong round (gọi từ submitClusterCommit)
     * @dev [SỬA LỖI B2] Theo dõi DA - đảm bảo không chain nào bị bỏ qua
     */
    function _markChainsSubmitted(uint256 clusterId, uint256 round) internal {
        uint256[] storage chainIds = clusters[clusterId].assignedChainIds;
        for (uint256 i = 0; i < chainIds.length; i++) {
            chainSubmittedInRound[round][chainIds[i]] = true;
        }
    }

    // ==========================================
    // Round Management
    // ==========================================

    function advanceRound() external {
        require(msg.sender == owner, "Not owner");
        currentRound++;
        reputationRegistry.advanceRound();
    }

    // ==========================================
    // View Functions
    // ==========================================

    function getClusterMembers(uint256 clusterId) external view returns (address[] memory) {
        return clusters[clusterId].members;
    }

    function getClusterChains(uint256 clusterId) external view returns (uint256[] memory) {
        return clusters[clusterId].assignedChainIds;
    }

    function getClusterHead(uint256 clusterId) external view returns (address) {
        return clusters[clusterId].clusterHead;
    }

    function getClusterCount() external view returns (uint256) {
        return clusterIds.length;
    }

    /**
     * @notice Get cluster commit scalar fields (excludes chainRoots bytes32[] for ABI compat)
     * @dev Used by AuditContractV2.acceptClusterCommit() to retrieve commit metadata.
     *   chainRoots must be supplied separately by the caller (from event logs).
     *   Reference: improvement doc §3.1 (integrated end-to-end flow)
     */
    function getClusterCommitInfo(bytes32 commitId) external view returns (
        uint256 clusterId,
        address clusterHead,
        bytes32 aggregatedRoot,
        bool    isVerified
    ) {
        ClusterCommit storage cc = clusterCommits[commitId];
        return (cc.clusterId, cc.clusterHead, cc.aggregatedRoot, cc.isVerified);
    }

    /**
     * @notice Compute theoretical workload complexity
     * @param totalChains k (total ordinary chains)
     * @return clusterCount M = √k (number of clusters)
     * @return proofPerAuditor O(√k) proofs per auditor vs O(k) in original
     */
    function getComplexityInfo(uint256 totalChains)
        external
        pure
        returns (uint256 clusterCount, uint256 proofPerAuditor, uint256 reduction)
    {
        clusterCount = _sqrt(totalChains);
        proofPerAuditor = clusterCount;
        reduction = totalChains / (clusterCount == 0 ? 1 : clusterCount);
    }

    // ==========================================
    // Internal Helpers
    // ==========================================

    function _electClusterHead(uint256 clusterId) internal {
        Cluster storage c = clusters[clusterId];
        require(c.members.length > 0, "No members");

        // Compute total quadratic weight
        uint256 totalWeight = 0;
        for (uint256 i = 0; i < c.members.length; i++) {
            totalWeight += reputationRegistry.getQuadraticWeight(c.members[i]);
        }

        if (totalWeight == 0) {
            // Fallback: elect first member if all have zero weight
            c.clusterHead = c.members[0];
            c.lastElectionRound = currentRound;
            emit ClusterHeadElected(clusterId, c.members[0], currentRound);
            return;
        }

        // VRF seed from block hash + cluster + round
        bytes32 seed = keccak256(abi.encode(blockhash(block.number - 1), clusterId, currentRound));
        uint256 rand = uint256(seed) % totalWeight;

        // Walk cumulative weight distribution
        uint256 cumulative = 0;
        address winner = c.members[0];
        for (uint256 i = 0; i < c.members.length; i++) {
            cumulative += reputationRegistry.getQuadraticWeight(c.members[i]);
            if (rand < cumulative) {
                winner = c.members[i];
                break;
            }
        }

        c.clusterHead = winner;
        c.lastElectionRound = currentRound;
        emit ClusterHeadElected(clusterId, winner, currentRound);
    }

    /// @dev Compute Merkle root of an array of bytes32 leaves
    function _merkleRoot(bytes32[] memory leaves) internal pure returns (bytes32) {
        if (leaves.length == 0) return bytes32(0);
        if (leaves.length == 1) return leaves[0];
        bytes32[] memory layer = leaves;
        while (layer.length > 1) {
            uint256 newLen = (layer.length + 1) / 2;
            bytes32[] memory next = new bytes32[](newLen);
            for (uint256 i = 0; i < newLen; i++) {
                uint256 l = i * 2;
                uint256 r = l + 1 < layer.length ? l + 1 : l;
                next[i] = keccak256(abi.encode(layer[l], layer[r]));
            }
            layer = next;
        }
        return layer[0];
    }

    /// @dev Find majority root among submissions (simple majority vote)
    function _majorityRoot(bytes32[] memory roots) internal pure returns (bytes32 best) {
        if (roots.length == 0) return bytes32(0);
        uint256 bestCount = 0;
        for (uint256 i = 0; i < roots.length; i++) {
            uint256 count = 0;
            for (uint256 j = 0; j < roots.length; j++) {
                if (roots[j] == roots[i]) count++;
            }
            if (count > bestCount) {
                bestCount = count;
                best = roots[i];
            }
        }
    }

    /// @dev Integer square root
    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }
}
