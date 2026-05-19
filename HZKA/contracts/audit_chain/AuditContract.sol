// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "../libraries/Groth16Verifier.sol";

/**
 * @title zkCross Audit Contract (Protocol Ψ) - Deployed on Audit Chain
 * @notice Implements cross-chain auditing with zk-SNARK proof verification
 * @dev The audit chain is the upper layer of zkCross's two-layer architecture.
 * 
 * Protocol Ψ Flow:
 *   1. Ψ.Initialize: Committer generates CRS (pk_Ψ, vk_Ψ) for circuit Λ_Ψ
 *   2. Ψ.Commit:     Committer generates proof and submits TxCommit
 *   3. Ψ.Audit:      Auditors verify proof and update audit chain state
 * 
 * The circuit Λ_Ψ contains 4 modules:
 *   - AF:  Auditing Function (blacklist check)
 *   - SVF: Signature Verification Function
 *   - STF: State Transition Function
 *   - RVF: Root Verification Function
 * 
 * Efficiency: Reduces audit time from O(k*m*n) to O(k*m) where
 *   k = number of chains, m = blocks/sec, n = transactions/block
 * 
 * Reference: zkCross paper Section 5.3 - Protocol Ψ
 */
contract AuditContract {
    using Groth16Verifier for *;

    // ==========================================
    // Data Structures
    // ==========================================

    /// @notice Represents a registered ordinary chain
    struct ChainInfo {
        uint256 chainId;           // Chain identifier
        bytes32 latestStateRoot;   // Latest verified state root
        uint256 lastUpdateBlock;   // Block number of last update
        uint256 totalCommits;      // Total number of commits for this chain
        bool isActive;             // Whether chain is actively monitored
    }

    /// @notice Commit record from a committer
    struct CommitRecord {
        address committer;         // Who submitted the proof
        uint256 chainId;           // Which chain this commit is for
        bytes32 oldStateRoot;      // State root before transactions (root_2)
        bytes32 newStateRoot;      // State root after transactions (root_3)
        uint256 timestamp;         // When the commit was submitted
        bool isVerified;           // Whether auditors verified it
    }

    /// @notice Registered committer (lower-layer node acting as bridge)
    struct CommitterInfo {
        address addr;              // Committer's address on audit chain
        uint256[] chainIds;        // Which chains this committer monitors
        uint256 totalCommits;      // Total commits submitted
        uint256 rewards;           // Accumulated rewards
        bool isRegistered;         // Registration status
    }

    // ==========================================
    // State Variables
    // ==========================================

    /// @notice Verification key for Circuit Λ_Ψ
    Groth16Verifier.VerifyingKey private vk_psi;

    /// @notice Registered chains
    mapping(uint256 => ChainInfo) public chains;
    uint256[] public chainList;

    /// @notice Commit records
    mapping(bytes32 => CommitRecord) public commits;
    bytes32[] public commitIds;

    /// @notice Registered committers
    mapping(address => CommitterInfo) public committers;
    address[] public committerList;

    /// @notice Audit chain state tree (stores state roots of ordinary chains)
    /// @dev In the paper, the audit chain's state tree has leaves = 
    ///      state tree roots of ordinary chains (hierarchical linking)
    mapping(uint256 => bytes32[]) public chainStateHistory;

    /// @notice Reward per successful commit (incentivizes committers)
    uint256 public rewardPerCommit = 0.001 ether;

    /// @notice Minimum stake required for committer registration (paper Section 4.1)
    uint256 public constant MIN_COMMITTER_STAKE = 1 ether;

    /// @notice Slash amount for invalid commits
    uint256 public constant SLASH_AMOUNT = 0.5 ether;

    /// @notice Committer stakes
    mapping(address => uint256) public committerStakes;

    /// @notice Contract owner (initial deployer)
    address public owner;

    /// @notice Minimum number of auditors required for consensus
    uint256 public minAuditors = 1;

    /// @notice Registered auditors
    mapping(address => bool) public auditors;
    uint256 public auditorCount;

    // ==========================================
    // Events
    // ==========================================

    event ChainRegistered(uint256 indexed chainId, bytes32 initialRoot);
    event CommitterRegistered(address indexed committer, uint256[] chainIds);
    event AuditorRegistered(address indexed auditor);

    event CommitSubmitted(
        bytes32 indexed commitId,
        address indexed committer,
        uint256 indexed chainId,
        bytes32 oldRoot,
        bytes32 newRoot
    );

    event CommitVerified(
        bytes32 indexed commitId,
        uint256 indexed chainId,
        bytes32 newRoot,
        address verifier
    );

    event RewardClaimed(address indexed committer, uint256 amount);
    event CommitterSlashed(address indexed committer, uint256 amount, bytes32 commitId);

    // ==========================================
    // Constructor
    // ==========================================

    constructor() {
        owner = msg.sender;
        auditors[msg.sender] = true;
        auditorCount = 1;
    }

    // ==========================================
    // Admin Functions
    // ==========================================

    /**
     * @notice Set verification key for Λ_Ψ circuit
     * @dev Generated during Ψ.Initialize by the committer
     */
    function setVerifyingKey(
        uint256[2] memory alpha,
        uint256[2][2] memory beta,
        uint256[2][2] memory gamma,
        uint256[2][2] memory delta,
        uint256[2][] memory ic
    ) external {
        require(msg.sender == owner, "Only owner");

        vk_psi.alpha = Groth16Verifier.G1Point(alpha[0], alpha[1]);
        vk_psi.beta = Groth16Verifier.G2Point(beta[0], beta[1]);
        vk_psi.gamma = Groth16Verifier.G2Point(gamma[0], gamma[1]);
        vk_psi.delta = Groth16Verifier.G2Point(delta[0], delta[1]);

        delete vk_psi.ic;
        for (uint256 i = 0; i < ic.length; i++) {
            vk_psi.ic.push(Groth16Verifier.G1Point(ic[i][0], ic[i][1]));
        }
    }

    /**
     * @notice Register a new ordinary chain for auditing
     */
    function registerChain(uint256 chainId, bytes32 initialRoot) external {
        require(msg.sender == owner, "Only owner");
        require(!chains[chainId].isActive, "Chain already registered");

        chains[chainId] = ChainInfo({
            chainId: chainId,
            latestStateRoot: initialRoot,
            lastUpdateBlock: block.number,
            totalCommits: 0,
            isActive: true
        });

        chainList.push(chainId);
        chainStateHistory[chainId].push(initialRoot);

        emit ChainRegistered(chainId, initialRoot);
    }

    /**
     * @notice Register an auditor
     */
    function registerAuditor(address auditor) external {
        require(msg.sender == owner, "Only owner");
        require(!auditors[auditor], "Already registered");

        auditors[auditor] = true;
        auditorCount++;

        emit AuditorRegistered(auditor);
    }

    // ==========================================
    // Committer Registration
    // ==========================================

    /**
     * @notice Register as a committer for specific chains
     * @param chainIds Array of chain IDs this committer will monitor
     * 
     * @dev Per paper Section 4.1: "honest upper-layer committers are duly rewarded"
     *   Committers must stake MIN_COMMITTER_STAKE as collateral.
     *   Rewards are earned for valid commits; stakes are slashed for invalid commits.
     *   This incentivizes honest behavior in the audit process.
     */
    function registerCommitter(uint256[] memory chainIds) external payable {
        require(!committers[msg.sender].isRegistered, "Already registered");
        require(msg.value >= MIN_COMMITTER_STAKE, "Insufficient stake");

        for (uint256 i = 0; i < chainIds.length; i++) {
            require(chains[chainIds[i]].isActive, "Chain not registered");
        }

        committers[msg.sender] = CommitterInfo({
            addr: msg.sender,
            chainIds: chainIds,
            totalCommits: 0,
            rewards: 0,
            isRegistered: true
        });

        committerStakes[msg.sender] = msg.value;
        committerList.push(msg.sender);

        emit CommitterRegistered(msg.sender, chainIds);
    }

    /**
     * @notice Slash a committer for submitting an invalid commit
     * @param commitId The invalid commit
     * @dev Only callable by auditors who detect a bad proof after it was stored.
     *      Per paper Section 4.1: committers face penalties for dishonest behavior.
     */
    function slashCommitter(bytes32 commitId) external {
        require(auditors[msg.sender], "Not an auditor");

        CommitRecord storage record = commits[commitId];
        require(record.timestamp > 0, "Commit not found");
        require(!record.isVerified, "Already verified as valid");

        address committerAddr = record.committer;
        require(committerStakes[committerAddr] >= SLASH_AMOUNT, "Insufficient stake to slash");

        committerStakes[committerAddr] -= SLASH_AMOUNT;

        // Transfer slashed amount to the auditor who reported it
        (bool success, ) = payable(msg.sender).call{value: SLASH_AMOUNT}("");
        require(success, "Slash transfer failed");

        emit CommitterSlashed(committerAddr, SLASH_AMOUNT, commitId);
    }

    // ==========================================
    // Ψ.Commit - Submit auditing proof
    // ==========================================

    /**
     * @notice Submit an auditing proof for a batch of transactions
     * @param chainId The ordinary chain being audited
     * @param oldStateRoot State root before transactions (root_2)
     * @param newStateRoot State root after transactions (root_3)
     * @param proofA Proof element A
     * @param proofB Proof element B
     * @param proofC Proof element C
     * 
     * @dev TxCommit = (From: CT, To: ξ, x_vec, π)
     * 
     * Public inputs (x_vec): initial root (root_2), final root (root_3)
     * Private inputs (w_vec): account states, transaction content, signatures
     * 
     * The proof π_Ψ proves (via circuit Λ_Ψ):
     *   1. AF:  All senders are NOT in blacklist
     *   2. SVF: All transaction signatures are valid
     *   3. STF: State transitions are correct
     *   4. RVF: Old and new roots match state trees
     * 
     * Proof size: constant 127.38 bytes regardless of transaction count
     */
    function submitCommit(
        uint256 chainId,
        bytes32 oldStateRoot,
        bytes32 newStateRoot,
        uint256[2] memory proofA,
        uint256[2][2] memory proofB,
        uint256[2] memory proofC
    ) external {
        require(committers[msg.sender].isRegistered, "Not a registered committer");
        require(chains[chainId].isActive, "Chain not active");
        require(chains[chainId].latestStateRoot == oldStateRoot, 
                "Old root mismatch - must chain from latest verified root");

        // Generate commit ID
        bytes32 commitId = keccak256(abi.encodePacked(
            msg.sender, chainId, oldStateRoot, newStateRoot, block.number
        ));

        require(commits[commitId].timestamp == 0, "Commit ID collision");

        // Store commit record (verification happens in Ψ.Audit)
        commits[commitId] = CommitRecord({
            committer: msg.sender,
            chainId: chainId,
            oldStateRoot: oldStateRoot,
            newStateRoot: newStateRoot,
            timestamp: block.timestamp,
            isVerified: false
        });

        commitIds.push(commitId);

        emit CommitSubmitted(commitId, msg.sender, chainId, oldStateRoot, newStateRoot);
    }

    // ==========================================
    // Ψ.Audit - Verify auditing proof
    // ==========================================

    /**
     * @notice Verify an auditing proof submitted by a committer
     * @param commitId The commit to verify
     * @param proofA Proof element A
     * @param proofB Proof element B
     * @param proofC Proof element C
     * 
     * @dev Auditors call Π.Verify(vk, x_vec, π_Ψ) to verify the proof.
     * On success:
     *   - Latest state root is updated
     *   - root_3 is stored as a new leaf in audit chain state tree
     *   - Committer receives reward
     * 
     * The verification is O(1) regardless of transaction count in the block,
     * compared to O(n) for full auditing of n transactions.
     */
    function verifyCommit(
        bytes32 commitId,
        uint256[2] memory proofA,
        uint256[2][2] memory proofB,
        uint256[2] memory proofC
    ) external {
        require(auditors[msg.sender], "Not an auditor");

        CommitRecord storage record = commits[commitId];
        require(record.timestamp > 0, "Commit not found");
        require(!record.isVerified, "Already verified");

        // Construct proof
        Groth16Verifier.Proof memory proof = Groth16Verifier.Proof({
            a: Groth16Verifier.G1Point(proofA[0], proofA[1]),
            b: Groth16Verifier.G2Point(proofB[0], proofB[1]),
            c: Groth16Verifier.G1Point(proofC[0], proofC[1])
        });

        // Public inputs: root_2 (old), root_3 (new)
        uint256[] memory publicInputs = new uint256[](2);
        publicInputs[0] = uint256(record.oldStateRoot);
        publicInputs[1] = uint256(record.newStateRoot);

        // Verify zk-SNARK proof: Π.Verify(vk_Ψ, x_vec, π_Ψ)
        require(
            Groth16Verifier.verify(vk_psi, proof, publicInputs),
            "Audit proof verification failed"
        );

        // Mark as verified
        record.isVerified = true;

        // Update chain state
        ChainInfo storage chain = chains[record.chainId];
        chain.latestStateRoot = record.newStateRoot;
        chain.lastUpdateBlock = block.number;
        chain.totalCommits++;

        // Store new root in state history (audit chain state tree leaf)
        chainStateHistory[record.chainId].push(record.newStateRoot);

        // Reward committer
        CommitterInfo storage committer = committers[record.committer];
        committer.totalCommits++;
        committer.rewards += rewardPerCommit;

        emit CommitVerified(commitId, record.chainId, record.newStateRoot, msg.sender);
    }

    // ==========================================
    // Reward Distribution
    // ==========================================

    /**
     * @notice Claim accumulated rewards
     */
    function claimRewards() external {
        CommitterInfo storage committer = committers[msg.sender];
        require(committer.isRegistered, "Not a committer");
        require(committer.rewards > 0, "No rewards");

        uint256 amount = committer.rewards;
        committer.rewards = 0;

        (bool success, ) = payable(msg.sender).call{value: amount}("");
        require(success, "Transfer failed");

        emit RewardClaimed(msg.sender, amount);
    }

    // ==========================================
    // View Functions
    // ==========================================

    /// @notice Get the number of registered chains
    function getChainCount() external view returns (uint256) {
        return chainList.length;
    }

    /// @notice Get chain state history length
    function getChainStateHistoryLength(uint256 chainId) external view returns (uint256) {
        return chainStateHistory[chainId].length;
    }

    /// @notice Get a specific historical state root
    function getChainStateRoot(uint256 chainId, uint256 index) external view returns (bytes32) {
        return chainStateHistory[chainId][index];
    }

    /// @notice Get total number of commits
    function getCommitCount() external view returns (uint256) {
        return commitIds.length;
    }

    /// @notice Get number of registered committers
    function getCommitterCount() external view returns (uint256) {
        return committerList.length;
    }

    /// @notice Check if a commit is verified
    function isCommitVerified(bytes32 commitId) external view returns (bool) {
        return commits[commitId].isVerified;
    }

    /// @notice Get committer info
    function getCommitterInfo(address addr) external view returns (
        uint256 totalCommits, uint256 rewards, bool isRegistered
    ) {
        CommitterInfo memory info = committers[addr];
        return (info.totalCommits, info.rewards, info.isRegistered);
    }

    // ==========================================
    // Tree-Shaped Topology: Intermediate Aggregation
    // ==========================================
    // Per paper Section 3.2 (Challenge FAI): the audit architecture uses a
    // tree-shaped topology, NOT a star topology. Intermediate nodes aggregate
    // proofs from sub-chains before forwarding to the audit chain.
    // Per Theorem 2: Protocol Ψ provides an n-fold reduction in audit cost
    // (from t1·k·m·n to t2·k·m). The tree distributes committer workload.

    /// @notice Represents a node in the tree topology
    struct TreeNode {
        uint256 nodeId;
        uint256 parentNodeId;       // 0 = root (audit chain itself)
        uint256[] childChainIds;    // Ordinary chains under this node
        uint256[] childNodeIds;     // Sub-intermediate nodes
        bytes32 aggregatedRoot;     // Aggregated state root of all children
        address assignedCommitter;  // Committer responsible for this node
        bool isActive;
    }

    /// @notice Tree nodes: nodeId => TreeNode
    mapping(uint256 => TreeNode) public treeNodes;
    uint256[] public nodeList;
    uint256 public nextNodeId = 1;

    event TreeNodeCreated(uint256 indexed nodeId, uint256 parentNodeId, address committer);
    event AggregatedCommitSubmitted(uint256 indexed nodeId, bytes32 aggregatedRoot);

    /**
     * @notice Create an intermediate node in the tree topology
     * @param parentNodeId Parent node (0 = direct child of audit chain root)
     * @param childChainIds Ordinary chains aggregated by this node
     * @param committer Committer responsible for this intermediate node
     * @dev Builds the tree hierarchy: audit chain → intermediate nodes → ordinary chains
     *      Per Theorem 2, Protocol Ψ reduces audit cost by factor n (number of
     *      txs per block). The tree distributes committer work across nodes.
     */
    function createTreeNode(
        uint256 parentNodeId,
        uint256[] calldata childChainIds,
        address committer
    ) external returns (uint256) {
        require(msg.sender == owner, "Only owner");
        require(committers[committer].isRegistered, "Committer not registered");

        // Verify all child chains are registered
        for (uint256 i = 0; i < childChainIds.length; i++) {
            require(chains[childChainIds[i]].isActive, "Child chain not registered");
        }

        // If parent is nonzero, verify it exists
        if (parentNodeId > 0) {
            require(treeNodes[parentNodeId].isActive, "Parent node not found");
        }

        uint256 nodeId = nextNodeId++;
        treeNodes[nodeId] = TreeNode({
            nodeId: nodeId,
            parentNodeId: parentNodeId,
            childChainIds: childChainIds,
            childNodeIds: new uint256[](0),
            aggregatedRoot: bytes32(0),
            assignedCommitter: committer,
            isActive: true
        });

        // Register this node as a child of the parent
        if (parentNodeId > 0) {
            treeNodes[parentNodeId].childNodeIds.push(nodeId);
        }

        nodeList.push(nodeId);
        emit TreeNodeCreated(nodeId, parentNodeId, committer);
        return nodeId;
    }

    /**
     * @notice Submit an aggregated commit for an intermediate tree node
     * @param nodeId The tree node submitting the aggregated proof
     * @param childRoots The state roots of each child (chain or sub-node), in order
     * @param aggregatedRoot The Merkle root of all childRoots (tree aggregation)
     * @param proofA Aggregated Groth16 proof element A
     * @param proofB Aggregated Groth16 proof element B
     * @param proofC Aggregated Groth16 proof element C
     * @dev The intermediate committer:
     *      1. Collects state roots from child chains/sub-nodes
     *      2. Computes aggregated Merkle root over all children
     *      3. Generates a single ZKP proving validity of all sub-proofs
     *      4. Submits ONE aggregated proof instead of N individual proofs
     *      Per Theorem 2, Protocol Ψ achieves n-fold audit cost reduction.
     */
    function submitAggregatedCommit(
        uint256 nodeId,
        bytes32[] calldata childRoots,
        bytes32 aggregatedRoot,
        uint256[2] memory proofA,
        uint256[2][2] memory proofB,
        uint256[2] memory proofC
    ) external {
        TreeNode storage node = treeNodes[nodeId];
        require(node.isActive, "Node not active");
        require(node.assignedCommitter == msg.sender, "Not assigned committer");
        require(childRoots.length == node.childChainIds.length + node.childNodeIds.length,
                "Root count mismatch");

        // Verify aggregated proof
        Groth16Verifier.Proof memory proof = Groth16Verifier.Proof({
            a: Groth16Verifier.G1Point(proofA[0], proofA[1]),
            b: Groth16Verifier.G2Point(proofB[0], proofB[1]),
            c: Groth16Verifier.G1Point(proofC[0], proofC[1])
        });

        // Public inputs: old aggregated root + new aggregated root
        uint256[] memory publicInputs = new uint256[](2);
        publicInputs[0] = uint256(node.aggregatedRoot);
        publicInputs[1] = uint256(aggregatedRoot);

        require(
            Groth16Verifier.verify(vk_psi, proof, publicInputs),
            "Aggregated proof verification failed"
        );

        // Update child chain roots
        for (uint256 i = 0; i < node.childChainIds.length; i++) {
            uint256 cid = node.childChainIds[i];
            chains[cid].latestStateRoot = childRoots[i];
            chains[cid].lastUpdateBlock = block.number;
            chains[cid].totalCommits++;
            chainStateHistory[cid].push(childRoots[i]);
        }

        // Update aggregated root
        node.aggregatedRoot = aggregatedRoot;

        // Reward committer
        CommitterInfo storage committer = committers[msg.sender];
        committer.totalCommits++;
        committer.rewards += rewardPerCommit;

        emit AggregatedCommitSubmitted(nodeId, aggregatedRoot);
    }

    /// @notice Get tree node children
    function getTreeNodeChildren(uint256 nodeId) external view returns (
        uint256[] memory childChains, uint256[] memory childNodes
    ) {
        TreeNode storage node = treeNodes[nodeId];
        return (node.childChainIds, node.childNodeIds);
    }

    /// @notice Fund the contract for rewards
    receive() external payable {}
}
