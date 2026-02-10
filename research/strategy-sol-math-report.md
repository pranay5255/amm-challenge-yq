# Strategy.sol Mathematical Report

Date: 2026-02-10  
Scope: Analytical review of `contracts/src/Strategy.sol` (no new simulations run)

## 1) Executive Summary

`contracts/src/Strategy.sol` is a layered adaptive-fee controller:

1. Estimate latent market state (`pHat`, `sigmaHat`, `lambdaHat`, `sizeHat`, `toxEma`, `actEma`, `dirState`)
2. Build a symmetric mid-fee (`fMid`) from volatility, flow, toxicity, and activity
3. Apply directional skew + stale-sign asymmetry + trade-aligned boost
4. Compress tails and clamp

This structure is mathematically strong for the challenge objective:

```text
Expected Edge = Expected Retail Edge - Expected Arb Loss
```

But the simulator’s routing is highly fee-elastic, so broad fee increases often lose more retail flow than arb they prevent.

## 2) Detailed Mechanics of Strategy.sol

### 2.1 State and initialization

State slots are documented in:
- `contracts/src/Strategy.sol:60` to `contracts/src/Strategy.sol:70`

Initialization:
- `contracts/src/Strategy.sol:72` to `contracts/src/Strategy.sol:84`

Important priors:
- `pHat` initialized from reserves
- nonzero `sigmaHat`, `lambdaHat`, `sizeHat` seeds to avoid cold-start underreaction

### 2.2 Step boundary and decays

Step detection:
- `isNewStep = trade.timestamp > lastTs`
- `contracts/src/Strategy.sol:100`

On new step:
- elapsed capping: `contracts/src/Strategy.sol:103`
- state decays: `contracts/src/Strategy.sol:105` to `contracts/src/Strategy.sol:108`
- arrival-rate update from step trade count: `contracts/src/Strategy.sol:110` to `contracts/src/Strategy.sol:114`
- reset trade counter: `contracts/src/Strategy.sol:116`

Mathematically:

```text
dirState <- decayCentered(dirState)
actEma, sizeHat, toxEma <- exponentially decayed
lambdaInst = stepTradeCount / elapsedRaw
lambdaHat <- 0.99*lambdaHat + 0.01*lambdaInst
```

### 2.3 Price inference (`pImplied`) and robust `pHat`/`sigmaHat` updates

Spot:
- `spot = reserveY / reserveX`
- `contracts/src/Strategy.sol:121`

Fee-adjusted implied price from last quoted fee:
- `contracts/src/Strategy.sol:124` to `contracts/src/Strategy.sol:131`

```text
gamma = 1 - feeUsed
pImplied = spot * gamma        (if AMM buys X)
pImplied = spot / gamma        (if AMM sells X)
```

Deviation:

```text
ret = |pImplied - pHat| / pHat
```

- `contracts/src/Strategy.sol:134`

Adaptive shock gate:

```text
adaptiveGate = max(10*sigmaHat, 0.03)
```

- `contracts/src/Strategy.sol:136` to `contracts/src/Strategy.sol:138`

`pHat` EMA update only if deviation is not too extreme:
- `contracts/src/Strategy.sol:138` to `contracts/src/Strategy.sol:140`

`sigmaHat` update only on first trade in step:
- `contracts/src/Strategy.sol:141` to `contracts/src/Strategy.sol:144`

```text
sigmaHat <- 0.824*sigmaHat + 0.176*min(ret, 0.1)
```

### 2.4 Direction, activity, and size signals

Trade ratio:
- `tradeRatio = amountY / reserveY` capped
- `contracts/src/Strategy.sol:147` to `contracts/src/Strategy.sol:148`

Only if above significance threshold:
- `contracts/src/Strategy.sol:150`

Direction push and clamps:
- `contracts/src/Strategy.sol:151` to `contracts/src/Strategy.sol:159`

Activity EMA:
- `contracts/src/Strategy.sol:161`

Size EMA:
- `contracts/src/Strategy.sol:163` to `contracts/src/Strategy.sol:164`

### 2.5 Toxicity signal

Raw toxicity:

```text
tox = |spot - pHat| / pHat
```

- `contracts/src/Strategy.sol:167`

Cap and blend:
- `contracts/src/Strategy.sol:168` to `contracts/src/Strategy.sol:170`

```text
toxSignal = toxEma
toxEma <- 0.051*toxEma + 0.949*tox
```

This is intentionally reactive (heavy weight on latest tox).

### 2.6 Fee decomposition

Base layer:
- `contracts/src/Strategy.sol:175` to `contracts/src/Strategy.sol:176`

```text
flowSize = lambdaHat * sizeHat
fBase = BASE
      + a_sigma * sigmaHat
      + a_lambda * lambdaHat
      + a_flow * flowSize
```

