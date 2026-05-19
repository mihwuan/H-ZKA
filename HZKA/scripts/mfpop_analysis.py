#!/usr/bin/env python3
"""
Detailed analysis of MF-PoP reputation trajectory
"""
import sys
sys.path.insert(0, '/home/mihwuan/Project/zkCross/scripts')

from mfpop_simulation import (
    MFPOPSimulation, R_MIN, PRECISION, W_CONS, W_HIST, W_LIVE
)

# Run single simulation and print detailed rounds
sim = MFPOPSimulation(n_honest=10, n_attackers=1)
sim.setup_nodes()

attacker = [n for n in sim.nodes if n.is_attacker][0]

print("="*70)
print("Detailed Round-by-Round Analysis")
print("="*70)
print(f"Initial attacker reputation: {attacker.reputation:.6f}")
print(f"Initial attacker history: {attacker.history_score:.6f}")
print(f"R_MIN threshold: {R_MIN/PRECISION:.6f}")
print()

# Track key rounds
key_rounds = [1, 6, 12, 18, 24, 30, 36, 42, 47, 50, 100, 150, 200]
round_data = {}

for round_num in range(1, 201):
    result = sim.simulate_round(round_num)
    
    if round_num in key_rounds:
        attacker_data = [u for u in result['nodes_updated'] if u['is_attacker']][0]
        round_data[round_num] = {
            'reputation': attacker.reputation,
            'history': attacker.history_score,
            'consecutive_fails': attacker.consecutive_fails,
            'consistent': attacker_data['consistent'],
            'is_below_rmin': attacker.reputation <= R_MIN/PRECISION * 1.05
        }

print(f"{'Round':<6} {'R (rep)':<12} {'History':<12} {'ConsecFails':<12} {'Consistent':<12} {'Below R_MIN':<12}")
print("-"*70)
for round_num in key_rounds:
    if round_num in round_data:
        data = round_data[round_num]
        print(f"{round_num:<6} {data['reputation']:<12.6f} {data['history']:<12.6f} {data['consecutive_fails']:<12} {str(data['consistent']):<12} {str(data['is_below_rmin']):<12}")
    else:
        print(f"{round_num:<6} {'(not simulated)':<12}")

print()
print("="*70)
print("SUMMARY")
print("="*70)
print(f"Attacker reputation at round 47: {round_data[47]['reputation']:.8f}")
print(f"Attacker reputation at round 200: {sim.nodes[sim.n_honest].reputation:.8f}")
print(f"R_MIN target: {R_MIN/PRECISION:.8f}")

if sim.nodes[sim.n_honest].reputation <= R_MIN/PRECISION:
    print("✓ SUCCESS: Attacker isolated!")
else:
    print("✗ FAILURE: Attacker NOT isolated")
    gap = sim.nodes[sim.n_honest].reputation - R_MIN/PRECISION
    print(f"  Gap to R_MIN: {gap:.8f}")
    print(f"  Ratio: {sim.nodes[sim.n_honest].reputation / (R_MIN/PRECISION):.2f}x above threshold")
