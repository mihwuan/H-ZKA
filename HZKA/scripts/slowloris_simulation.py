#!/usr/bin/env python3
import os
import json
import numpy as np
import pandas as pd
import matplotlib.pyplot as plt

R_MIN, R_MAX, R_JAIL = 0.01, 1.0, 0.015
R_INITIAL, A_H, GAMMA, Q_L, Q_S = 0.5, 0.016, 0.70, 0.95, 0.50

class MFPoPMachine:
    def __init__(self, is_attacker=False):
        self.is_attacker, self.r_base, self.h, self.phi, self.j = is_attacker, R_INITIAL, R_INITIAL, 1.0, False

    def get_effective_r(self):
        return R_MIN if self.j else max(R_MIN, self.r_base * self.phi)

    def transition(self, event: str):
        if self.j: return 
        new_h = GAMMA * self.h + (1 - GAMMA) if event == "valid" else (GAMMA * self.h if event == "invalid" else self.h)
        if event == "valid":
            self.r_base = min(R_MAX, (1 - A_H) * self.r_base + A_H * (0.7 + 0.3 * new_h))
        elif event == "missing":
            self.r_base = Q_L * self.r_base
        self.h = new_h
        if event == "invalid": self.phi *= Q_S
        if event == "invalid" and self.get_effective_r() <= R_JAIL: self.j = True

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
    
    def get_effective_r(self): return self.r

def run_slow_loris(n_rounds, osc_n, n_seeds=30, base_seed=100):
    res = {k: np.zeros((n_seeds, n_rounds)) for k in ['hon_c', 'atk_c', 'atk_o']}
    raw_data = []

    for i in range(n_seeds):
        np.random.seed(base_seed + i)
        n_c = [MFPoPMachine() for _ in range(20)] + [MFPoPMachine(True)]
        n_o = [NonMFPoPMachine() for _ in range(20)] + [NonMFPoPMachine(True)]
        
        for t in range(1, n_rounds + 1):
            is_miss = np.random.rand() < 0.05
            hon_ev = "missing" if is_miss else "valid"
            atk_ev = "missing" if is_miss else ("invalid" if t % osc_n == 0 else "valid")
            
            for j in range(20):
                n_c[j].transition(hon_ev)
                n_o[j].transition(hon_ev)
            n_c[-1].transition(atk_ev)
            n_o[-1].transition(atk_ev)
                
            res['hon_c'][i, t-1] = np.mean([x.get_effective_r() for x in n_c[:-1]])
            res['atk_c'][i, t-1] = n_c[-1].get_effective_r()
            res['atk_o'][i, t-1] = n_o[-1].get_effective_r()
            raw_data.append({"seed": base_seed + i, "round": t, "honest_c": res['hon_c'][i, t-1]})

    out = {'rounds': np.arange(1, n_rounds + 1), 'raw_data': raw_data, 'raw_atk_c': res['atk_c']}
    for k in res:
        out[k] = np.mean(res[k], axis=0)
        out[k+'_ci'] = 1.96 * np.std(res[k], axis=0) / np.sqrt(n_seeds)
    return out

def plot_figure3b(data):
    os.makedirs('results', exist_ok=True)
    fig, ax = plt.subplots(figsize=(10, 6))
    r = data['rounds']

    ax.plot(r, data['hon_c'], color="#55a868", lw=2.5, label="Honest committer")
    ax.fill_between(r, data['hon_c'] - data['hon_c_ci'], data['hon_c'] + data['hon_c_ci'], color="#55a868", alpha=0.15)
    
    ax.plot(r, data['atk_c'], color="#c44e52", lw=2.5, ls="--", label="Attacker (with MF-PoP)")
    ax.fill_between(r, data['atk_c'] - data['atk_c_ci'], data['atk_c'] + data['atk_c_ci'], color="#c44e52", alpha=0.15)
    
    ax.plot(r, data['atk_o'], color="#dd8452", lw=2.5, ls=":", label="Attacker (non MF-PoP)")
    ax.fill_between(r, data['atk_o'] - data['atk_o_ci'], data['atk_o'] + data['atk_o_ci'], color="#dd8452", alpha=0.15)

    ax.axhline(R_MIN, color="gray", ls="-.", lw=1.5, label=f"$R_{{\\min}} = {R_MIN}$")
    ax.axhline(R_JAIL, color="#b491c8", ls="--", lw=1.5, label="Isolation threshold")

    # FIX 1: Trích xuất raw data để vẽ đường dọc (Mean Isolation Round)
    iso_rounds = [np.where(data['raw_atk_c'][i] <= R_MIN)[0][0] + 1 for i in range(30) if len(np.where(data['raw_atk_c'][i] <= R_MIN)[0]) > 0]
    if len(iso_rounds) > 0:
        mean_iso = np.mean(iso_rounds)
        ax.axvline(mean_iso, color="#e8a39c", ls="--", lw=1.5, label=f"Mean isolation (round {mean_iso:.1f})")

    ax.set_xlabel("Round $t$", fontsize=17)
    ax.set_ylabel("Effective Reputation", fontsize=17)
    
    # FIX 2: Kéo hộp chú thích lên tọa độ y=0.48 (Nằm hoàn toàn ở khoảng trắng giữa các đường đồ thị)
    ax.legend(loc='center right', bbox_to_anchor=(0.98, 0.48), fontsize=14, framealpha=1.0)
    
    ax.grid(True, alpha=0.3)
    ax.set_xlim(0, max(r) + 2)
    ax.set_ylim(0.0, 1.05)
    
    plt.tight_layout()
    plt.savefig('results/fig3b_slowloris_patch.pdf')
    plt.savefig('results/fig3b_slowloris_patch.png', dpi=300)
    plt.close()

if __name__ == "__main__":
    d = run_slow_loris(200, 5)
    pd.DataFrame(d['raw_data']).to_csv('results/raw_slowloris.csv', index=False)
    plot_figure3b(d)
    print("✅ Sinh thành công đồ thị Figure 3b (Đã thêm đường đỏ dọc và sửa vị trí chú thích).")