Symmetric widening:
- `contracts/src/Strategy.sol:177` to `contracts/src/Strategy.sol:185`

```text
fMid = fBase
     + b1*tox
     + b2*tox^2
     + b3*tox^3
     + b_act*actEma
     + b_sigtox*(sigmaHat*tox)
```

### 2.7 Bid/ask asymmetry and protection logic

Direction-derived skew:
- `contracts/src/Strategy.sol:187` to `contracts/src/Strategy.sol:198`

Bid/ask split from `fMid`:
- `contracts/src/Strategy.sol:199` to `contracts/src/Strategy.sol:207`

Stale-sign asymmetry:
- `contracts/src/Strategy.sol:209` to `contracts/src/Strategy.sol:220`

Trade-aligned toxicity boost:
- `contracts/src/Strategy.sol:222` to `contracts/src/Strategy.sol:233`

Interpretation:
- Protect side: side likely to face informed flow gets wider
- Attract side: opposite side is discounted to preserve retail share

### 2.8 Tail compression and clamping

Tail compressor:
- `contracts/src/Strategy.sol:259` to `contracts/src/Strategy.sol:262`

```text
if fee <= knee: fee
else: knee + slope*(fee-knee)
```

Applied asymmetrically to protect/attract side:
- `contracts/src/Strategy.sol:235` to `contracts/src/Strategy.sol:242`

Then hard clamped through `clampFee`.

## 3) Findings

1. **Strong architecture**: Multi-layer decomposition (base + symmetric + directional) is well designed for the competition objective.
2. **Good temporal structure**: Step-level decay and first-in-step logic reduce noise sensitivity.
3. **Nonlinear tox terms are justified**: `tox`, `tox^2`, `tox^3` create soft-to-hard protection transitions.
4. **Main risk**: Over-widening fees in low-to-moderate risk states can quickly lose routed retail flow.
5. **Most promising improvement path**: Make protection more selective in time and regime, not globally stronger.

## 4) Suggestion Ratings (Math Perspective, 1-10)

Scale:
- 10 = strongest theoretical fit for this simulator and this strategy design
- 1 = structurally weak fit

1. One-shot transition boost using first-in-step gating  
Score: 9/10  
Why: aligns with step timing; avoids repeated intra-step fee taxation.

2. Relative sigma surprise (normalized volatility acceleration)  
Score: 8/10  
Why: scale-invariant trigger:

```text
rel = max(sigma_t - sigma_{t-1}, 0) / max(sigma_{t-1}, eps)
trigger = max(rel - theta, 0)
```

3. Toxicity-gated transition protection  
Score: 8/10  
Why: apply extra protection only when stale-price risk is also high:

```text
gate = min(1, toxSignal / tau)
extra = coef * trigger * gate
```

4. Calm-regime attract-side anchor near normalizer  
Score: 8/10  
Why: preserves routing competitiveness when risk is low:

```text
if toxSignal < tox_low and actEma < act_low:
    attract_side_fee <= normalizer + buffer
```

5. Regime switching with hysteresis  
Score: 7/10  
Why: good for stability, but threshold tuning risk:

```text
enter protect at T_on, exit at T_off, with T_off < T_on
```

6. Reserve-based asymmetric inventory penalty  
Score: 6/10  
Why: underexplored and plausible if done asymmetrically + gated; symmetric reserve penalties are usually harmful.

7. Intra-step fee escalation  
Score: 2/10  
Why: typically taxes retail routing more than it blocks additional arb once within-step dynamics are already in motion.

## 5) Most Useful Next Experiment for Strategy.sol

Highest expected value per complexity:

1. Add a small first-in-step transition term (only once per step)
2. Normalize by previous sigma (`eps` floor, `theta` threshold)
3. Gate by toxicity (`tau`)
4. Keep calm attract-side near normalizer when `tox` and `act` are low

Compact form:

```text
extraProtect =
  1_firstInStep
  * coef
  * max( max(sigmaHat-prevSigma,0)/max(prevSigma,eps) - theta, 0 )
  * min(1, toxSignal/tau)
```

Then apply `extraProtect` only to protect side, or primarily protect side, while keeping attract side competitive in calm regime.

## 6) Practical Notes

1. Keep parameter changes minimal to avoid overfitting.
2. Evaluate with multi-seed cross-validation; treat sub-0.3 gains as potentially noise.
3. Preserve existing stale-sign and tail-compression blocks initially; they are strong priors in this architecture.

## 7) Bottom Line

`Strategy.sol` is already a strong, near-frontier design for this simulator.  
The mathematically sound path forward is selective transition protection, not globally higher fees.
