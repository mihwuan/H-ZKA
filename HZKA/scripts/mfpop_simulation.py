#!/usr/bin/env python3
import json
import os
import numpy as np
import pandas as pd
import matplotlib.pyplot as plt

R_MIN, R_MAX, R_JAIL = 0.01, 1.0, 0.015
R_INITIAL, A_H, GAMMA, Q_L, Q_S, SIGMA = 0.5, 0.016, 0.70, 0.95, 0.50, 0.10

class MFPoPMachine:
    def __init__(self, is_attacker=False):
        self.is_attacker, self.r_base, self.h, self.phi, self.v, self.s, self.j = is_attacker, R_INITIAL, R_INITIAL, 1.0, 0, 1.0, False

    def get_effective_r(self):
        return R_MIN if self.j else max(R_MIN, self.r_base * self.phi)

    def transition(self, event: str) -> float:
        if self.j: return 0.0 
        slashed = 0.0
        
        new_h = GAMMA * self.h + (1 - GAMMA) if event == "valid" else (GAMMA * self.h if event == "invalid" else self.h)
        if event == "valid":
            self.r_base = min(R_MAX, (1 - A_H) * self.r_base + A_H * (0.7 + 0.3 * new_h))
        elif event == "missing":
            self.r_base = Q_L * self.r_base
        self.h = new_h
            
        if event == "invalid":
            self.phi *= Q_S
            self.v += 1
            slashed = SIGMA * self.s
            self.s -= slashed
            
        if event == "invalid" and self.get_effective_r() <= R_JAIL:
            self.j = True
        return slashed

class NonMFPoPMachine:
    def __init__(self, is_attacker=False):
        self.is_attacker, self.r, self.h = is_attacker, R_INITIAL, R_INITIAL

    def transition(self, event: str):
        C = 1.0 if event == "valid" else 0.0
        beta = 0.3 if event == "valid" else 0.4
        self.r = (1 - 0.2*beta) * self.r + (0.2*beta) * (0.6 * C + 0.3 * self.h + 0.1)
        if self.r > 0.5: self.r -= (self.r - 0.5) / 100
        self.r = max(R_MIN, min(R_MAX, self.r))
        self.h = GAMMA * self.h + (1 - GAMMA) * C
        return 0.0
    
    def get_effective_r(self): return self.r

def run_simulation(n_rounds, osc_n, n_seeds=30, base_seed=42):
    res = {k: np.zeros((n_seeds, n_rounds)) for k in ['hon', 'atk_c', 'atk_o', 'w', 'acc_c', 'acc_o', 'slash']}
    raw_data = []

    for i in range(n_seeds):
        np.random.seed(base_seed + i)
        n_c = [MFPoPMachine() for _ in range(10)] + [MFPoPMachine(True)]
        n_o = [NonMFPoPMachine() for _ in range(10)] + [NonMFPoPMachine(True)]
        t_slash = 0.0

        for t in range(1, n_rounds + 1):
            is_miss = np.random.rand() < 0.05
            hon_ev = "missing" if is_miss else "valid"
            atk_ev = "missing" if is_miss else ("invalid" if t % osc_n == 0 else "valid")
            
            for j in range(10):
                n_c[j].transition(hon_ev)
                n_o[j].transition(hon_ev)
            
            t_slash += n_c[-1].transition(atk_ev)
            n_o[-1].transition(atk_ev)
                
            res['hon'][i, t-1] = np.mean([n.get_effective_r() for n in n_c[:-1]])
            res['atk_c'][i, t-1] = n_c[-1].get_effective_r()
            res['atk_o'][i, t-1] = n_o[-1].get_effective_r()
            res['slash'][i, t-1] = t_slash
            
            atk_w_c = res['atk_c'][i, t-1] / sum(n.get_effective_r() for n in n_c) if res['atk_c'][i, t-1] > R_MIN else 0.0
            res['w'][i, t-1] = atk_w_c
            res['acc_c'][i, t-1] = 1.0 - min(1.0, atk_w_c)
            
            atk_w_o = res['atk_o'][i, t-1] / sum(n.get_effective_r() for n in n_o) if res['atk_o'][i, t-1] > R_MIN else 0.0
            res['acc_o'][i, t-1] = 1.0 - min(1.0, atk_w_o)

            raw_data.append({"seed": base_seed + i, "round": t, "honest": res['hon'][i, t-1], "slash": t_slash})

    out = {'rounds': np.arange(1, n_rounds + 1), 'raw_data': raw_data, 'raw_atk_c': res['atk_c']}
    for k in res:
        out[k] = np.mean(res[k], axis=0)
        out[k+'_ci'] = 1.96 * np.std(res[k], axis=0) / np.sqrt(n_seeds)
    return out

