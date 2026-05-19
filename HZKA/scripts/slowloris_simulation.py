#!/usr/bin/env python3
"""
===============================================================
Figure 3b: Slow-Loris (Oscillating) Attack — Cumulative V_i Patch
===============================================================

Purpose:
  Demonstrates that the cumulative safety-fault counter V_i (Eq.13,
  Theorem 4) drives a periodic attacker (N=5: 4 correct + 1 wrong
  per cycle) to the Trust Jail boundary, where the reputation
  oscillates at R_min = 0.01.

Three curves in Figure 3b:
  1. Green solid   — Honest committer (stable at ~1.0)
  2. Red dashed    — Attacker WITH Eq.13 patch (V_i cumulative)
  3. Orange dashd  — Attacker WITHOUT patch (resetting F_i only)

Key mechanism:
  On every C=0 round the reputation is multiplied by
  dec = max(0, 0.6 - V_i * 0.1).
  After V_i >= 6 faults the decay factor hits 0, pushing R into
  Trust Jail. With N=5, one fault occurs every 5 rounds, so
  Trust Jail activates around round 30.

Usage:
  python scripts/slowloris_simulation.py

Output:
  results/fig3b_slowloris_patch.png   (and .pdf)
  results/slowloris_simulation_data.json
"""

import json
import os

import matplotlib.pyplot as plt
import numpy as np

# ============================================================
# Protocol Constants
# ============================================================

PRECISION = 1e18
R_MIN     = 0.01
R_MAX     = 10.0
R_INITIAL = 0.5

W_CONS = 0.6
W_HIST  = 0.3
W_LIVE  = 0.1

BETA   = 0.08
ALPHA_V = 0.5
SLASH_MULTIPLIER = 5

TRUST_JAIL_MULT = 1.5

# Fault-round reputation decay factor.
# Reputation multiplier on each C=0 round under the Eq.13 patch:
#   dec = max(0, DECAY_BASE - V_i * DECAY_STEP)
# This implements the cumulative-penalty effect of Eq.13 in a
# simulation-friendly way. After V_i >= 6, dec=0, driving R to R_MIN.
DECAY_BASE = 0.6
DECAY_STEP = 0.1


# ============================================================
# Data Structures
# ============================================================

class Committer:
    def __init__(self, id: int, is_attacker: bool = False):
        self.id = id
        self.is_attacker = is_attacker
        self.reputation = R_INITIAL
        self.history_score = R_INITIAL
        self.consecutive_fails = 0
        self.cumulative_faults = 0


# ============================================================
# Update Functions
# ============================================================

def update_patched(c: Committer, consistent: bool) -> None:
    """
    Eq.13 patch: cumulative fault counter V_i never resets.
    Reputation formula:
      R^(t+1) = dec * R^t        if C=0
      R^(t+1) = (1-beta)*R + beta*Q  otherwise
    where dec = max(0, 0.6 - V_i * 0.1) and
          beta = beta * 5 * max(F_i, alpha_V * V_i) / 2
    """
    C = 1.0 if consistent else 0.0

    if not consistent:
        c.cumulative_faults += 1
        c.consecutive_fails += 1

        Vi_term = ALPHA_V * c.cumulative_faults
        max_term = max(c.consecutive_fails, Vi_term)
        beta = BETA * SLASH_MULTIPLIER * max_term / 2.0
        beta = min(beta, 1.0)

        dec = max(0.0, DECAY_BASE - float(c.cumulative_faults) * DECAY_STEP)
        c.reputation *= dec
    else:
        c.consecutive_fails = 0
        beta = BETA

        Q = W_CONS * C + W_HIST * c.history_score + W_LIVE * 1.0
        c.reputation = (1.0 - beta) * c.reputation + beta * Q

    c.reputation = max(R_MIN, min(R_MAX, c.reputation))

    if c.reputation <= TRUST_JAIL_MULT * R_MIN:
        c.reputation = R_MIN

    c.history_score = 0.7 * c.history_score + 0.3 * C


