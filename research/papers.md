# Academic Research for AMM Fee Optimization

## Paper 1: Optimal Dynamic Fees in AMMs (Baggiani et al. 2025)
- arXiv: 2506.02869
- **Key result**: Optimal fee is linear in inventory + tracks external price
- **Two regimes**: High fees deter arbs, low fees attract retail
- **Implementable formula**: fee* ≈ a(t) + b(t)*(y - y0)
  - y = current inventory (reserves ratio), y0 = equilibrium
  - a,b depend on value function derivatives
- **Insight for us**: We track dirState but don't use RESERVE DEVIATION as a signal.
  The ratio reserveX/reserveY vs initial ratio is an untapped inventory signal.

## Paper 2: Optimal Fees for LP in AMMs (Campbell et al. 2025)
- arXiv: 2508.08152
- **Key result**: Threshold-type fee — stable under normal conditions, spikes in high vol
- **Fee depends on**: volatility sigma, CEX spread, arrival rates
- **Under normal vol**: optimal fee ≈ CEX trading cost (competitive)
- **Under high vol**: optimal fee >> CEX cost (protective)
- **Insight for us**: We already have sigma-dependent fees but NO threshold/regime switch.
  A hard sigma threshold could be more effective than smooth scaling.

## Paper 3: Adaptive Fees and Adverse Selection (2023)
- Kyle (1985) framework for DeFi
- **Key result**: Optimal fee scales with asset price volatility
- **Insight**: Confirms our sigma-based approach is directionally correct

## Novel Algorithm Ideas (Not Yet Tried)

### 1. Reserve Ratio Signal (from Paper 1)
Track how far reserves have drifted from initial ratio:
```
reserveRatio = reserveY / reserveX  (current)
initialRatio = initialY / initialX  (stored from init)
deviation = |reserveRatio - initialRatio| / initialRatio
fee += RESERVE_DEV_COEF * deviation
```
This captures INVENTORY RISK directly — something our EMA-based signals miss.
Uses 1 new slot (initialRatio or just deviation EMA).

### 2. Sigma Threshold Regime Switch (from Paper 2)
Instead of smooth sigma scaling, use hard threshold:
```
if (sigmaHat > SIGMA_HIGH_THRESHOLD) {
    // Protective regime: higher base, wider spread
    fBase = PROTECTIVE_BASE_FEE + wmul(HIGH_SIGMA_COEF, sigmaHat);
} else {
    // Competitive regime: lower base, tighter spread
    fBase = COMPETITIVE_BASE_FEE + wmul(LOW_SIGMA_COEF, sigmaHat);
}
```

### 3. Cumulative Imbalance Signal
Track net signed flow (buys minus sells) as inventory proxy:
```
if (isBuy) imbalance += tradeRatio; else imbalance -= tradeRatio;
// Decay toward zero
imbalance = wmul(imbalance, IMBALANCE_DECAY);
// Higher fee when imbalance is large (inventory risk)
fee += IMBALANCE_COEF * |imbalance|;
```
Uses 1 new slot. Different from dirState because it accumulates SIZE, not just direction.

### 4. Adaptive Shock Gate
Make PHAT_SHOCK_GATE dynamic based on recent volatility:
```
adaptiveGate = wmul(sigmaHat, GATE_SIGMA_MULT);
// Instead of fixed 0.04 gate
```
In low-vol regimes, tighter gate = faster pHat tracking.
In high-vol regimes, wider gate = more robust to noise.

### 5. Exponential Fee Scaling
Replace linear+quadratic fee model with exponential:
```
fee = base * exp(k * toxSignal)
```
Approximated in integer math as: fee = base + wmul(k, toxSignal) + wmul(k2, wmul(toxSignal, toxSignal)) / 2
(Taylor expansion — we already have linear+quadratic, add cubic term)
