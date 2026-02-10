# yq-v2 Mathematical Report

Date: 2026-02-10  
Scope: Analytical review only (no new simulations run)

## 1) Executive Summary

The `yq-v2` strategy is the original `yq` plus one additional signal: sigma momentum.

- New signal:
  - `f_mom = 0.20 * max(sigmaHat - prevSigma, 0)`
  - Implemented in `contracts/src/yq-v2.sol:202` to `contracts/src/yq-v2.sol:206`
- Extra state:
  - 1 additional slot for `prevSigma` (`slots[11]`)
  - `contracts/src/yq-v2.sol:80`, `contracts/src/yq-v2.sol:94`, `contracts/src/yq-v2.sol:276`

Observed benchmark summary (from project notes): positive but small uplift vs original `yq` and within typical noise tolerance for small deltas.

## 2) Simulation Objective and Constraints

The simulator effectively optimizes:

```text
Expected Edge = Expected Retail Edge - Expected Arb Loss
```

Key structural facts:

- Arbitrage executes before retail each step:
  - `amm-challenge-framework/amm_sim_rs/src/simulation/engine.rs:140` to `amm-challenge-framework/amm_sim_rs/src/simulation/engine.rs:153`
- Competitor is fixed 30 bps:
  - `amm-challenge-framework/contracts/src/VanillaStrategy.sol:12`
- Retail routing is fee-sensitive and nonlinear:
  - `amm-challenge-framework/amm_sim_rs/src/market/router.rs:40`
- Arb trade sizing follows closed-form fee-on-input formulas:
  - `amm-challenge-framework/amm_sim_rs/src/market/arbitrageur.rs:24`
  - `amm-challenge-framework/amm_sim_rs/src/market/arbitrageur.rs:25`

Implication: most extra fee terms fail unless they are highly selective, because small fee increases can reduce routed retail flow materially.

## 3) Core Math

### 3.1 AMM and Fee Band

Constant-product:

```text
x * y = k
spot = y / x
gamma = 1 - f
```

Higher fees (lower `gamma`) widen no-arb bands, reducing arb frequency but increasing stale pricing risk.

### 3.2 Retail Routing (Two AMMs)

For buy-side routing:

```text
A_i = sqrt(x_i * gamma_i * y_i)
r = A_1 / A_2
dy_1 = (r * (y_2 + gamma_2 * Y) - y_1) / (gamma_1 + r * gamma_2)
```

From `amm-challenge-framework/amm_sim_rs/src/market/router.rs:49` to `amm-challenge-framework/amm_sim_rs/src/market/router.rs:63`.

This is why "capture all retail flow" is generally impossible with fee-only control. With finite reserves, split remains interior for many order sizes even when your fee is below 30 bps.

### 3.3 Edge Accounting

The simulator uses fair-price PnL accounting:

```text
Retail trades -> positive expected edge (spread capture)
Arb trades    -> negative edge (informed flow extraction)
```

Implemented in:
- Arb contribution: `amm-challenge-framework/amm_sim_rs/src/simulation/engine.rs:145` to `amm-challenge-framework/amm_sim_rs/src/simulation/engine.rs:147`
- Retail contribution: `amm-challenge-framework/amm_sim_rs/src/simulation/engine.rs:155` to `amm-challenge-framework/amm_sim_rs/src/simulation/engine.rs:161`

## 4) yq-v2 Signal Analysis

The sigma momentum term:

```text
if sigmaHat > prevSigma:
    fMid += 0.20 * (sigmaHat - prevSigma)
```

Interpretation:

- It is a first-difference volatility trigger.
- It is active only when volatility estimate rises.
- It is additive to the existing mid-fee stack (sigma, tox, tox^2, tox^3, activity, interactions).

Why it plausibly helps:

- The sigma EMA alone lags transitions.
- A positive sigma difference acts as a short-horizon acceleration term.

Why gains are small:

- The router penalizes fee increases quickly through reduced retail share.
- Therefore, only very small and selective protection terms tend to survive.