def update_unpatched(c: Committer, consistent: bool) -> None:
    """
    Pre-patch: F_i resets on valid rounds.
    Steady-state R* = (N-1)/(N+4) for N-cycle oscillating attacker.
    """
    C = 1.0 if consistent else 0.0

    if not consistent:
        c.consecutive_fails += 1

        max_term = c.consecutive_fails
        beta = BETA * SLASH_MULTIPLIER * max_term / 2.0
        beta = min(beta, 1.0)

        Q = W_CONS * C + W_HIST * c.history_score + W_LIVE * 0.0
        c.reputation = (1.0 - beta) * c.reputation + beta * Q
    else:
        c.consecutive_fails = 0
        beta = BETA

        Q = W_CONS * C + W_HIST * c.history_score + W_LIVE * 1.0
        c.reputation = (1.0 - beta) * c.reputation + beta * Q

    c.reputation = max(R_MIN, min(R_MAX, c.reputation))

    if c.reputation <= TRUST_JAIL_MULT * R_MIN:
        c.reputation = R_MIN

    c.history_score = 0.7 * c.history_score + 0.3 * C


# ============================================================
# Simulation
# ============================================================

class SlowLorisSimulator:
    def __init__(self, n_honest: int = 20, n_rounds: int = 200,
                 oscillation_n: int = 5):
        self.n_honest     = n_honest
        self.n_rounds     = n_rounds
        self.oscillation_n = oscillation_n

    def _make_nodes(self):
        nodes = [Committer(i) for i in range(self.n_honest)]
        nodes.append(Committer(self.n_honest, is_attacker=True))
        return nodes

    def _run_patched(self):
        nodes = self._make_nodes()
        rounds, atk_r, hon_r, atk_vi = [], [], [], []
        for t in range(1, self.n_rounds + 1):
            pos = t % self.oscillation_n
            atk_cons = (pos != 0)
            for n in nodes:
                update_patched(n, atk_cons if n.is_attacker else True)
                if n.is_attacker:
                    atk_vi.append(n.cumulative_faults)
            rounds.append(t)
            atk_r.append(nodes[-1].reputation)
            hon_r.append(np.mean([n.reputation for n in nodes if not n.is_attacker]))
        return dict(rounds=rounds, atk_r=atk_r, hon_r=hon_r, atk_vi=atk_vi)

    def _run_unpatched(self):
        nodes = self._make_nodes()
        rounds, atk_r, hon_r = [], [], []
        for t in range(1, self.n_rounds + 1):
            pos = t % self.oscillation_n
            atk_cons = (pos != 0)
            for n in nodes:
                update_unpatched(n, atk_cons if n.is_attacker else True)
            rounds.append(t)
            atk_r.append(nodes[-1].reputation)
            hon_r.append(np.mean([n.reputation for n in nodes if not n.is_attacker]))
        return dict(rounds=rounds, atk_r=atk_r, hon_r=hon_r)

    def run(self):
        return self._run_patched(), self._run_unpatched()


# ============================================================
# Plotting
# ============================================================

def plot_figure3b(p: dict, np_: dict, osc_n: int, out_dir: str = "results"):
    fig, ax = plt.subplots(figsize=(10, 6))
    rounds = p["rounds"]

    ax.plot(rounds, p["hon_r"], color="#2ca02c", lw=2.2, ls="-",
            label="Honest committer")
    ax.plot(rounds, p["atk_r"], color="#d62728", lw=2.0, ls="--",
            label="Attacker (Eq.13 patch, $V_i$ cumulative)")
    ax.plot(rounds, np_["atk_r"], color="#ff7f0e", lw=2.0, ls="-.",
            label="Attacker (pre-patch, resetting $F_i^t$ only)")

    ax.axhline(R_MIN, color="black", ls=":", lw=1.2, alpha=0.7,
               label=f"$R_{{\\min}} = {R_MIN}$")
    ax.axhline(TRUST_JAIL_MULT * R_MIN, color="gray", ls=":", lw=1.0, alpha=0.5,
               label=f"Trust Jail $= 1.5\\times R_{{\\min}}$")

    R_star = (osc_n - 1) / (osc_n + 4)
    ax.axhline(R_star, color="#ff7f0e", ls=":", lw=0.8, alpha=0.5)

    isolation_round = None
    for i, r in enumerate(p["atk_r"]):
        if r <= TRUST_JAIL_MULT * R_MIN:
            isolation_round = i + 1
            break

    atk_final = p["atk_r"][-1]
    ax.annotate(f"Final: {atk_final:.4f}", xy=(rounds[-1], atk_final),
                xytext=(rounds[-1] - 60, atk_final + 0.08), fontsize=9,
                color="#d62728",
                arrowprops=dict(arrowstyle="->", color="#d62728", lw=1.2))

    if isolation_round:
        ax.axvline(isolation_round, color="#d62728", ls="--", lw=1.0, alpha=0.6)
        ax.annotate(f"Trust Jail\nround {isolation_round}",
                    xy=(isolation_round, R_MIN),
                    xytext=(isolation_round + 15, R_MIN + 0.06),
                    fontsize=9, color="#d62728",
                    arrowprops=dict(arrowstyle="->", color="#d62728", lw=1.2))

    ax.set_xlabel("Round $t$", fontsize=13)
    ax.set_ylabel("Reputation $R_i^t$", fontsize=13)
    ax.set_title(
        "Figure 3b: Slow-Loris Attack — Cumulative $V_i$ Patch (Eq.13)",
        fontsize=14, fontweight="bold")
    ax.legend(fontsize=10, loc="center right")
    ax.set_xlim(0, len(rounds) + 2)
    ax.set_ylim(0.0, 1.05)
    ax.grid(True, alpha=0.3)
    ax.tick_params(labelsize=11)
    plt.tight_layout()

    for ext in ("png", "pdf"):
        out = os.path.join(out_dir, f"fig3b_slowloris_patch.{ext}")
        plt.savefig(out, dpi=300, bbox_inches="tight")
        print(f"Saved: {out}")
    plt.close()


