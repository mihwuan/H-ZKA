#!/usr/bin/env python3
import os
import matplotlib.pyplot as plt
import numpy as np

# Canonical Configuration
R_MIN, R_MAX, R_JAIL = 0.01, 1.0, 0.015
A_H, GAMMA = 0.016, 0.70
Q_S = 0.50

class CanonicalMachine:
    def __init__(self, is_attacker=False):
        self.is_attacker = is_attacker
        self.r_base = 0.5
        self.h = 0.5
        self.phi = 1.0
        self.j = False

    def get_effective_r(self):
        if self.j: return R_MIN
        return max(R_MIN, self.r_base * self.phi)

    def transition(self, event: str):
        if self.j: return
        
        if event == "valid":
            self.r_base = min(R_MAX, (1 - A_H) * self.r_base + A_H * 1.0)
            if self.r_base > 0.5: self.r_base -= (self.r_base - 0.5) / 100
        elif event == "invalid":
            self.phi *= Q_S
            
        if self.get_effective_r() <= R_JAIL:
            self.j = True

class OldBaselineMachine:
    def __init__(self, is_attacker=False):
        self.is_attacker = is_attacker
        self.r = 0.5
        self.h = 0.5

    def get_effective_r(self): return self.r

    def transition(self, event: str):
        C = 1.0 if event == "valid" else 0.0
        Q = 0.6 * C + 0.3 * self.h + 0.1 * 1.0
        beta = 0.3 if event == "valid" else 0.4
        self.r = max(R_MIN, min(R_MAX, (1 - 0.2*beta) * self.r + (0.2*beta) * Q))
        self.h = GAMMA * self.h + (1 - GAMMA) * C

def run_slow_loris(n_rounds, osc_n=5):
    nodes_can = [CanonicalMachine() for _ in range(20)] + [CanonicalMachine(is_attacker=True)]
    nodes_old = [OldBaselineMachine() for _ in range(20)] + [OldBaselineMachine(is_attacker=True)]
    
    rounds, atk_r_can, hon_r_can, atk_r_old = [], [], [], []
    jail_round = None

    for t in range(1, n_rounds + 1):
        event = "invalid" if t % osc_n == 0 else "valid"
        
        for n in nodes_can: n.transition(event if n.is_attacker else "valid")
        for n in nodes_old: n.transition(event if n.is_attacker else "valid")
            
        atk_r_can.append(nodes_can[-1].get_effective_r())
        atk_r_old.append(nodes_old[-1].get_effective_r())
        hon_r_can.append(np.mean([n.get_effective_r() for n in nodes_can[:-1]]))
        rounds.append(t)
        
        if nodes_can[-1].j and jail_round is None:
            jail_round = t

    return rounds, hon_r_can, atk_r_can, atk_r_old, jail_round

def plot_figure3b(rounds, hon_r_can, atk_r_can, atk_r_old, jail_round):
    os.makedirs('results', exist_ok=True)
    fig, ax = plt.subplots(figsize=(10, 6))

    ax.plot(rounds, hon_r_can, color="#2ca02c", lw=2.2, label="Honest committer")
    ax.plot(rounds, atk_r_can, color="#d62728", lw=2.0, ls="--", label="Attacker (Canonical Machine, Eq. 16)")
    ax.plot(rounds, atk_r_old, color="#ff7f0e", lw=2.0, ls="-.", label="Attacker (Old Baseline)")

    ax.axhline(R_MIN, color="black", ls=":", lw=1.2, label=f"$R_{{\\min}} = {R_MIN}$")
    ax.axhline(R_JAIL, color="gray", ls=":", lw=1.0, label="Trust Jail")

    if jail_round:
        ax.axvline(jail_round, color="#d62728", ls="--", lw=1.0, alpha=0.6)
        ax.annotate(f"Trust Jail Activated\nRound {jail_round}",
                    xy=(jail_round, R_JAIL), xytext=(jail_round + 5, R_JAIL + 0.1),
                    color="#d62728", arrowprops=dict(arrowstyle="->", color="#d62728"))

    ax.set_xlabel("Round $t$", fontsize=13)
    ax.set_ylabel("Effective Reputation", fontsize=13)
    ax.set_title("Figure 3b: Slow-Loris Attack Defeated via Geometric Safety Slash", fontsize=14, fontweight="bold")
    ax.legend()
    ax.grid(True, alpha=0.3)
    ax.set_xlim(0, max(rounds) + 2)
    ax.set_ylim(0.0, 1.05)
    
    plt.tight_layout()
    plt.savefig('results/fig3b_slowloris_patch.png', dpi=300)
    plt.close()

if __name__ == "__main__":
    rounds, hon, atk_can, atk_old, jail = run_slow_loris(200, osc_n=5)
    print("Slow-Loris N=5 Simulation Complete!")
    print(f"Jail activated at round: {jail}")
    print(f"Final Attacker R (Canonical) : {atk_can[-1]:.4f}")
    plot_figure3b(rounds, hon, atk_can, atk_old, jail)
    print("Saved to results/fig3b_slowloris_patch.png")