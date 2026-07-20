#!/usr/bin/env python3
import json
import os
import random
import matplotlib.pyplot as plt
import numpy as np

# Canonical MF-PoP Constants
R_MIN, R_MAX, R_JAIL = 0.01, 1.0, 0.015
R_INITIAL = 0.5

# Convex & Geometric update factors
A_H = 0.016
GAMMA = 0.70
Q_L = 0.95
Q_S = 0.50
SIGMA = 0.10

class CanonicalStateMachine:
    def __init__(self, is_attacker=False):
        self.is_attacker = is_attacker
        self.r_base = R_INITIAL
        self.h = R_INITIAL
        self.phi = 1.0
        self.v = 0
        self.s = 1.0
        self.j = False

    def get_effective_r(self):
        if self.j: return R_MIN
        return max(R_MIN, self.r_base * self.phi)

    def transition(self, event: str) -> float:
        """Returns slashed stake amount."""
        if self.j: return 0.0 # Absorbing state
        
        slashed = 0.0
        
        # 1. History
        if event == "valid":
            self.h = GAMMA * self.h + (1 - GAMMA)
        elif event == "invalid":
            self.h = GAMMA * self.h

        # 2. Base Reputation & Tax
        if event == "valid":
            self.r_base = (1 - A_H) * self.r_base + A_H * 1.0
            if self.r_base > 0.5:
                self.r_base -= (self.r_base - 0.5) / 100
            self.r_base = min(self.r_base, R_MAX)
        elif event == "missing":
            self.r_base = Q_L * self.r_base
            
        # 3. Safety Transition
        if event == "invalid":
            self.phi = Q_S * self.phi
            self.v += 1
            slashed = SIGMA * self.s
            self.s -= slashed
            
        # 4. Trust Jail Trigger
        if self.get_effective_r() <= R_JAIL:
            self.j = True
            
        return slashed

class OldBaselineStateMachine:
    """The original vulnerable algorithm (without safety multiplier)"""
    def __init__(self, is_attacker=False):
        self.is_attacker = is_attacker
        self.r = R_INITIAL
        self.h = R_INITIAL

    def transition(self, event: str):
        C = 1.0 if event == "valid" else 0.0
        Q = 0.6 * C + 0.3 * self.h + 0.1 * 1.0 # Baseline included 0.1 liveness floor
        
        beta = 0.3 if event == "valid" else 0.4
        self.r = (1 - 0.2*beta) * self.r + (0.2*beta) * Q
        
        if self.r > 0.5:
            self.r -= (self.r - 0.5) / 100
        self.r = max(R_MIN, min(R_MAX, self.r))
        self.h = GAMMA * self.h + (1 - GAMMA) * C
        return 0.0
    
    def get_effective_r(self):
        return self.r

def run_simulation(n_rounds, attacker_cycle_N=6, use_canonical=True):
    nodes = [CanonicalStateMachine() if use_canonical else OldBaselineStateMachine() for _ in range(10)]
    nodes.append(CanonicalStateMachine(is_attacker=True) if use_canonical else OldBaselineStateMachine(is_attacker=True))
    
    history = {'rounds': [], 'hon_r': [], 'atk_r': [], 'atk_w': [], 'acc': [], 'slashed': []}
    total_slashed = 0.0

    for t in range(1, n_rounds + 1):
        for n in nodes:
            event = "valid"
            if n.is_attacker and (t % attacker_cycle_N == 0):
                event = "invalid"
            
            slashed = n.transition(event)
            total_slashed += slashed
            
        hon_r = np.mean([n.get_effective_r() for n in nodes if not n.is_attacker])
        atk_r = nodes[-1].get_effective_r()
        
        total_rep = sum(n.get_effective_r() for n in nodes)
        atk_w = atk_r / total_rep if atk_r > R_MIN * 1.01 else 0.0
        
        contamination = min(1.0, atk_w ** 1.5)
        acc = 1.0 - contamination
        
        history['rounds'].append(t)
        history['hon_r'].append(hon_r)
        history['atk_r'].append(atk_r)
        history['atk_w'].append(atk_w)
        history['acc'].append(acc)
        history['slashed'].append(total_slashed)
        
    return history