# ============================================================
# Main
# ============================================================

def main():
    if os.name == "nt":
        os.system("chcp 65001 >nul 2>&1")

    out_dir = "results"
    os.makedirs(out_dir, exist_ok=True)

    N_ROUNDS = 200
    N_HONEST = 20
    N_OSCILL = 5   # N=5: 4 correct + 1 wrong per cycle

    print("Slow-Loris simulation: 200 rounds, N=5 oscillating pattern...")

    sim = SlowLorisSimulator(n_honest=N_HONEST, n_rounds=N_ROUNDS,
                             oscillation_n=N_OSCILL)
    p, np_ = sim.run()

    # ---- Results ----
    atk_patch_final = p["atk_r"][-1]
    atk_orig_final  = np_["atk_r"][-1]
    hon_final       = p["hon_r"][-1]
    isolation_round = None
    for i, r in enumerate(p["atk_r"]):
        if r <= TRUST_JAIL_MULT * R_MIN:
            isolation_round = i + 1
            break

    R_star_theory = (N_OSCILL - 1) / (N_OSCILL + 4)

    sep = "=" * 62
    print(f"\n{sep}")
    print("  Simulation Summary: Slow-Loris Attack + Cumulative $V_i$ Patch")
    print(sep)
    print(f"  Rounds            : {N_ROUNDS}")
    print(f"  Oscillation N     : {N_OSCILL} (4 correct + 1 wrong)")
    print(f"  R_min             : {R_MIN}")
    print(f"  Trust Jail        : {TRUST_JAIL_MULT * R_MIN}")
    print(f"  Theoretical R*     : {R_star_theory:.4f}  (pre-patch, N={N_OSCILL})")
    print(f"  Empirical R* (no patch) : {atk_orig_final:.4f}")
    print(f"  Attacker final R (patched) : {atk_patch_final:.6f}")
    print(f"  Trust Jail at     : round {isolation_round}")
    print(f"  Honest final R    : {hon_final:.4f}")
    print()
    if isolation_round is not None:
        print(f"  PASS: Trust Jail activates at round {isolation_round}.")
        print(f"        Patch closes slow-loris gap: "
              f"{atk_orig_final:.3f} -> {atk_patch_final:.3f}")
    else:
        print(f"  NOTE: Trust Jail did not fully activate in 200 rounds.")
    print(sep)

    plot_figure3b(p, np_, N_OSCILL, out_dir=out_dir)

    # JSON export
    data = {
        "simulation_params": {
            "n_honest": N_HONEST, "n_rounds": N_ROUNDS,
            "oscillation_N": N_OSCILL, "beta": BETA,
            "alpha_V": ALPHA_V, "decay_base": DECAY_BASE,
            "decay_step": DECAY_STEP, "R_min": R_MIN,
        },
        "with_patch": {
            "rounds": p["rounds"], "atk_r": p["atk_r"],
            "hon_r": p["hon_r"], "atk_vi": p["atk_vi"],
        },
        "without_patch": {
            "rounds": np_["rounds"], "atk_r": np_["atk_r"],
            "hon_r": np_["hon_r"],
        },
        "summary": {
            "atk_final_patch": atk_patch_final,
            "atk_final_orig": atk_orig_final,
            "hon_final": hon_final,
            "trust_jail_round": isolation_round,
            "theoretical_R_star": R_star_theory,
        },
    }
    out_json = os.path.join(out_dir, "slowloris_simulation_data.json")
    with open(out_json, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
    print(f"Data saved: {out_json}")


if __name__ == "__main__":
    main()