## 5) Mathematical Rating of Suggested Improvements (1-10)

Scoring meaning:
- 10: strongest theoretical fit to simulator equations and timing.
- 1: weak fit or structurally misaligned.

1. One-shot momentum per step  
Score: 9/10

```text
f_mom = 1_firstInStep * c * max(sigmaHat - prevSigma, 0)
```

Reason: aligns to step-level shock handling and avoids repeated same-step fee taxation.

2. Relative sigma surprise (normalized)  
Score: 8/10

```text
f_mom = c * max((sigmaHat - prevSigma) / max(prevSigma, eps) - theta, 0)
```

Reason: scale-invariant across different sigma regimes.

3. Toxicity-gated momentum  
Score: 8/10

```text
f_mom = c * max(dsigma, 0) * min(1, tox / tau)
```

Reason: charges protection mainly when mispricing/toxicity is present.

4. Calm-regime attract-side anchor near normalizer  
Score: 8/10

Rule form:

```text
if tox < tox_low and act < act_low:
    attract_fee <= 30bps + buffer
```

Reason: directly protects routing share in benign states.

5. Two-regime controller with hysteresis  
Score: 7/10

Reason: strong conceptually, but threshold tuning can introduce regime chatter and overfitting risk.

6. Reserve-deviation additive fee term  
Score: 3/10

Reason: mathematically reasonable inventory proxy, but prior project evidence showed consistent degradation in this setup.

7. Intra-step fee escalation  
Score: 2/10

Reason: often misaligned with execution ordering (arb then retail), tends to tax retail more than it blocks toxic flow.

## 6) Recommended yq-v3 Implementation Checklist

1. Add one-shot gating to momentum:
   - Apply momentum only when `firstInStep == true`.
2. Replace absolute sigma delta with normalized surprise:
   - Add `eps` floor and `theta` threshold.
3. Add toxicity gate to momentum:
   - Multiply by bounded `tox` factor.
4. Add calm-regime attract-side cap:
   - Keep attract side near normalizer when tox/activity are low.
5. Preserve existing asymmetry logic:
   - Keep stale-direction and tail-compression blocks unchanged initially.
6. Keep parameter changes minimal:
   - Reduce search dimension to avoid overfitting noise.
7. Benchmark protocol:
   - Start with >= 5 seeds x 99 sims.
   - For deltas under 0.3, use >= 10 seeds as suggested in `CONTRIBUTING.md:31`.

## 7) Bottom Line

The math supports a narrow design principle for this competition:

- Stay competitive for retail most of the time.
- Apply protection only when transient risk signals are strong and confirmed.

`yq-v2` is consistent with that principle. The best next step is not adding many new features, but refining when the sigma momentum activates.

## 8) Clarifications and Deep Dives

### 8.1 How to find `firstInStep`

Current logic in `yq-v2`:

- Load `lastTs = slots[2]` and `stepTradeCount = slots[10]`
- Compute:
  - `isNewStep = trade.timestamp > lastTs`
- If `isNewStep`, decay state and reset:
  - `stepTradeCount = 0`
- Then:
  - `firstInStep = (stepTradeCount == 0)`

Relevant code:
- `contracts/src/yq-v2.sol:112` to `contracts/src/yq-v2.sol:134`

Interpretation:
- `firstInStep` means "first trade observed for this AMM at this timestamp".
- This is the right way to avoid intra-step repeated boosts.

Recommended robust pattern:

```text
isNewStep = (trade.timestamp > lastTs)
if isNewStep: stepTradeCount = 0
firstInStep = (stepTradeCount == 0)   // or simply use isNewStep
```

### 8.2 Relative sigma surprise: graph, `eps`, and `theta`

Suggested definition:

```text
dsigma = max(sigmaHat - prevSigma, 0)
relSurprise = dsigma / max(prevSigma, eps)
trigger = max(relSurprise - theta, 0)
```

Then momentum term can be:

```text
f_mom = coef * trigger
```