def plot_all(data):
    os.makedirs('results', exist_ok=True)
    r = data['rounds']

    # --- Hình 1: Multi-plot ---
    fig, axes = plt.subplots(3, 1, figsize=(10, 14))
    
    # 1. Rep Plot
    ax1 = axes[0]
    ax1.plot(r, data['hon'], label='Honest committer', color='#55a868', lw=2.5)
    ax1.fill_between(r, data['hon'] - data['hon_ci'], data['hon'] + data['hon_ci'], color='#55a868', alpha=0.15)
    
    ax1.plot(r, data['atk_c'], label='Attacker (oscillating)', color='#c44e52', ls='--', lw=2.5)
    ax1.fill_between(r, data['atk_c'] - data['atk_c_ci'], data['atk_c'] + data['atk_c_ci'], color='#c44e52', alpha=0.15)
    
    ax1.plot(r, data['atk_o'], label='Attacker (non MF-PoP)', color='#dd8452', ls=':', lw=2.5)
    ax1.fill_between(r, data['atk_o'] - data['atk_o_ci'], data['atk_o'] + data['atk_o_ci'], color='#dd8452', alpha=0.15)
    
    ax1.axhline(R_MIN, color='gray', ls='-.', label='$R_{\\min} = 0.01$')
    
    # FIX: Tính toán và vẽ đường đỏ gạch dọc (Mean Isolation Round)
    iso_rounds = [np.where(data['raw_atk_c'][i] <= R_MIN)[0][0] + 1 for i in range(30) if len(np.where(data['raw_atk_c'][i] <= R_MIN)[0]) > 0]
    if len(iso_rounds) > 0:
        mean_iso = np.mean(iso_rounds)
        ax1.axvline(mean_iso, color="#e8a39c", ls="--", lw=1.5, label=f"Mean isolation (round {mean_iso:.1f})")

    ax1.set_ylabel('Effective Reputation', fontsize=16)
    ax1.legend(loc='center right', bbox_to_anchor=(0.99, 0.45), fontsize=14, framealpha=1.0)
    ax1.grid(True, alpha=0.3)
    ax1.set_xlim(0, 200)

    # 2. Weight Plot
    ax2 = axes[1]
    ax2.plot(r, data['w'], label='Attacker voting weight', color='#8c2d04', lw=2.5)
    ax2.fill_between(r, data['w'] - data['w_ci'], data['w'] + data['w_ci'], color='#8c2d04', alpha=0.15)
    ax2.axhline(0.00, color='#b491c8', ls='--', label='Isolation threshold', lw=2.0)
    ax2.set_ylabel('Linear Voting Weight', fontsize=16)
    ax2.legend(loc='upper right', fontsize=14, framealpha=1.0)
    ax2.grid(True, alpha=0.3)
    ax2.set_xlim(0, 200)

    # 3. Acc Plot
    ax3 = axes[2]
    ax3.plot(r, data['acc_c'], label='With MF-PoP', color='#4c72b0', marker='o', markevery=10, lw=2)
    ax3.plot(r, data['acc_o'], label='Non MF-PoP', color='#c44e52', marker='x', markevery=10, lw=2)
    ax3.axhline(1.0, color='#8de5a1', ls='--', label='Perfect accuracy', lw=2.0)
    ax3.set_xlabel('Round $t$', fontsize=16)
    ax3.set_ylabel('System Accuracy', fontsize=16)
    
    # FIX: Đặt legend vào khoảng trống ở giữa bên phải để không đè lên đường Non MF-PoP
    ax3.legend(loc='center right', bbox_to_anchor=(0.99, 0.45), fontsize=14, framealpha=1.0)
    
    ax3.grid(True, alpha=0.3)
    ax3.set_xlim(0, 200)

    plt.tight_layout()
    plt.savefig('results/mfpop_reputation_recovery.pdf')
    plt.savefig('results/mfpop_reputation_recovery.png', dpi=300)
    plt.close()

    # --- Hình 2: Slashed Stake ---
    fig2, ax = plt.subplots(figsize=(10, 6))
    ax.plot(r, data['slash'], label='Total Stake Slashed', color='red', lw=2.5)
    ax.fill_between(r, data['slash'] - data['slash_ci'], data['slash'] + data['slash_ci'], color='red', alpha=0.15)
    ax.set_xlabel('Round $t$', fontsize=16)
    ax.set_ylabel('Total Stake Slashed (ETH)', fontsize=16)
    ax.legend(loc='lower right', fontsize=14, framealpha=1.0)
    ax.grid(True, alpha=0.3)
    ax.set_xlim(0, 200)

    plt.tight_layout()
    plt.savefig('results/mfpop_stake_slashing.pdf')
    plt.savefig('results/mfpop_stake_slashing.png', dpi=300)
    plt.close()

if __name__ == "__main__":
    d = run_simulation(200, 6)
    pd.DataFrame(d['raw_data']).to_csv('results/raw_analysis.csv', index=False)
    plot_all(d)
    print("✅ Sinh thành công đồ thị Analysis (Đã hiển thị đường cách ly và fix lỗi chú thích).")