def plot_reputation_recovery(h_new, h_old, out_path='results/mfpop_reputation_recovery.png'):
    os.makedirs('results', exist_ok=True)
    fig, axes = plt.subplots(3, 1, figsize=(14, 12))
    
    # 1. Reputation
    ax1 = axes[0]
    ax1.plot(h_new['rounds'], h_new['hon_r'], label='Honest Committer', color='#2ca02c', lw=2.2)
    ax1.plot(h_new['rounds'], h_new['atk_r'], label='Attacker (Canonical Machine)', color='#d62728', lw=2.0, ls='--')
    ax1.plot(h_new['rounds'], h_old['atk_r'], label='Attacker (Old Baseline)', color='#ff7f0e', lw=2.0, ls=':')
    ax1.axhline(R_JAIL, color='gray', ls=':', label='Trust Jail Threshold', alpha=0.5)
    ax1.set_ylabel('Effective Reputation')
    ax1.set_title('Reputation Trajectory: Oscillating Attack (5 Valid, 1 Invalid)')
    ax1.legend()
    ax1.grid(True, alpha=0.3)
    ax1.set_xlim(0, 200)

    # 2. Weight
    ax2 = axes[1]
    ax2.plot(h_new['rounds'], h_new['atk_w'], label='Attacker Voting Weight', color='#8b0000', lw=2.0)
    ax2.set_ylabel('Voting Weight')
    ax2.set_title('Attacker Voting Power Over Time')
    ax2.legend()
    ax2.grid(True, alpha=0.3)
    ax2.set_xlim(0, 200)

    # 3. Accuracy
    ax3 = axes[2]
    r_50 = [r for r in h_new['rounds'] if r <= 50]
    ax3.plot(r_50, h_new['acc'][:50], label='With Canonical MF-PoP', color='#1f77b4', marker='o', markersize=4)
    ax3.plot(r_50, h_old['acc'][:50], label='Old Baseline', color='#d62728', marker='x', markersize=4)
    ax3.axhline(1.0, color='green', ls='--', alpha=0.5)
    ax3.set_xlabel('Round $t$')
    ax3.set_ylabel('System Accuracy')
    ax3.set_title('Accuracy Recovery (Rounds 1-50)')
    ax3.legend()
    ax3.grid(True, alpha=0.3)
    ax3.set_xlim(1, 50)

    plt.tight_layout()
    plt.savefig(out_path, dpi=300)
    plt.close()

def plot_stake_slashing(h_new, out_path='results/mfpop_stake_slashing.png'):
    fig, ax = plt.subplots(figsize=(10, 6))
    ax.plot(h_new['rounds'], h_new['slashed'], label='Total Stake Slashed', color='red', lw=2)
    ax.set_xlabel('Round $t$', fontsize=12)
    ax.set_ylabel('Total Stake Slashed (ETH)', fontsize=12)
    ax.set_title('Cumulative Stake Slashing Under Canonical MF-PoP', fontsize=13)
    ax.legend()
    ax.grid(True, alpha=0.3)
    plt.tight_layout()
    plt.savefig(out_path, dpi=300)
    plt.savefig(out_path.replace('.png', '.pdf')) # Lưu thêm bản PDF cho bài báo
    plt.close()

def main():
    print("="*70)
    print("  Canonical MF-PoP Reputation System Simulation")
    print("  Scenario: Oscillating Attack (N=6)")
    print("="*70)
    
    hist_new = run_simulation(200, attacker_cycle_N=6, use_canonical=True)
    hist_old = run_simulation(200, attacker_cycle_N=6, use_canonical=False)
    
    print("\n--- RESULTS AFTER 200 ROUNDS ---")
    print(f"1. OLD Baseline: Attacker Rep = {hist_old['atk_r'][-1]:.4f} (EVADED)")
    print(f"2. NEW Canonical: Attacker Rep = {hist_new['atk_r'][-1]:.4f}")
    if hist_new['atk_r'][-1] <= R_MIN + 1e-6:
        print("   -> ✓ PASS: Attacker fully jailed via geometric slash.")
        jail_round = next(r for r, val in zip(hist_new['rounds'], hist_new['atk_r']) if val <= R_MIN + 1e-6)
        print(f"   -> Jailed exactly at Round {jail_round}")
    
    # --- PHẦN GỌI HÀM VẼ ĐỒ THỊ ---
    plot_reputation_recovery(hist_new, hist_old)
    print("\nChart saved to results/mfpop_reputation_recovery.png")
    
    plot_stake_slashing(hist_new)
    print("Chart saved to results/mfpop_stake_slashing.png")

if __name__ == '__main__':
    main()