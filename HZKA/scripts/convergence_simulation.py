#!/usr/bin/env python3
import os
import json
import numpy as np
import pandas as pd
import matplotlib.pyplot as plt

# Configuration
R_MIN, R_MAX, R_JAIL = 0.01, 1.0, 0.015
A_H, GAMMA = 0.016, 0.70
Q_L, Q_S = 0.95, 0.50
R_INITIAL = 0.5

class MFPoPMachine:
    def __init__(self):
        self.r_base, self.h, self.phi, self.j = R_INITIAL, R_INITIAL, 1.0, False

    def get_effective_r(self):
        if self.j: return R_MIN
        return max(R_MIN, self.r_base * self.phi)

    def transition(self, event: str):
        if self.j: return 
        if event == "valid":
            new_h = GAMMA * self.h + (1 - GAMMA)
            q = 0.7 + 0.3 * new_h
            self.r_base = (1 - A_H) * self.r_base + A_H * q
        elif event == "invalid":
            new_h = GAMMA * self.h
            self.phi *= Q_S
        else:
            new_h = self.h
            self.r_base = Q_L * self.r_base
            
        self.r_base = min(R_MAX, max(R_MIN, self.r_base))
        self.h = new_h
        
        if event == "invalid" and self.get_effective_r() <= R_JAIL:
            self.j = True

def main():
    os.makedirs('results', exist_ok=True)
    N_SEEDS, N_ROUNDS, PACKET_LOSS, BASE_SEED = 30, 100, 0.05, 42
    
    hon_hist = np.zeros((N_SEEDS, N_ROUNDS))
    atk_hist = np.zeros((N_SEEDS, N_ROUNDS))
    raw_records = []

    for i in range(N_SEEDS):
        seed = BASE_SEED + i
        np.random.seed(seed)
        hon_node, atk_node = MFPoPMachine(), MFPoPMachine()
        
        for t in range(1, N_ROUNDS + 1):
            hon_event = "missing" if np.random.rand() < PACKET_LOSS else "valid"
            atk_event = "missing" if np.random.rand() < PACKET_LOSS else "invalid"
            
            hon_node.transition(hon_event)
            atk_node.transition(atk_event)
            
            hon_hist[i, t-1] = hon_node.get_effective_r()
            atk_hist[i, t-1] = atk_node.get_effective_r()
            
            raw_records.append({"seed": seed, "round": t, 
                                "honest_r_eff": round(hon_hist[i, t-1], 6), 
                                "attacker_r_eff": round(atk_hist[i, t-1], 6)})

    df = pd.DataFrame(raw_records)
    df.to_csv('results/raw_convergence.csv', index=False)
    with open('results/raw_convergence.json', 'w') as f:
        json.dump(raw_records, f, indent=2)

    rounds = np.arange(1, N_ROUNDS + 1)
    hon_mean = np.mean(hon_hist, axis=0)
    hon_ci = 1.96 * np.std(hon_hist, axis=0) / np.sqrt(N_SEEDS)
    atk_mean = np.mean(atk_hist, axis=0)
    atk_ci = 1.96 * np.std(atk_hist, axis=0) / np.sqrt(N_SEEDS)

    iso_rounds = [np.where(atk_hist[i, :] <= R_MIN)[0][0] + 1 for i in range(N_SEEDS) if len(np.where(atk_hist[i, :] <= R_MIN)[0]) > 0]
    mean_iso = np.mean(iso_rounds)

    fig, ax = plt.subplots(figsize=(10, 6))

    ax.plot(rounds, hon_mean, color="#4c72b0", lw=2.5, label="Honest committer")
    ax.fill_between(rounds, hon_mean - hon_ci, hon_mean + hon_ci, color="#4c72b0", alpha=0.15)

    ax.plot(rounds, atk_mean, color="#c44e52", lw=2.5, ls="--", label="Byzantine committer")
    ax.fill_between(rounds, atk_mean - atk_ci, atk_mean + atk_ci, color="#c44e52", alpha=0.15)

    ax.axhline(R_MIN, color="gray", ls=":", lw=1.5, label=f"$R_{{\\min}} = {R_MIN}$")
    ax.axvline(mean_iso, color="#e8a39c", ls="--", lw=1.5, label=f"Mean isolation (round {mean_iso:.1f})")

    ax.set_xlabel("Round $t$", fontsize=16)
    ax.set_ylabel("Effective Reputation $R_{i,\\mathrm{eff}}^t$", fontsize=16)
    ax.legend(loc="center right", fontsize=14, framealpha=1.0)
    ax.grid(True, alpha=0.3)
    ax.set_xlim(0, 100); ax.set_ylim(0.0, 1.05)
    
    plt.tight_layout()
    plt.savefig('results/convergence.pdf')
    plt.savefig('results/convergence.png', dpi=300)
    print("✅ Sinh thành công: convergence.pdf")

if __name__ == "__main__":
    main()