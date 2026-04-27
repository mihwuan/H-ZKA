R_MIN = 0.01
R_MAX = 10.0
W_CONS = 0.6
W_HIST = 0.3
W_LIVE = 0.1
PRECISION = 1.0

BETA = 0.15
SLASH_MULTIPLIER = 20

def compute_quality(consistent, history, alive):
    C = 1.0 if consistent else 0.0
    return W_CONS * C + W_HIST * history + W_LIVE * (1.0 if alive else 0.0)

def update_history(history, consistent):
    C = 1.0 if consistent else 0.0
    return 0.7 * history + 0.3 * C

reputation = 0.5
history = 0.5
consecutive_fails = 0
staked = 1.0

for round_num in range(1, 201):
    consistent = (round_num % 6) != 0
    Q = compute_quality(consistent, history, True)
    
    beta = BETA
    slashed = 0.0
    
    if Q < 0.5:
        decay_factor = 0.05
        if consecutive_fails > 0:
            decay_factor *= (0.3 ** consecutive_fails)
        new_r = reputation * decay_factor
        consecutive_fails += 1
        slashed = staked * 0.20
        staked -= slashed
    else:
        # Tweak here
        actual_beta = beta if staked > 0.5 else 0.001
        new_r = (1 - actual_beta) * reputation + actual_beta * Q
        consecutive_fails = 0

    if new_r > 3.0:
        new_r -= (new_r - 3.0) * 0.03
    reputation = max(R_MIN, min(R_MAX, new_r))
    history = update_history(history, consistent)

print(f"Final reputation: {reputation}")
