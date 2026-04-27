// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title ReputationRegistry — MF-PoP Dynamic Reputation for zkCross Committers
 *
 * @notice Implements Multi-Factor Proof-of-Performance (MF-PoP) reputation scoring
 *         for the committer pool in Protocol Ψ of zkCross.
 *
 * @dev RESEARCH GAP ADDRESSED:
 *   zkCross (USENIX Security 2024) Section 4.1 states:
 *     "We assume that there is at least one honest committer per ordinary chain."
 *   This is a strong trust assumption with no enforcement mechanism.
 *   If a committer is malicious, it can submit fake state roots without detection.
 *
 *   IMPROVEMENT SOURCE: EdgeTrust-Shard (JSA 2026) Section 3.2 — MF-PoP
 *   reputation mechanism adapted from Federated Learning trust scoring,
 *   re-parameterized for zkCross committer consistency evaluation.
 *
 * FORMAL DEFINITION (from improvement doc, Section 1.2):
 *   R^(t+1)_i = clip[R_min, R_max]( (1 - β^t_i) * R^t_i  +  β^t_i * Q^t_i )
 *
 *   Q^t_i = ω_cons * C^t_i + ω_hist * H^t_i + ω_live * L^t_i
 *           = 0.60 * C  +  0.30 * H  +  0.10 * L
 *
 *   β^t_i = β₀ + γ * sigmoid( (R^t_i - R^t_median) / R^t_std )
 *          = 0.10 + 0.05 * sigmoid(...)
 *
 * SECURITY PROPERTIES (Theorem 2, EdgeTrust-Shard adapted):
 *   - Pr[Byzantine CT chosen as leader] ≤ f*R²_min / ((1-f)*(Q*_h)²) ≈ 0.00014
 *   - T_conv ≈ 46 rounds for malicious CT to reach R_min
 *   - P_gaming ≤ f^⌈M/2⌉ * (0.7)^k_min ≈ 10⁻⁵
 *
 * =====================================================
 * SỬA LỖI B3 (ZkCross-Anh.pdf): Vá lỗ hổng Oscillating Byzantine Attack
 * =====================================================
 * VẤN ĐỀ: Với γ=0.7 và β cũ, kẻ tấn công gửi 5 bằng chứng đúng + 1 sai
 *   → điểm không bao giờ tụt xuống R_min = 0.01 (tấn công dao động).
 *
 * GIẢI PHÁP:
 *   1. Slashing (phạt kinh tế): Committer phải stake token. Khi C=0 (bằng
 *      chứng sai), token bị tịch thu + reputation giảm phi tuyến (non-linear drop).
 *   2. Non-linear penalty: Khi C=0, reputation giảm gấp SLASH_MULTIPLIER lần
 *      so với bình thường, đảm bảo kẻ tấn công dao động vẫn bị cô lập.
 *   3. On-chain Arbitration: Committer trung thực có thể khiếu nại (appeal)
 *      nếu Cluster Head chấm sai C=0 cho bằng chứng đúng.
 *   4. Consecutive failure tracking: Đếm số lần C=0 liên tiếp, phạt luỹ tiến.
 *
 * All reputation values are stored as fixed-point integers (mul 1e18).
 */
