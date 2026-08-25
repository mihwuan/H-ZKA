#!/usr/bin/env python3
"""Core discrete-round protocol simulator for H-ZKA.

This module implements the canonical MF-PoP transition system, the
k-medoid cluster-formation objective, capped reputation-weighted cluster-head
election, and a calibrated audit-layer network model.  It is the shared engine
for the second-revision experiments (Byzantine/churn sweeps, adaptive and
colluding adversaries, clustering ablation, leakage estimation, fault
recovery, and communication accounting).

Equation numbers refer to the manuscript "H-ZKA: A Hierarchical
Zero-Knowledge Architecture for Byzantine-Resilient Cross-Chain Auditing".

Determinism
-----------
Every experiment seeds a dedicated ``numpy.random.Generator``.  Re-running a
script with the same ``--seed`` reproduces every reported number bit for bit.

Dependencies
------------
Python >= 3.9, numpy >= 1.24.  ``scipy`` is used only by the leakage
experiment.  No plotting library is required: experiments emit CSV/JSON and
the manuscript renders figures with pgfplots.
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field
from typing import Dict, List, Optional, Sequence, Tuple

import numpy as np

# ---------------------------------------------------------------------------
# Canonical MF-PoP constants (manuscript Section 4.1)
# ---------------------------------------------------------------------------

R_MIN = 0.01          # floor of the recoverable base reputation
R_MAX = 1.0
R_JAIL = 0.015        # safety-jail threshold, Eq. (16)
R_ELIG = 0.015        # election-eligibility threshold, Eq. (18)
R_INITIAL = 0.5       # default initialisation r_0
A_H = 0.016           # convex step of the valid-event update, Eq. (13)
GAMMA = 0.70          # history decay, Eq. (11)
Q_L = 0.95            # liveness (omission) decay, Eq. (14)
Q_S = 0.50            # non-resetting safety multiplier decay, Eq. (15)
SIGMA = 0.10          # multiplicative stake slash on a confirmed safety fault
ALPHA_C, ALPHA_H, ALPHA_L = 0.6, 0.3, 0.1   # quality weights, Eq. (12)

W_MAX = 1.0           # election-weight cap, Eq. (21)
W_MIN = 1e-6          # negligible base weight epsilon
NU = 1.0              # default linear election exponent

EPOCH_LEN = 100       # VRF-based global cluster reassignment period

VALID, INVALID, MISSING, UNRESOLVED = "valid", "invalid", "missing", "unresolved"


# ---------------------------------------------------------------------------
# Canonical MF-PoP state machine
# ---------------------------------------------------------------------------


class MFPoP:
    """Canonical four-outcome MF-PoP transition system, Eqs. (8)-(19).

    The transition order follows the manuscript exactly: history update,
    base-reputation update, safety-multiplier and stake update, jail
    evaluation, eligibility update.  A jailed committer is absorbing.
    """

    __slots__ = ("r_base", "h", "phi", "v", "stake", "jailed",
                 "missed_streak", "rounds_ineligible")

    def __init__(self, r0: float = R_INITIAL, stake: float = 1.0) -> None:
        self.r_base = r0
        self.h = r0
        self.phi = 1.0
        self.v = 0
        self.stake = stake
        self.jailed = False
        self.missed_streak = 0
        self.rounds_ineligible = 0

    # -- observable quantities ------------------------------------------------

    @property
    def raw_reputation(self) -> float:
        """Eq. (17): the product of base reputation and safety multiplier."""
        return self.r_base * self.phi

    @property
    def public_reputation(self) -> float:
        """Eq. (18), first branch."""
        return R_MIN if self.jailed else max(R_MIN, self.raw_reputation)

    @property
    def eligible(self) -> bool:
        """Eq. (18), second branch."""
        return (not self.jailed) and self.raw_reputation > R_ELIG

    def election_weight(self, nu: float = NU, w_max: float = W_MAX) -> float:
        """Eq. (21): capped, jail-gated election weight."""
        if self.jailed or not self.eligible:
            return 0.0
        return min(w_max, (W_MIN + self.public_reputation) ** nu)

    # -- transition -----------------------------------------------------------

    def step(self, event: str) -> float:
        """Apply one adjudicated event; return the stake slashed this round."""
        if self.jailed:
            # Absorbing state: no further reputation or stake mutation.
            return 0.0

        slashed = 0.0

        # (1) history update, Eq. (11)
        if event == VALID:
            new_h = GAMMA * self.h + (1.0 - GAMMA)
        elif event == INVALID:
            new_h = GAMMA * self.h
        else:
            new_h = self.h

        # (2) base-reputation update, Eqs. (12)-(14)
        if event == VALID:
            quality = ALPHA_C * 1.0 + ALPHA_H * new_h + ALPHA_L * 1.0
            self.r_base = min(R_MAX, max(R_MIN,
                              (1.0 - A_H) * self.r_base + A_H * quality))
        elif event == MISSING:
            self.r_base = max(R_MIN, Q_L * self.r_base)
        self.h = new_h

        # (3) safety multiplier and stake, Eq. (15)
        if event == INVALID:
            self.phi *= Q_S
            self.v += 1
            slashed = SIGMA * self.stake
            self.stake -= slashed

        # (4) jail evaluation, Eq. (16): only on a finalised invalid event
        if event == INVALID and self.raw_reputation <= R_JAIL:
            self.jailed = True

        # (5) bookkeeping used by the churn and liveness experiments
        if event == MISSING:
            self.missed_streak += 1
        elif event == VALID:
            self.missed_streak = 0
        if not self.eligible:
            self.rounds_ineligible += 1

        return slashed


class ConvexOnlyBaseline:
    """Ablation baseline: a convex reputation update with no safety multiplier.

    This is the mechanism class that a periodic attacker can evade, and it is
    retained as the comparison arm in the adaptive-adversary study.
    """

    __slots__ = ("r", "h", "stake", "jailed")

    def __init__(self, r0: float = R_INITIAL, stake: float = 1.0) -> None:
        self.r = r0
        self.h = r0
        self.stake = stake
        self.jailed = False

    @property
    def raw_reputation(self) -> float:
        return self.r

    @property
    def public_reputation(self) -> float:
        return max(R_MIN, self.r)

    @property
    def eligible(self) -> bool:
        return self.r > R_ELIG

    def election_weight(self, nu: float = NU, w_max: float = W_MAX) -> float:
        if not self.eligible:
            return 0.0
        return min(w_max, (W_MIN + self.public_reputation) ** nu)

    def step(self, event: str) -> float:
        c = 1.0 if event == VALID else 0.0
        beta = 0.3 if event == VALID else 0.4
        self.r = (1 - 0.2 * beta) * self.r + (0.2 * beta) * (
            ALPHA_C * c + ALPHA_H * self.h + ALPHA_L)
        self.r = float(np.clip(self.r, R_MIN, R_MAX))
        self.h = GAMMA * self.h + (1 - GAMMA) * c
        return 0.0


# ---------------------------------------------------------------------------
# Calibrated audit-layer network model
# ---------------------------------------------------------------------------


@dataclass
class NetworkProfile:
    """Audit-layer link model.

    Latency and loss ranges follow the tc/netem sweep used for the measured
    coordination results (50-500 ms one-way base latency, 1-5% loss).
    ``intra_region_ms`` and ``inter_region_ms`` calibrate the two-tier RTT
    structure used by cluster formation.
    """

    intra_region_ms: float = 50.0
    inter_region_ms: float = 200.0
    global_ms: float = 500.0
    jitter_sigma: float = 0.25        # lognormal multiplicative jitter
    loss: float = 0.05                # per-message packet-loss probability
    retransmits: int = 2              # deadline permits this many retries
    deadline_ms: float = 3000.0       # per-round submission deadline
    unresolved_rate: float = 0.02     # checkpoint-adjudication failure rate

    def delivered(self, rng: np.random.Generator, base_ms: float) -> Tuple[bool, float]:
        """Return (delivered_before_deadline, observed_latency_ms)."""
        total = 0.0
        for _ in range(self.retransmits + 1):
            hop = base_ms * float(rng.lognormal(mean=0.0, sigma=self.jitter_sigma))
            total += hop
            if rng.random() >= self.loss:
                return (total <= self.deadline_ms), total
        return False, total


# ---------------------------------------------------------------------------
# Topology and cluster formation
# ---------------------------------------------------------------------------


@dataclass
class Topology:
    """Chain topology: region labels, pairwise RTT, transaction correlation."""

    k: int
    regions: np.ndarray               # (k,) integer region id per chain
    rtt: np.ndarray                   # (k,k) normalised RTT score in [0,1]
    corr: np.ndarray                  # (k,k) normalised flow correlation in [0,1]
    rtt_ms: np.ndarray                # (k,k) raw RTT in milliseconds

    def distance(self, eta: float) -> np.ndarray:
        """Eq. (20): D_ab(eta) = eta * RTT_ab + (1-eta) * (1 - rho_ab)."""
        return eta * self.rtt + (1.0 - eta) * (1.0 - self.corr)


def make_topology(k: int,
                  rng: np.random.Generator,
                  n_regions: int = 5,
                  n_communities: int = 5,
                  community_alignment: float = 0.5,
                  profile: Optional[NetworkProfile] = None) -> Topology:
    """Build a synthetic topology with partially misaligned geography and flow.

    ``community_alignment`` in [0,1] is the probability that a chain's
    transaction-flow community equals its geographic region.  At 1.0 the RTT
    and correlation objectives agree and eta is irrelevant; at 0.0 they are
    independent and eta expresses a genuine trade-off.  The default 0.5 is the
    mixed regime reported in the manuscript.
    """
    profile = profile or NetworkProfile()
    regions = rng.integers(0, n_regions, size=k)
    aligned = rng.random(k) < community_alignment
    communities = np.where(
        aligned, regions % n_communities, rng.integers(0, n_communities, size=k))

    rtt_ms = np.empty((k, k), dtype=float)
    for a in range(k):
        for b in range(k):
            if a == b:
                rtt_ms[a, b] = 0.0
            else:
                same = regions[a] == regions[b]
                base = profile.intra_region_ms if same else profile.inter_region_ms
                # A minority of inter-region links are intercontinental.
                if not same and ((a * 31 + b * 17) % 5 == 0):
                    base = profile.global_ms
                rtt_ms[a, b] = base
    rtt_ms = 0.5 * (rtt_ms + rtt_ms.T)
    jitter = rng.lognormal(mean=0.0, sigma=0.10, size=(k, k))
    jitter = 0.5 * (jitter + jitter.T)
    rtt_ms = rtt_ms * jitter
    np.fill_diagonal(rtt_ms, 0.0)

    denom = rtt_ms.max() if rtt_ms.max() > 0 else 1.0
    rtt = rtt_ms / denom

    # Flow correlation: high inside a community, low across communities.
    corr = np.where(communities[:, None] == communities[None, :], 0.85, 0.10)
    noise = rng.normal(0.0, 0.05, size=(k, k))
    noise = 0.5 * (noise + noise.T)
    corr = np.clip(corr + noise, 0.0, 1.0)
    np.fill_diagonal(corr, 1.0)

    return Topology(k=k, regions=regions, rtt=rtt, corr=corr, rtt_ms=rtt_ms)


# ---------------------------------------------------------------------------
# Trace-calibrated topology loading (TODO Item 7)
# ---------------------------------------------------------------------------

def load_topology_file(path: str) -> dict:
    """Load a topology specification from a JSON file.

    The file must contain at least:
      - ``rtt_ms``:  a k×k matrix of pairwise RTT in milliseconds.
      - ``corr``:    a k×k matrix of normalised flow correlations in [0,1].

    Optional fields:
      - ``regions``: a length-k array of integer region labels.
      - ``churn``:   a dict with keys ``offline_prob`` and ``rejoin_prob``
                     (per-round probabilities for an MMPP churn process).
    """
    import json as _json
    with open(path, "r", encoding="utf-8") as fh:
        data = _json.load(fh)
    required = {"rtt_ms", "corr"}
    missing = required - set(data.keys())
    if missing:
        raise ValueError(f"Topology file {path} is missing keys: {missing}")
    return data


def make_topology_from_file(path: str, rng: np.random.Generator,
                            profile: Optional[NetworkProfile] = None
                            ) -> Topology:
    """Build a ``Topology`` from a trace-calibrated JSON file.

    The file's ``rtt_ms`` and ``corr`` matrices define the topology.  If the
    file provides ``regions``, those are used; otherwise regions are inferred
    from hierarchical clustering on the RTT matrix.

    Parameters
    ----------
    path : str
        Path to the JSON topology file (see ``load_topology_file``).
    rng : numpy.random.Generator
        Random generator (used only if ``regions`` are not provided).
    profile : NetworkProfile, optional
        Not used by the loader; kept for API symmetry with ``make_topology``.
    """
    data = load_topology_file(path)
    rtt_ms = np.array(data["rtt_ms"], dtype=float)
    corr = np.array(data["corr"], dtype=float)
    k = rtt_ms.shape[0]
    if rtt_ms.shape != (k, k):
        raise ValueError(f"rtt_ms must be square; got shape {rtt_ms.shape}")
    if corr.shape != (k, k):
        raise ValueError(f"corr must be k×k (k={k}); got shape {corr.shape}")

    # Ensure symmetry
    rtt_ms = 0.5 * (rtt_ms + rtt_ms.T)
    corr = 0.5 * (corr + corr.T)
    np.fill_diagonal(rtt_ms, 0.0)
    np.fill_diagonal(corr, 1.0)

    # Normalised RTT
    denom = rtt_ms.max() if rtt_ms.max() > 0 else 1.0
    rtt = rtt_ms / denom

    # Regions: from file or inferred via simple threshold clustering
    if "regions" in data:
        regions = np.array(data["regions"], dtype=int)
    else:
        # Infer regions: chains with RTT below the 25th percentile are
        # co-regional.  This is a coarse heuristic; real deployments should
        # supply region labels explicitly.
        threshold = np.percentile(rtt_ms[rtt_ms > 0], 25) if (rtt_ms > 0).any() else 1.0
        regions = np.zeros(k, dtype=int)
        label = 0
        assigned = np.full(k, False)
        for a in range(k):
            if assigned[a]:
                continue
            regions[a] = label
            assigned[a] = True
            for b in range(a + 1, k):
                if not assigned[b] and rtt_ms[a, b] <= threshold:
                    regions[b] = label
                    assigned[b] = True
            label += 1

    return Topology(k=k, regions=regions, rtt=rtt, corr=corr, rtt_ms=rtt_ms)


def kmedoid_partition(dist: np.ndarray,
                      n_clusters: int,
                      rng: np.random.Generator,
                      capacity: Optional[int] = None,
                      iters: int = 30,
                      restarts: int = 8) -> np.ndarray:
    """Capacitated k-medoid assignment minimising Eq. (21)'s objective.

    The partition is the best of ``restarts`` beacon-seeded initialisations,
    scored by the objective of Eq. (21).  Selecting the best restart is what a
    deployment does at an epoch boundary, and it prevents the ablation from
    measuring local-optimum noise instead of the policy itself.  Returns a
    (k,) array of cluster labels.
    """
    best_labels, best_cost = None, float("inf")
    for _ in range(max(1, restarts)):
        labels = _kmedoid_once(dist, n_clusters, rng, capacity, iters)
        cost = _partition_cost(dist, labels, n_clusters)
        if cost < best_cost:
            best_labels, best_cost = labels, cost
    return best_labels


def _partition_cost(dist: np.ndarray, labels: np.ndarray, n_clusters: int) -> float:
    """Objective of Eq. (21): total distance to the medoid of each cluster."""
    total = 0.0
    for c in range(n_clusters):
        members = np.where(labels == c)[0]
        if members.size == 0:
            continue
        sub = dist[np.ix_(members, members)]
        total += float(sub.sum(axis=0).min())
    return total


def _kmedoid_once(dist: np.ndarray,
                  n_clusters: int,
                  rng: np.random.Generator,
                  capacity: Optional[int],
                  iters: int) -> np.ndarray:
    k = dist.shape[0]
    capacity = capacity or int(math.ceil(k / n_clusters))
    medoids = list(rng.choice(k, size=n_clusters, replace=False))
    labels = np.zeros(k, dtype=int)

    for _ in range(iters):
        # -- capacitated assignment: chains claim their nearest free medoid.
        counts = np.zeros(n_clusters, dtype=int)
        order = np.argsort(dist[:, medoids].min(axis=1))
        labels = np.full(k, -1, dtype=int)
        for a in order:
            pref = np.argsort(dist[a, medoids])
            placed = False
            for c in pref:
                if counts[c] < capacity:
                    labels[a] = c
                    counts[c] += 1
                    placed = True
                    break
            if not placed:                       # all clusters at capacity
                c = int(np.argmin(counts))
                labels[a] = c
                counts[c] += 1

        # -- medoid update
        new_medoids = []
        for c in range(n_clusters):
            members = np.where(labels == c)[0]
            if members.size == 0:
                new_medoids.append(int(rng.integers(0, k)))
                continue
            sub = dist[np.ix_(members, members)]
            new_medoids.append(int(members[int(np.argmin(sub.sum(axis=1)))]))
        if new_medoids == medoids:
            break
        medoids = new_medoids

    return labels


def random_partition(k: int, n_clusters: int, rng: np.random.Generator) -> np.ndarray:
    """Balanced random partition: the null clustering policy."""
    order = rng.permutation(k)
    labels = np.zeros(k, dtype=int)
    for i, a in enumerate(order):
        labels[a] = i % n_clusters
    return labels


def cluster_metrics(labels: np.ndarray,
                    topo: Topology,
                    b_max: int) -> Dict[str, float]:
    """Quality metrics for one partition."""
    n_clusters = int(labels.max()) + 1
    sizes = np.array([(labels == c).sum() for c in range(n_clusters)], dtype=float)

    intra_rtt: List[float] = []
    for c in range(n_clusters):
        members = np.where(labels == c)[0]
        if members.size < 2:
            continue
        sub = topo.rtt_ms[np.ix_(members, members)]
        iu = np.triu_indices(members.size, k=1)
        intra_rtt.append(float(sub[iu].mean()))

    same = labels[:, None] == labels[None, :]
    iu = np.triu_indices(topo.k, k=1)
    total_flow = float(topo.corr[iu].sum())
    cut_flow = float(topo.corr[iu][~same[iu]].sum())

    padding = float(np.mean(np.maximum(0.0, b_max - sizes) / b_max))
    gini = _gini(sizes)

    return {
        "mean_intra_rtt_ms": float(np.mean(intra_rtt)) if intra_rtt else 0.0,
        "max_intra_rtt_ms": float(np.max(intra_rtt)) if intra_rtt else 0.0,
        "tx_cut_ratio": cut_flow / total_flow if total_flow > 0 else 0.0,
        "size_gini": gini,
        "size_max": float(sizes.max()),
        "size_min": float(sizes.min()),
        "padding_ratio": padding,
    }


def _gini(x: np.ndarray) -> float:
    if x.size == 0 or x.sum() == 0:
        return 0.0
    xs = np.sort(x)
    n = xs.size
    idx = np.arange(1, n + 1)
    return float((2.0 * (idx * xs).sum()) / (n * xs.sum()) - (n + 1.0) / n)


def reassignment_churn(prev: np.ndarray, cur: np.ndarray) -> float:
    """Fraction of chains whose cluster label changed, up to relabelling.

    Cluster identifiers are arbitrary, so the two partitions are matched by a
    greedy maximum-overlap correspondence before the churn is computed.
    """
    n_prev = int(prev.max()) + 1
    n_cur = int(cur.max()) + 1
    overlap = np.zeros((n_prev, n_cur), dtype=int)
    for a in range(prev.size):
        overlap[prev[a], cur[a]] += 1
    mapping: Dict[int, int] = {}
    used = set()
    for _ in range(min(n_prev, n_cur)):
        i, j = np.unravel_index(int(np.argmax(overlap)), overlap.shape)
        if overlap[i, j] <= 0:
            break
        mapping[int(j)] = int(i)
        used.add(int(j))
        overlap[i, :] = -1
        overlap[:, j] = -1
    moved = sum(1 for a in range(prev.size)
                if mapping.get(int(cur[a]), -1) != int(prev[a]))
    return moved / float(prev.size)


# ---------------------------------------------------------------------------
# Adversary strategies
# ---------------------------------------------------------------------------


@dataclass
class Adversary:
    """Behavioural policy of a Byzantine committer.

    ``kind`` selects the strategy:

    ``naive``      submit an invalid proof every round;
    ``periodic``   submit an invalid proof once every ``period`` rounds;
    ``adaptive``   submit an invalid proof only while the resulting raw
                   reputation would stay strictly above ``R_JAIL``, that is,
                   only while the fault cannot trigger the absorbing jail;
    ``omission``   never submit an invalid proof, withhold instead;
    ``farm``       behave honestly for ``warmup`` rounds, then attack every
                   round from the highest reachable base reputation;
    ``dormant``    behave honestly until round ``warmup``, then follow the
                   adaptive policy.
    """

    kind: str = "naive"
    period: int = 6
    warmup: int = 100

    def act(self, state: MFPoP, t: int) -> str:
        if self.kind == "naive":
            return INVALID
        if self.kind == "periodic":
            return INVALID if (t % self.period == 0) else VALID
        if self.kind == "omission":
            return MISSING
        if self.kind == "farm":
            return VALID if t <= self.warmup else INVALID
        if self.kind in ("adaptive", "dormant"):
            if self.kind == "dormant" and t <= self.warmup:
                return VALID
            # A fault is safe only if the post-fault raw reputation stays
            # strictly above the jail threshold.
            projected = state.r_base * state.phi * Q_S
            return INVALID if projected > R_JAIL else VALID
        raise ValueError(f"unknown adversary kind: {self.kind}")


# ---------------------------------------------------------------------------
# Committer population and round loop
# ---------------------------------------------------------------------------


@dataclass
class Committer:
    idx: int
    chain: int
    byzantine: bool
    state: MFPoP
    adversary: Optional[Adversary] = None
    online: bool = True
    colluder: bool = False


@dataclass
class RoundStats:
    audit_accuracy: float = 0.0
    head_honest_frac: float = 0.0
    byz_weight_share: float = 0.0
    jailed_byz: int = 0
    jailed_honest: int = 0
    ineligible_honest: int = 0
    slashed: float = 0.0
    accepted_faults: int = 0
    coordination_ms: float = 0.0
    offline: int = 0
    stalled_chains: int = 0
    stalled_clusters: int = 0
    flat_stalled_chains: int = 0
    valid_events: int = 0
    honest_eligible: int = 0
    failover_attempts: int = 0
    exhausted_clusters: int = 0
    captured_clusters: int = 0
    censored_clusters: int = 0
    fresh_slots: int = 0
    round_complete: bool = True
    within_budget: bool = True
    accuracy_inbound: float = 1.0


@dataclass
class SimConfig:
    k: int = 100
    rounds: int = 200
    byz_frac: float = 0.30
    churn_rate: float = 0.0        # per-round probability a node toggles offline
    rejoin_rate: float = 0.30      # per-round probability an offline node returns
    adversary: Adversary = field(default_factory=Adversary)
    profile: NetworkProfile = field(default_factory=NetworkProfile)
    eta: float = 0.5
    b_max: int = 15
    n_regions: int = 5
    community_alignment: float = 0.5
    epoch_len: int = EPOCH_LEN
    nu: float = NU
    w_max: float = W_MAX
    collusion_size: int = 0        # colluders coordinate head capture
    head_crash_prob: float = 0.0   # cluster-head crash after election
    # Failover semantics.  A submission attempt has its own deadline
    # (NetworkProfile.deadline_ms).  A crashed head is detected when that
    # deadline expires; the cluster then re-elects and makes another attempt.
    # A cluster that exhausts ``max_attempts`` leaves its slot non-fresh, and
    # the round is not globally complete.  The whole round must finish inside
    # ``round_budget_ms``, the audit cadence.
    max_attempts: int = 3
    round_budget_ms: float = 120_000.0
    workload_dynamic: bool = False
    partition_frac: float = 0.0    # fraction of chains isolated by a partition
    partition_start: int = 0
    partition_end: int = 0
    # Captured-cluster behavior.  A cluster whose live Byzantine membership
    # reaches ceil(|C|/3) violates the per-cluster BFT condition of the threat
    # model.  When ``model_capture`` is set, such a cluster acts on that power:
    # it censors adjudication for its members and withholds its round slot.
    model_capture: bool = False
    censor_prob: float = 1.0
    # Trace-calibrated topology file (TODO Item 7).  When set, the topology
    # is loaded from this JSON file instead of being generated synthetically.
    # The synthetic path remains the default so published numbers reproduce.
    topology_file: Optional[str] = None


class HZKASimulation:
    """One seeded run of the H-ZKA audit layer."""

    def __init__(self, cfg: SimConfig, seed: int) -> None:
        self.cfg = cfg
        self.rng = np.random.default_rng(seed)
        self.seed = seed
        if cfg.topology_file:
            self.topo = make_topology_from_file(
                cfg.topology_file, self.rng, profile=cfg.profile)
            # Override k from the loaded topology if it differs
            if self.topo.k != cfg.k:
                import warnings
                warnings.warn(
                    f"Topology file has k={self.topo.k}, but SimConfig has "
                    f"k={cfg.k}. Using k={self.topo.k} from the file.")
                cfg.k = self.topo.k
        else:
            self.topo = make_topology(
                cfg.k, self.rng, n_regions=cfg.n_regions,
                community_alignment=cfg.community_alignment, profile=cfg.profile)
        self.n_clusters = int(math.ceil(math.sqrt(cfg.k)))
        self.labels = kmedoid_partition(
            self.topo.distance(cfg.eta), self.n_clusters, self.rng,
            capacity=cfg.b_max)

        n_byz = int(round(cfg.byz_frac * cfg.k))
        byz_idx = set(self.rng.choice(cfg.k, size=n_byz, replace=False).tolist())
        colluders = set()
        if cfg.collusion_size > 0:
            pool = sorted(byz_idx) or list(range(cfg.k))
            take = min(cfg.collusion_size, len(pool))
            colluders = set(self.rng.choice(pool, size=take, replace=False).tolist())

        self.committers: List[Committer] = []
        for j in range(cfg.k):
            is_byz = j in byz_idx
            self.committers.append(Committer(
                idx=j, chain=j, byzantine=is_byz, state=MFPoP(),
                adversary=cfg.adversary if is_byz else None,
                colluder=j in colluders))

        self._members = self._build_members()
        self._censoring: Dict[int, bool] = {}
        self.history: List[RoundStats] = []
        self.isolation_round: Dict[int, int] = {}
        self.head_capture_rounds = 0
        self.head_rounds = 0

    # -- helpers --------------------------------------------------------------

    def _bft_threshold(self, size: int) -> int:
        """Smallest Byzantine count that violates f_l < |C_l|/3."""
        return int(math.ceil(size / 3.0))

    def _captured_clusters(self) -> Dict[int, bool]:
        """Clusters whose live Byzantine membership breaks the BFT condition.

        A jailed committer has zero election weight and cannot vote, so it is
        not counted toward the adversarial quorum.
        """
        out: Dict[int, bool] = {}
        for c, members in self._members.items():
            if not members:
                out[c] = False
                continue
            live_byz = sum(1 for j in members
                           if self.committers[j].byzantine
                           and not self.committers[j].state.jailed)
            out[c] = live_byz >= self._bft_threshold(len(members))
        return out

    def _build_members(self) -> Dict[int, List[int]]:
        members: Dict[int, List[int]] = {c: [] for c in range(self.n_clusters)}
        for j in range(self.cfg.k):
            members[int(self.labels[j])].append(j)
        return members

    def _adjudicate(self, c: Committer) -> str:
        """Map an intended action plus network outcome to a canonical event."""
        p = self.cfg.profile
        if not c.online:
            return MISSING
        intent = c.adversary.act(c.state, len(self.history) + 1) if c.byzantine else VALID
        if intent == MISSING:
            return MISSING
        base_ms = self.topo.rtt_ms[c.chain, self._head_chain_for(c.chain)]
        delivered, _ = p.delivered(self.rng, max(base_ms, 1.0))
        if not delivered:
            return MISSING
        if self.rng.random() < p.unresolved_rate:
            return UNRESOLVED
        # A captured cluster can prevent its members' faults from being
        # adjudicated.  The evidence never reaches a finalized verdict, so the
        # canonical transition sees an unresolved event and no state moves.
        if self._censoring.get(int(self.labels[c.chain]), False):
            return UNRESOLVED
        return intent

    def _head_chain_for(self, chain: int) -> int:
        return int(self.current_heads.get(int(self.labels[chain]), chain))

    def _elect_heads(self) -> Dict[int, int]:
        heads: Dict[int, int] = {}
        for c in range(self.n_clusters):
            members = self._members[c]
            weights = np.array([
                self.committers[j].state.election_weight(self.cfg.nu, self.cfg.w_max)
                if self.committers[j].online else 0.0
                for j in members], dtype=float)
            if self.cfg.collusion_size > 0:
                # Colluders concentrate their VRF participation: they always
                # stand for election, which is the strongest permitted
                # coordination under a public, weight-proportional lottery.
                for i, j in enumerate(members):
                    if self.committers[j].colluder and weights[i] == 0.0:
                        weights[i] = 0.0
            total = weights.sum()
            if total <= 0:
                heads[c] = int(members[0]) if members else 0
                continue
            heads[c] = int(self.rng.choice(members, p=weights / total))
        return heads

    # -- main loop ------------------------------------------------------------

    def run(self) -> List[RoundStats]:
        cfg = self.cfg
        for t in range(1, cfg.rounds + 1):
            # network partition: a contiguous outage window, applied before
            # independent churn so that a partitioned node stays offline.
            if cfg.partition_frac > 0.0:
                if t == cfg.partition_start:
                    n_part = int(round(cfg.partition_frac * cfg.k))
                    self._partitioned = set(self.rng.choice(
                        cfg.k, size=n_part, replace=False).tolist())
                    for j in self._partitioned:
                        self.committers[j].online = False
                elif t == cfg.partition_end:
                    for j in getattr(self, "_partitioned", set()):
                        self.committers[j].online = True
                    self._partitioned = set()

            # churn
            if cfg.churn_rate > 0.0:
                partitioned = getattr(self, "_partitioned", set())
                for c in self.committers:
                    if c.idx in partitioned:
                        continue
                    if c.online and self.rng.random() < cfg.churn_rate:
                        c.online = False
                    elif (not c.online) and self.rng.random() < cfg.rejoin_rate:
                        c.online = True

            # epoch reassignment
            if cfg.epoch_len and t % cfg.epoch_len == 0:
                self.labels = kmedoid_partition(
                    self.topo.distance(cfg.eta), self.n_clusters, self.rng,
                    capacity=cfg.b_max)
                self._members = self._build_members()

            # Captured-cluster determination precedes election and
            # adjudication, so a captured cluster can act within this round.
            captured = self._captured_clusters() if cfg.model_capture else {}
            self._censoring = {c: (v and self.rng.random() < cfg.censor_prob)
                               for c, v in captured.items()}

            self.current_heads = self._elect_heads()

            stats = RoundStats()
            stats.captured_clusters = sum(1 for v in captured.values() if v)
            stats.censored_clusters = sum(1 for v in self._censoring.values() if v)
            # head honesty and capture accounting
            honest_heads = 0
            for c, h in self.current_heads.items():
                self.head_rounds += 1
                comm = self.committers[h]
                head_is_byz = comm.byzantine and not comm.state.jailed
                if not head_is_byz:
                    honest_heads += 1
                else:
                    self.head_capture_rounds += 1
            stats.head_honest_frac = honest_heads / max(1, len(self.current_heads))

            # cluster-head crash and re-election within the round
            coordination_ms = self._round_coordination_ms()
            if cfg.head_crash_prob > 0.0:
                # The identical i.i.d. crash process is applied to the flat
                # baseline, where each chain's own committer fails
                # independently, so the two arms differ only in blast radius.
                stats.flat_stalled_chains = int(
                    (self.rng.random(cfg.k) < cfg.head_crash_prob).sum())
                extra_ms = 0.0
                for c in list(self.current_heads):
                    attempts = 0
                    while attempts < cfg.max_attempts:
                        if self.rng.random() >= cfg.head_crash_prob:
                            break                       # this attempt succeeds
                        attempts += 1
                        extra_ms += cfg.profile.deadline_ms   # detection delay
                        members = [j for j in self._members[c]
                                   if j != self.current_heads[c]]
                        if not members:
                            break
                        w = np.array([
                            self.committers[j].state.election_weight(
                                cfg.nu, cfg.w_max) for j in members])
                        self.current_heads[c] = (
                            int(self.rng.choice(members, p=w / w.sum()))
                            if w.sum() > 0 else int(members[0]))
                    if attempts:
                        stats.stalled_clusters += 1
                        stats.stalled_chains += len(self._members[c])
                    stats.failover_attempts += attempts
                    if attempts >= cfg.max_attempts:
                        stats.exhausted_clusters += 1
                # Attempts within a cluster are sequential; clusters proceed in
                # parallel, so the round pays the worst cluster's delay.
                coordination_ms += extra_ms / max(1, self.n_clusters)
            stats.coordination_ms = coordination_ms

            # adjudicate every committer and apply the canonical transition
            self._valid_events = 0
            for c in self.committers:
                before_jailed = c.state.jailed
                event = self._adjudicate(c)
                if event == VALID:
                    self._valid_events += 1
                if event == INVALID and not before_jailed:
                    stats.accepted_faults += 1
                stats.slashed += c.state.step(event)
                if c.state.jailed and not before_jailed:
                    self.isolation_round.setdefault(c.idx, t)

            # per-round observables
            active_byz = sum(1 for c in self.committers
                             if c.byzantine and not c.state.jailed and c.state.eligible)
            stats.audit_accuracy = 1.0 - active_byz / float(cfg.k)
            weights = np.array([c.state.election_weight(cfg.nu, cfg.w_max)
                                for c in self.committers])
            byz_w = np.array([c.state.election_weight(cfg.nu, cfg.w_max)
                              if c.byzantine else 0.0 for c in self.committers])
            stats.byz_weight_share = float(byz_w.sum() / weights.sum()) if weights.sum() > 0 else 0.0
            stats.jailed_byz = sum(1 for c in self.committers
                                   if c.byzantine and c.state.jailed)
            stats.jailed_honest = sum(1 for c in self.committers
                                      if (not c.byzantine) and c.state.jailed)
            stats.ineligible_honest = sum(1 for c in self.committers
                                          if (not c.byzantine) and not c.state.eligible)
            stats.offline = sum(1 for c in self.committers if not c.online)
            # A censored cluster withholds its slot, so the slot is not fresh
            # and the round is not globally complete (Section 5.6).
            stats.fresh_slots = self.n_clusters - stats.censored_clusters
            stats.within_budget = coordination_ms <= cfg.round_budget_ms
            stats.round_complete = (stats.censored_clusters == 0
                                    and stats.exhausted_clusters == 0
                                    and stats.within_budget)
            # Accuracy restricted to clusters that satisfy the BFT condition.
            inbound = [c for c in range(self.n_clusters)
                       if not captured.get(c, False)]
            if inbound:
                inbound_chains = [j for c in inbound for j in self._members[c]]
                bad = sum(1 for j in inbound_chains
                          if self.committers[j].byzantine
                          and not self.committers[j].state.jailed
                          and self.committers[j].state.eligible)
                stats.accuracy_inbound = 1.0 - bad / max(1, len(inbound_chains))
            stats.valid_events = self._valid_events
            stats.honest_eligible = sum(
                1 for c in self.committers if (not c.byzantine) and c.state.eligible)
            self.history.append(stats)
        return self.history

    def _round_coordination_ms(self) -> float:
        """Two-phase coordination latency: intra-cluster then global."""
        per_cluster = []
        for c in range(self.n_clusters):
            members = self._members[c]
            if not members:
                continue
            head = self.current_heads.get(c, members[0])
            hops = [self.topo.rtt_ms[j, head] for j in members if j != head]
            per_cluster.append(max(hops) if hops else 0.0)
        intra = max(per_cluster) if per_cluster else 0.0
        heads = list(self.current_heads.values())
        global_hop = (max(self.topo.rtt_ms[h, heads[0]] for h in heads)
                      if len(heads) > 1 else 0.0)
        return float(intra + global_hop)


def flat_coordination_ms(topo: Topology) -> float:
    """Baseline: every chain contacts the global audit chain directly."""
    anchor = 0
    return float(sum(topo.rtt_ms[j, anchor] for j in range(topo.k)) / 1.0)


__all__ = [
    "MFPoP", "ConvexOnlyBaseline", "Adversary", "Committer",
    "NetworkProfile", "Topology", "make_topology", "make_topology_from_file",
    "load_topology_file", "kmedoid_partition",
    "random_partition", "cluster_metrics", "reassignment_churn",
    "SimConfig", "HZKASimulation", "RoundStats", "flat_coordination_ms",
    "VALID", "INVALID", "MISSING", "UNRESOLVED",
    "R_MIN", "R_JAIL", "R_ELIG", "Q_S", "Q_L", "SIGMA", "A_H", "GAMMA",
]