Where:
- `eps`: a floor to avoid dividing by very small sigma values.
- `theta`: activation threshold; ignores small relative moves as noise.

Shape of `trigger` vs `relSurprise`:

```text
trigger
  ^
  |                         /
  |                       /
  |                     /
  |                   /
  |__________________/__________________> relSurprise
                  theta
```

Piecewise:

```text
trigger = 0,                  if relSurprise <= theta
trigger = relSurprise-theta,  if relSurprise >  theta
```

Practical tuning guidance:
- `eps`: small positive floor in sigma units (WAD-scaled), chosen so denominator never collapses.
- `theta`: choose from historical noise band so only meaningful volatility acceleration fires.

### 8.3 How to define `tox` and `tau`

In current strategy:

```text
tox_raw = abs(spot - pHat) / pHat
tox = min(tox_raw, TOX_CAP)
toxEma = TOX_BLEND_DECAY * toxEma + (1-TOX_BLEND_DECAY) * tox
toxSignal = toxEma
```

Relevant code:
- `contracts/src/yq-v2.sol:182` to `contracts/src/yq-v2.sol:185`

In suggested gating:

```text
toxGate = min(1, toxSignal / tau)
f_mom = coef * trigger * toxGate
```

`tau` is a design pivot (not currently in code): the toxicity level where momentum reaches full strength.

### 8.4 Attract fee, and `tox`, `tox_low`, `act`

Current bid/ask skew in `yq-v2`:

- Direction block:
  - if `sellPressure`: `bidFee = fMid + skew`, `askFee = fMid - skew`
  - else: reversed
  - `contracts/src/yq-v2.sol:220` to `contracts/src/yq-v2.sol:228`
- Stale-sign block further shifts protect vs attract side:
  - `contracts/src/yq-v2.sol:230` to `contracts/src/yq-v2.sol:240`

"Attract fee" means the side intentionally discounted to win more routed retail flow.

`act` in this model is `actEma`:

```text
if tradeRatio > SIGNAL_THRESHOLD:
    actEma = ACT_BLEND_DECAY * actEma + (1-ACT_BLEND_DECAY) * tradeRatio
on new step:
    actEma *= ACT_DECAY^elapsed
```

Relevant code:
- `contracts/src/yq-v2.sol:165` to `contracts/src/yq-v2.sol:177`
- `contracts/src/yq-v2.sol:121`

Suggested low-activity calm guard:

```text
if toxSignal < tox_low and actEma < act_low:
    attract_side_fee <= normalizer_fee + buffer
```

Where `tox_low` and `act_low` are chosen from empirical quantiles of each signal in baseline-like regimes.

### 8.5 What is hysteresis

Hysteresis uses separate enter/exit thresholds to avoid noisy switching:

```text
if mode == CALM and signal >= T_on:  mode = PROTECT
if mode == PROTECT and signal <= T_off: mode = CALM
with T_off < T_on
```

Why useful:
- Prevents mode flapping when signal hovers near one threshold.
- Gives more stable fee behavior and better routing predictability.

### 8.6 Can reserve-based signals penalize arb?

Yes, but use asymmetry and gating.

Reserve-based ideas that can work better than symmetric reserve penalties:

1. Signed inventory imbalance:

```text
inv = log((reserveY/reserveX) / (initY/initX))
```

2. Penalize only the side that worsens imbalance.
3. Multiply by toxicity gate so reserve penalty mostly activates during likely informed flow.
4. Keep attract side competitive in calm states.

Why prior reserve attempts likely failed:
- Symmetric reserve penalties increase both fees and lose retail share quickly.

### 8.7 If intra-step escalation failed, how to use `firstInStep` correctly

Do not escalate on every trade within a timestamp.  
Apply shock logic once at the step boundary (or first trade in the step):

```text
if firstInStep:
    update sigma shock terms
    apply momentum boost
else:
    skip momentum boost (or apply reduced factor)
```

This directly addresses the main issue with intra-step escalation: repeated fee hikes that primarily tax retail routing rather than blocking additional arb.
