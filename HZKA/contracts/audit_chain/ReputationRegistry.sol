// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title ReputationRegistry — Canonical MF-PoP Dynamic Reputation
 *
 * @notice Implements the Canonical Multi-Factor Proof-of-Performance (MF-PoP)
 *         state machine (6-tuple) to evaluate committer reliability.
 *
 * FORMAL STATE MACHINE DEFINITION:
 *   X^t_i = (R_base, H, phi, V, S, J)
 *   Events: { VALID, INVALID, MISSING }
 *   
 *   SAFETY FAULT (INVALID):
 *     phi^t_i = 0.50 * phi^{t-1}_i
 *     V^t_i += 1
 *     S^t_i -= 0.10 * S^{t-1}_i
 * 
 *   BASE REPUTATION (R_base): Updated via Convex Average only on VALID/MISSING.
 *   TRUST JAIL: Triggered if (R_base * phi) <= 0.015. Absorbing state.
 */
contract ReputationRegistry {
    // ==========================================
    // Constants
    // ==========================================
    uint256 public constant PRECISION = 1e18;
    uint256 public constant R_MIN = 1e16;       // 0.01
    uint256 public constant R_MAX = 1e18;       // 1.0 (Maximum base reputation)
    uint256 public constant R_INITIAL = 5e17;   // 0.5
    uint256 public constant R_ENDORSE_MIN = 7e17; // 0.7
    uint256 public constant R_JAIL = 15e15;     // 0.015 (Trust Jail Threshold)

    uint256 public constant A_H = 16e14;        // a_h = 0.016 (Convex update)
    uint256 public constant GAMMA = 7e17;       // γ = 0.70 (History decay)
    uint256 public constant Q_L = 95e16;        // q_l = 0.95 (Missing decay penalty)
    uint256 public constant Q_S = 5e17;         // q_s = 0.50 (Geometric safety slash)
    uint256 public constant SIGMA = 1e17;       // σ = 0.10 (10% stake slash)

    uint256 public constant MIN_STAKE = 1 ether;
    uint256 public constant POW_DIFFICULTY = 20;
    uint256 public constant APPEAL_WINDOW = 5;

    enum EventType { VALID, INVALID, MISSING }

    // ==========================================
    // Data Structures
    // ==========================================
    struct StateSnapshot {
        uint256 baseReputation; // R_bar
        uint256 historyScore;   // H
        uint256 safetyMult;     // phi
        uint32  cumulativeV;    // V
        uint256 stakedAmount;   // S
        bool    isJailed;       // J
        
        bool    isRegistered;
        uint256 registeredAt;
        address[2] endorsedBy;
    }

    mapping(address => StateSnapshot) public states;
    address[] public committerList;
    
    uint256 public currentRound = 1;
    uint256 public totalSlashedPool;
    address public owner;
    
    // Authorization
    mapping(address => bool) public authorizedAuditors;

    // Appeals
    struct Appeal {
        address committer;
        uint256 round;
        bytes32 proofHash;
        uint256 filedAt;
        bool    resolved;
        bool    upheld;
    }
    mapping(bytes32 => Appeal) public appeals;
    mapping(bytes32 => StateSnapshot) private appealSnapshots;

    // Events
    event CommitterRegistered(address indexed ct, address[2] endorsers);
    event ReputationUpdated(address indexed ct, EventType e, uint256 effectiveR);
    event NodeJailed(address indexed ct);
    event AppealFiled(bytes32 indexed appealId, address indexed ct, uint256 round);
    event AppealResolved(bytes32 indexed appealId, bool upheld);

    constructor() {
        owner = msg.sender;
        authorizedAuditors[msg.sender] = true;
        _bootstrap(msg.sender);
    }

    // ==========================================
    // Registration
    // ==========================================
    function registerCommitter(uint256 nonce, address[2] calldata endorsers) external payable {
        require(!states[msg.sender].isRegistered, "Already registered");
        require(msg.value >= MIN_STAKE, "Insufficient stake");
        require(states[endorsers[0]].isRegistered && _getEffectiveR(states[endorsers[0]]) >= R_ENDORSE_MIN, "Endorser 0 invalid");
        require(states[endorsers[1]].isRegistered && _getEffectiveR(states[endorsers[1]]) >= R_ENDORSE_MIN, "Endorser 1 invalid");

        bytes32 hash = keccak256(abi.encode(msg.sender, nonce));
        require(_leadingZeroBits(hash) >= POW_DIFFICULTY, "PoW failed");

        states[msg.sender] = StateSnapshot({
            baseReputation: R_INITIAL,
            historyScore:   R_INITIAL,
            safetyMult:     PRECISION,
            cumulativeV:    0,
            stakedAmount:   msg.value,
            isJailed:       false,
            isRegistered:   true,
            registeredAt:   currentRound,
            endorsedBy:     endorsers
        });
        committerList.push(msg.sender);
        emit CommitterRegistered(msg.sender, endorsers);
    }

    // ==========================================
    // Canonical State Transition Update
    // ==========================================
    function updateState(address ct, EventType e, bytes32 proofHash) external {
        require(authorizedAuditors[msg.sender], "Not authorized auditor");
        StateSnapshot storage state = states[ct];
        require(state.isRegistered, "Not registered");

        if (state.isJailed) return; // Absorbing state

        // Capture snapshot before processing an INVALID fault (for appeal purposes)
        if (e == EventType.INVALID) {
            appealSnapshots[proofHash] = state;
        }

        // 1. History Update (Eq 14)
        if (e == EventType.VALID) {
            state.historyScore = (GAMMA * state.historyScore + (PRECISION - GAMMA) * PRECISION) / PRECISION;
        } else if (e == EventType.INVALID) {
            state.historyScore = (GAMMA * state.historyScore) / PRECISION;
        }

        // 2. Base Reputation Update (Eq 15)
        if (e == EventType.VALID) {
            uint256 Q = PRECISION; // Baseline Q simplified for VALID
            uint256 newRBase = ((PRECISION - A_H) * state.baseReputation + A_H * Q) / PRECISION;
            
            // Progressive Tax: 1% tax on reputation above 0.5
            if (newRBase > 5e17) {
                newRBase -= (newRBase - 5e17) / 100;
            }
            state.baseReputation = newRBase > R_MAX ? R_MAX : newRBase;
        } else if (e == EventType.MISSING) {
            state.baseReputation = (Q_L * state.baseReputation) / PRECISION;
        }

        // 3. Safety Fault Transition (Eq 16)
        if (e == EventType.INVALID) {
            state.safetyMult = (Q_S * state.safetyMult) / PRECISION;
            state.cumulativeV += 1;
            uint256 slash = (SIGMA * state.stakedAmount) / PRECISION;
            state.stakedAmount -= slash;
            totalSlashedPool += slash;
        }

        // 4. Effective Reputation & Jail Check (Eq 17)
        uint256 rEff = _getEffectiveR(state);
        if (rEff <= R_JAIL) {
            state.isJailed = true;
            emit NodeJailed(ct);
        }

        emit ReputationUpdated(ct, e, rEff);
    }

    // ==========================================
    // On-Chain Arbitration (Appeal)
    // ==========================================
    function fileAppeal(uint256 round, bytes32 proofHash) external {
        require(states[msg.sender].isRegistered, "Not registered");
        require(currentRound <= round + APPEAL_WINDOW, "Appeal window expired");

        bytes32 appealId = keccak256(abi.encode(msg.sender, round, proofHash));
        require(!appeals[appealId].resolved, "Already resolved");

        appeals[appealId] = Appeal({
            committer: msg.sender,
            round: round,
            proofHash: proofHash,
            filedAt: currentRound,
            resolved: false,
            upheld: false
        });
        emit AppealFiled(appealId, msg.sender, round);
    }

    function resolveAppeal(bytes32 appealId, bool upheld) external {
        require(authorizedAuditors[msg.sender], "Not authorized auditor");
        Appeal storage a = appeals[appealId];
        require(!a.resolved, "Appeal already resolved");

        a.resolved = true;
        a.upheld = upheld;

        if (upheld) {
            StateSnapshot memory snap = appealSnapshots[a.proofHash];
            require(snap.isRegistered, "Snapshot missing");
            
            // Refund slashed tokens dynamically
            uint256 slashedAmount = states[a.committer].stakedAmount < snap.stakedAmount ? 
                                    snap.stakedAmount - states[a.committer].stakedAmount : 0;
            if (slashedAmount > 0 && totalSlashedPool >= slashedAmount) {
                totalSlashedPool -= slashedAmount;
            }

            // Atomically restore full snapshot
            states[a.committer] = snap;
        }
        emit AppealResolved(appealId, upheld);
    }

    // ==========================================
    // View & Helpers
    // ==========================================
    function _getEffectiveR(StateSnapshot memory state) internal pure returns (uint256) {
        if (state.isJailed) return R_MIN;
        uint256 rEff = (state.baseReputation * state.safetyMult) / PRECISION;
        return rEff < R_MIN ? R_MIN : rEff;
    }

    function getEffectiveReputation(address ct) external view returns (uint256) {
        return _getEffectiveR(states[ct]);
    }

    function getQuadraticWeight(address ct) external view returns (uint256) {
        uint256 r = _getEffectiveR(states[ct]);
        return (r * r) / PRECISION;
    }

    function advanceRound() external {
        require(authorizedAuditors[msg.sender], "Not authorized");
        currentRound++;
    }

    function _bootstrap(address genesis) internal {
        states[genesis] = StateSnapshot({
            baseReputation: R_MAX,
            historyScore:   R_MAX,
            safetyMult:     PRECISION,
            cumulativeV:    0,
            stakedAmount:   0,
            isJailed:       false,
            isRegistered:   true,
            registeredAt:   1,
            endorsedBy:     [address(0), address(0)]
        });
        committerList.push(genesis);
    }
    
    function setAuthorizedAuditor(address auditor, bool status) external {
        require(msg.sender == owner, "Not owner");
        authorizedAuditors[auditor] = status;
    }

    function _leadingZeroBits(bytes32 h) internal pure returns (uint256 count) {
        bytes memory b = abi.encodePacked(h);
        for (uint256 i = 0; i < 32 && count < 256; i++) {
            uint8 byt = uint8(b[i]);
            if (byt == 0) { count += 8; } 
            else {
                if (byt & 0x80 == 0) count++;
                if (byt & 0x40 == 0 && byt & 0x80 == 0) count++;
                if (byt & 0x20 == 0 && byt & 0xC0 == 0) count++;
                if (byt & 0x10 == 0 && byt & 0xE0 == 0) count++;
                break;
            }
        }
    }
}