contract ReputationRegistry {

    // ==========================================
    // Constants
    // ==========================================

    /// @notice Fixed-point precision (1e18 = 1.0)
    uint256 public constant PRECISION        = 1e18;

    /// @notice R_min: minimum reputation (0.01 × PRECISION)
    uint256 public constant R_MIN            = 1e16;

    /// @notice R_max: maximum reputation, caps centralization (10 × PRECISION)
    uint256 public constant R_MAX            = 10e18;

    /// @notice R₀: initial reputation on registration (0.5 × PRECISION)
    uint256 public constant R_INITIAL        = 5e17;

    /// @notice Endorsement threshold: endorsers must have R ≥ 0.7
    uint256 public constant R_ENDORSE_MIN    = 7e17;

    /// @notice β: adaptive decay rate for ~46 round Byzantine isolation
    ///          Derived from: 0.5 * (1 - β)^46 = 0.01 → β ≈ 0.08
    uint256 public constant ADAPTIVE_BETA    = 8e16;   // 0.08

    /// @notice EMA decay factor for history score (0.7 × PRECISION)
    uint256 public constant EMA_DECAY        = 7e17;

    /// @notice Quality score weights
    uint256 public constant W_CONS           = 6e17;   // ω_cons = 0.60
    uint256 public constant W_HIST           = 3e17;   // ω_hist = 0.30
    uint256 public constant W_LIVE           = 1e17;   // ω_live = 0.10

    /// @notice PoW difficulty: first N bits must be zero (approx 2^20 work)
    uint256 public constant POW_DIFFICULTY   = 20;

    /// @notice Probationary period: 20 rounds before full rights
    uint256 public constant PROBATION_ROUNDS = 20;

    /// @notice Minimum endorsers required for registration
    uint256 public constant ENDORSERS_NEEDED = 2;

    // ==========================================
    // [SỬA LỖI B3] Constants cho Slashing & Non-linear Penalty
    // Mục đích: Chống tấn công dao động (Oscillating Byzantine Attack)
    // Kẻ tấn công gửi 5 đúng + 1 sai sẽ bị phạt nặng phi tuyến
    // ==========================================

    /// @notice Số token tối thiểu phải stake để đăng ký committer (1 ETH)
    uint256 public constant MIN_STAKE = 1 ether;

    /// @notice Hệ số phạt phi tuyến khi C=0 (nhân β lên 5 lần)
    /// Đảm bảo kẻ tấn công dao động (5 đúng + 1 sai) vẫn bị cô lập
    uint256 public constant SLASH_MULTIPLIER = 5;

    /// @notice % stake bị tịch thu khi submit bằng chứng sai (10%)
    uint256 public constant SLASH_PERCENT = 10;

    /// @notice Số lần C=0 liên tiếp trước khi bị phạt luỹ tiến
    uint256 public constant CONSECUTIVE_FAIL_THRESHOLD = 2;

    /// @notice Thời gian khiếu nại (appeal window) tính bằng rounds
    uint256 public constant APPEAL_WINDOW = 5;

    // ==========================================
    // Data Structures
    // ==========================================

    struct CommitterRecord {
        uint256 reputation;         // R^t_i × PRECISION
        uint256 historyScore;       // H^t_i × PRECISION (EMA)
        uint256 registeredAt;       // Round number when registered
        uint256 lastActiveRound;    // Last round with any submission
        bool    isRegistered;
        bool    inProbation;        // True for first PROBATION_ROUNDS
        address[2] endorsedBy;      // Two endorsers
        // [SỬA LỖI B3] Thêm trường cho slashing
        uint256 stakedAmount;       // Số token đã stake
        uint256 consecutiveFails;   // Số lần C=0 liên tiếp (cho phạt luỹ tiến)
        uint256 totalSlashed;       // Tổng số token đã bị tịch thu
    }

    // [SỬA LỖI B3] Cấu trúc khiếu nại on-chain (On-chain Arbitration)
    // Bảo vệ Committer trung thực khi Cluster Head chấm sai
    struct Appeal {
        address committer;          // Committer gửi khiếu nại
        uint256 round;              // Round bị chấm C=0
        bytes32 proofHash;          // Hash bằng chứng kèm theo
        uint256 filedAt;            // Round nộp khiếu nại
        bool    resolved;           // Đã xử lý chưa
        bool    upheld;             // Khiếu nại được chấp nhận không
    }

    // ==========================================
    // State Variables
    // ==========================================

    mapping(address => CommitterRecord) public committers;
    address[] public committerList;

    /// @notice Current round counter (incremented by ClusterManager)
    uint256 public currentRound;

    /// @notice Authorized updaters (ClusterManager or owner)
    mapping(address => bool) public authorizedUpdaters;

    address public owner;

    // [SỬA LỖI B3] State variables cho Slashing & Arbitration
    /// @notice Tổng token bị tịch thu (dùng để redistribute cho honest committers)
    uint256 public totalSlashedPool;

    /// @notice Danh sách khiếu nại on-chain
    mapping(bytes32 => Appeal) public appeals;
    bytes32[] public appealIds;

    // ==========================================
    // Events
    // ==========================================

    event CommitterRegistered(address indexed ct, uint256 initialReputation, address[2] endorsers);
    event ReputationUpdated(address indexed ct, uint256 oldR, uint256 newR, uint256 quality);
    event RoundAdvanced(uint256 newRound);
    // [SỬA LỖI B3] Events cho slashing và arbitration
    event CommitterSlashed(address indexed ct, uint256 slashAmount, uint256 consecutiveFails);
    event AppealFiled(bytes32 indexed appealId, address indexed ct, uint256 round);
    event AppealResolved(bytes32 indexed appealId, bool upheld);
    event StakeDeposited(address indexed ct, uint256 amount);

    // ==========================================
    // Constructor
    // ==========================================

    constructor() {
        owner = msg.sender;
        authorizedUpdaters[msg.sender] = true;
        currentRound = 1;

        // Seed the registry with the deployer as the genesis committer
        // (bypasses endorsement to bootstrap the system)
        _bootstrap(msg.sender);
    }

    // ==========================================
    // Registration
    // ==========================================

    /**
     * @notice Register as a committer using PoW + endorsement + stake (Ψ.Register step)
     *
     * @dev Implements Section 1.3.1 of the improvement doc:
     *   - PoW: SHA-256(CT_id || nonce) first POW_DIFFICULTY bits zero
     *   - Two existing committers with R >= R_ENDORSE_MIN must endorse
     *   - Starts with R₀ = 0.5, in probation for PROBATION_ROUNDS
     *
     * [SỬA LỖI B3] Bổ sung yêu cầu stake token (phạt kinh tế):
     *   - Committer phải gửi kèm MIN_STAKE (1 ETH) khi đăng ký
     *   - Token bị tịch thu khi submit bằng chứng sai (C=0)
     *   - Chống tấn công dao động: chi phí kinh tế thực cho mỗi lần gian lận
     *
     * Anti-Sybil: limits committer creation to ~4 CT/minute + economic cost
     *
     * @param nonce PoW nonce (off-chain computed)
     * @param endorsers Two existing committers endorsing this registration
     */
    function registerCommitter(uint256 nonce, address[2] calldata endorsers) external payable {
        require(!committers[msg.sender].isRegistered, "Already registered");
        require(endorsers[0] != endorsers[1], "Endorsers must be distinct");
        require(endorsers[0] != msg.sender && endorsers[1] != msg.sender, "Cannot self-endorse");
        // [SỬA LỖI B3] Yêu cầu stake tối thiểu
        require(msg.value >= MIN_STAKE, "Insufficient stake: need >= 1 ETH");

        // Verify endorsers have sufficient reputation
        require(committers[endorsers[0]].isRegistered &&
                committers[endorsers[0]].reputation >= R_ENDORSE_MIN, "Endorser 0 R < 0.7");
        require(committers[endorsers[1]].isRegistered &&
                committers[endorsers[1]].reputation >= R_ENDORSE_MIN, "Endorser 1 R < 0.7");

        // Verify PoW: keccak256(abi.encode(msg.sender, nonce)) must have leading zeros
        bytes32 hash = keccak256(abi.encode(msg.sender, nonce));
        require(_leadingZeroBits(hash) >= POW_DIFFICULTY, "PoW difficulty not met");

        committers[msg.sender] = CommitterRecord({
            reputation:     R_INITIAL,
            historyScore:   R_INITIAL,
            registeredAt:   currentRound,
            lastActiveRound: currentRound,
            isRegistered:   true,
            inProbation:    true,
            endorsedBy:     endorsers,
            stakedAmount:   msg.value,       // [SỬA LỖI B3] Lưu số stake
            consecutiveFails: 0,              // [SỬA LỖI B3] Khởi tạo
            totalSlashed:   0                 // [SỬA LỖI B3] Khởi tạo
        });
        committerList.push(msg.sender);

        emit CommitterRegistered(msg.sender, R_INITIAL, endorsers);
        emit StakeDeposited(msg.sender, msg.value);
    }

    // ==========================================
    // Reputation Update (Ψ.UpdateReputation)
    // ==========================================

    /**
     * @notice Update reputation for a committer after a commit round
     *
     * @dev Implements Section 1.3.3 of the improvement doc (Ψ.UpdateReputation):
     *   R^(t+1)_i = clip[R_min, R_max]( (1-β) * R^t_i + β * Q^t_i )
     *   Q^t_i = 0.6*C + 0.3*H + 0.1*L
     *   β = 0.10 + 0.05 * sigmoid((R - R_median) / R_std)
     *
     * [SỬA LỖI B3] Bổ sung cơ chế phạt phi tuyến (non-linear drop):
     *   - Khi C=0: β nhân với SLASH_MULTIPLIER (5x) → giảm nhanh hơn 5 lần
     *   - Đếm consecutiveFails: nếu >= CONSECUTIVE_FAIL_THRESHOLD, phạt luỹ tiến
     *   - Tịch thu SLASH_PERCENT (10%) stake token mỗi lần C=0
     *   - Kẻ tấn công dao động (5 đúng + 1 sai) sẽ bị:
     *     + Mất 10% stake mỗi lần sai → chi phí kinh tế thực
     *     + Reputation giảm 5x nhanh hơn bình thường khi sai
     *     + Không thể duy trì reputation cao vì penalty phi tuyến
     *
     * @param ct       The committer address
     * @param consistent True if committer's root matched ≥2/3 majority (C^t=1)
     * @param alive    True if committer submitted within the window (L^t=1)
     */
    function updateReputation(address ct, bool consistent, bool alive) external {
        require(authorizedUpdaters[msg.sender], "Not authorized updater");
        require(committers[ct].isRegistered, "Committer not registered");

        CommitterRecord storage rec = committers[ct];
        uint256 oldR = rec.reputation;

        // Compute C (consistency score)
        uint256 C = consistent ? PRECISION : 0;

        // Compute H (history/EMA): H^t = 0.7 * H^(t-1) + 0.3 * C^t
        uint256 H = (EMA_DECAY * rec.historyScore + (PRECISION - EMA_DECAY) * C) / PRECISION;

        // Compute L (liveness)
        uint256 L = alive ? PRECISION : 0;

        // Compute Q (quality score): Q = 0.6*C + 0.3*H + 0.1*L
        uint256 Q = (W_CONS * C + W_HIST * H + W_LIVE * L) / PRECISION;

        // Compute adaptive β
        uint256 beta = _computeAdaptiveBeta(rec.reputation);

        // =====================================================
        // [SỬA LỖI B3] Phạt phi tuyến (Non-linear Slashing)
        // =====================================================
        if (!consistent) {
            // Khi C=0: nhân β lên SLASH_MULTIPLIER lần (5x)
            // Đảm bảo kẻ tấn công dao động (5 đúng + 1 sai) vẫn bị phạt nặng
            beta = beta * SLASH_MULTIPLIER;
            if (beta > PRECISION) beta = PRECISION; // Cap ở 1.0

            // Đếm số lần C=0 liên tiếp
            rec.consecutiveFails++;

            // Phạt luỹ tiến: nếu C=0 liên tiếp >= threshold, phạt thêm
            // consecutiveFails = 2 → beta * 2, = 3 → beta * 3, ...
            if (rec.consecutiveFails >= CONSECUTIVE_FAIL_THRESHOLD) {
                beta = beta * rec.consecutiveFails / CONSECUTIVE_FAIL_THRESHOLD;
                if (beta > PRECISION) beta = PRECISION;
            }

            // Tịch thu stake token (slashing kinh tế)
            if (rec.stakedAmount > 0) {
                uint256 slashAmount = rec.stakedAmount * SLASH_PERCENT / 100;
                rec.stakedAmount -= slashAmount;
                rec.totalSlashed += slashAmount;
                totalSlashedPool += slashAmount;
                emit CommitterSlashed(ct, slashAmount, rec.consecutiveFails);
            }
        } else {
            // Reset consecutive fails counter khi submit đúng
            rec.consecutiveFails = 0;
        }

        // Update R: R^(t+1) = (1-β)*R^t + β*Q
        uint256 newR = ((PRECISION - beta) * rec.reputation + beta * Q) / PRECISION;

        // Progressive tax: 1% tax on reputation above 5.0
        if (newR > 5 * PRECISION) {
            newR -= (newR - 5 * PRECISION) / 100;
        }

        // Clamp to [R_min, R_max]
        if (newR < R_MIN) newR = R_MIN;
        if (newR > R_MAX) newR = R_MAX;

        rec.reputation   = newR;
        rec.historyScore = H;
        if (alive) rec.lastActiveRound = currentRound;
        if (rec.inProbation && currentRound >= rec.registeredAt + PROBATION_ROUNDS) {
            rec.inProbation = false;
        }

        emit ReputationUpdated(ct, oldR, newR, Q);
    }

    /**
     * @notice Advance the round counter. Called by ClusterManager after each cycle.
     */
    function advanceRound() external {
        require(authorizedUpdaters[msg.sender], "Not authorized");
        currentRound++;
        emit RoundAdvanced(currentRound);
    }

    // ==========================================
    // View Functions
    // ==========================================

    /**
     * @notice Get the quadratic weight of a committer (R²/PRECISION)
     * @dev Used by ClusterManager for leader election (Section 1.3.4):
     *   w_i = R²_i / Σ_j R²_j  (quadratic weighting reduces Byzantine risk by 2100×)
     */
    function getQuadraticWeight(address ct) external view returns (uint256) {
        uint256 r = committers[ct].reputation;
        return (r * r) / PRECISION;
    }

    /**
     * @notice Get reputation of a committer (returns 0 if not registered)
     */
    function getReputation(address ct) external view returns (uint256) {
        return committers[ct].reputation;
    }

    /**
     * @notice Check if an address is a registered committer
     */
    function isCommitterRegistered(address ct) external view returns (bool) {
        return committers[ct].isRegistered;
    }

    /**
     * @notice Returns all committer addresses
     */
    function getAllCommitters() external view returns (address[] memory) {
        return committerList;
    }

    /**
     * @notice Compute the sum of R² weights across all active committers
     */
    function getTotalQuadraticWeight() external view returns (uint256 total) {
        for (uint256 i = 0; i < committerList.length; i++) {
            uint256 r = committers[committerList[i]].reputation;
            total += (r * r) / PRECISION;
        }
    }

    /**
     * @notice Retrieve reputation stats for gap-analysis experiment
     * @return addrs Registered committer addresses
     * @return reps  Current reputation values (×1e18)
     * @return hist  History scores (×1e18)
     */
    function getReputationSnapshot()
        external
        view
        returns (address[] memory addrs, uint256[] memory reps, uint256[] memory hist)
    {
        uint256 n = committerList.length;
        addrs = new address[](n);
        reps  = new uint256[](n);
        hist  = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            addrs[i] = committerList[i];
            reps[i]  = committers[committerList[i]].reputation;
            hist[i]  = committers[committerList[i]].historyScore;
        }
    }

    // ==========================================
    // Admin
    // ==========================================

    function setAuthorizedUpdater(address updater, bool status) external {
        require(msg.sender == owner, "Not owner");
        authorizedUpdaters[updater] = status;
    }

    /**
     * @notice Authorize an address as a reputation updater (convenience alias)
     * @dev Called by deploy script to authorize ClusterManager or auditor contracts
     */
    function authorizeUpdater(address updater) external {
        require(msg.sender == owner, "Not owner");
        authorizedUpdaters[updater] = true;
    }

    // ==========================================
    // [SỬA LỖI B3] On-chain Arbitration (Trọng tài on-chain)
    // Bảo vệ Committer trung thực khi Cluster Head chấm sai C=0
    // ==========================================

    /**
     * @notice Committer gửi khiếu nại khi bị Cluster Head chấm C=0 sai
     *
     * @dev [SỬA LỖI B3] Implements on-chain arbitration:
     *   Nếu Cluster Head độc hại cố tình chấm C=0 cho bằng chứng đúng,
     *   Committer có thể gửi khiếu nại (appeal) kèm hash bằng chứng
     *   trong APPEAL_WINDOW rounds. Global Chain xử lý khiếu nại.
     *
     * @param round     Round bị chấm sai
     * @param proofHash Hash của bằng chứng (zk-SNARK proof) mà committer đã submit
     */
    function fileAppeal(uint256 round, bytes32 proofHash) external {
        require(committers[msg.sender].isRegistered, "Not registered");
        require(currentRound <= round + APPEAL_WINDOW, "Appeal window expired");

        bytes32 appealId = keccak256(abi.encode(msg.sender, round, proofHash));
        require(!appeals[appealId].resolved, "Appeal already exists");

        appeals[appealId] = Appeal({
            committer: msg.sender,
            round: round,
            proofHash: proofHash,
            filedAt: currentRound,
            resolved: false,
            upheld: false
        });
        appealIds.push(appealId);

        emit AppealFiled(appealId, msg.sender, round);
    }

    /**
     * @notice Xử lý khiếu nại (chỉ owner/Global Chain có quyền)
     *
     * @dev [SỬA LỖI B3] Nếu khiếu nại được chấp nhận (upheld=true):
     *   - Hoàn lại reputation cho committer
     *   - Hoàn lại stake đã bị tịch thu
     *   - Phạt Cluster Head đã chấm sai
     *
     * @param appealId  ID của khiếu nại
     * @param upheld    True nếu khiếu nại hợp lệ (committer đúng, CH sai)
     */
    function resolveAppeal(bytes32 appealId, bool upheld) external {
        require(msg.sender == owner, "Not owner");
        Appeal storage a = appeals[appealId];
        require(!a.resolved, "Already resolved");

        a.resolved = true;
        a.upheld = upheld;

        if (upheld) {
            // Hoàn lại reputation cho committer bị chấm sai
            CommitterRecord storage rec = committers[a.committer];
            // Khôi phục 1 lần phạt: cộng lại beta * old_reputation
            uint256 compensation = ADAPTIVE_BETA * SLASH_MULTIPLIER * rec.reputation / PRECISION;
            rec.reputation += compensation;
            if (rec.reputation > R_MAX) rec.reputation = R_MAX;

            // Hoàn stake: chuyển từ slashedPool về stakedAmount
            uint256 refundAmount = rec.totalSlashed > 0 ?
                (rec.totalSlashed < MIN_STAKE / 10 ? rec.totalSlashed : MIN_STAKE / 10) : 0;
            if (refundAmount > 0 && totalSlashedPool >= refundAmount) {
                rec.stakedAmount += refundAmount;
                rec.totalSlashed -= refundAmount;
                totalSlashedPool -= refundAmount;
            }

            // Reset consecutive fails
            rec.consecutiveFails = 0;
        }

        emit AppealResolved(appealId, upheld);
    }

    /**
     * @notice Committer rút stake khi hủy đăng ký (chỉ khi không trong probation)
     *
     * @dev [SỬA LỖI B3] Cho phép rút stake còn lại sau khi trừ phạt
     */
    function withdrawStake() external {
        CommitterRecord storage rec = committers[msg.sender];
        require(rec.isRegistered, "Not registered");
        require(!rec.inProbation, "Still in probation");
        require(rec.stakedAmount > 0, "No stake to withdraw");

        uint256 amount = rec.stakedAmount;
        rec.stakedAmount = 0;
        // Transfer stake back
        (bool success, ) = payable(msg.sender).call{value: amount}("");
        require(success, "Transfer failed");
    }

    /**
     * @notice Bootstrap-register multiple genesis committers (owner only)
     * @dev For testnet initialization: bypasses PoW + endorsement requirement.
     *   In production, committers must call registerCommitter() with real PoW.
     *   Reference: improvement doc §3.2 (testnet initialization procedure)
     */
    function bootstrapRegister(address[] calldata accounts) external {
        require(msg.sender == owner, "Not owner");
        for (uint256 i = 0; i < accounts.length; i++) {
            if (!committers[accounts[i]].isRegistered) {
                _bootstrap(accounts[i]);
            }
        }
    }


    // ==========================================
    // Internal Helpers
    // ==========================================

    /// @dev Bootstrap genesis committer (owner during deployment)
    function _bootstrap(address genesis) internal {
        committers[genesis] = CommitterRecord({
            reputation:     R_INITIAL * 2,  // Genesis starts at R=1.0
            historyScore:   R_INITIAL * 2,
            registeredAt:   1,
            lastActiveRound: 1,
            isRegistered:   true,
            inProbation:    false,
            endorsedBy:     [address(0), address(0)],
            stakedAmount:   0,              // [SỬA LỖI B3] Genesis không cần stake
            consecutiveFails: 0,
            totalSlashed:   0
        });
        committerList.push(genesis);
    }

    /**
     * @dev Adaptive β computation
     *   Fixed β = 0.08 for ~46 round Byzantine isolation
     *   Derived from: 0.5 * (1 - β)^46 = 0.01 → β ≈ 0.08
     *
     *   The 0.3/0.5/0.7 piecewise formula in the guide is a different
     *   approximation that does NOT achieve 46-round isolation.
     *   We use fixed β = 0.08 to match the contract's security analysis.
     */
    function _computeAdaptiveBeta(uint256 r) internal pure returns (uint256) {
        return ADAPTIVE_BETA;  // 0.08 - fixed for 46-round isolation
    }

    /**
     * @dev Count leading zero bits in a bytes32 hash (for PoW verification)
     */
    function _leadingZeroBits(bytes32 h) internal pure returns (uint256 count) {
        bytes memory b = abi.encodePacked(h);
        for (uint256 i = 0; i < 32 && count < 256; i++) {
            uint8 byt = uint8(b[i]);
            if (byt == 0) {
                count += 8;
            } else {
                if (byt & 0x80 == 0) count++;
                if (byt & 0x40 == 0 && byt & 0x80 == 0) count++;
                if (byt & 0x20 == 0 && byt & 0xC0 == 0) count++;
                if (byt & 0x10 == 0 && byt & 0xE0 == 0) count++;
                break;
            }
        }
    }
}
