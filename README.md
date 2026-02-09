# amm-challenge-yq

A dynamic fee strategy for the [AMM Fee Strategy Challenge](https://www.ammchallenge.com/) — a competition to design the most profitable fee strategy for a constant-product AMM (`x * y = k`).

## Score

| Metric | Baseline (30bps fixed) | **yq** |
|--------|----------------------|--------|
| **Cross-seed mean** | 522.13 | **523.21** (+1.08) |
| Seed 0 | 536.09 | 537.28 |
| Seed 10000 | 517.40 | 518.65 |
| Seed 20000 | 516.30 | 517.56 |
| Seed 30000 | 529.70 | 531.23 |
| Seed 40000 | 511.17 | 512.25 |

Official leaderboard score: **523.21** on [ammchallenge.com](https://www.ammchallenge.com/).

Local benchmark: 5 seed offsets x 99 simulations each (495 total).

## Novel Features

1. **Adaptive Shock Gate** — Sigma-dependent pHat update gating. Tighter in low-vol for faster tracking, wider in high-vol for noise rejection.
2. **Cubic Toxicity** — Superlinear fee response (`tox^3`) at high toxicity levels.
3. **Trade-Aligned Toxicity Boost** — Extra fee when the trade direction aligns with spot-vs-pHat divergence (likely arbitrage).
4. **Higher PHAT_ALPHA** (0.26) — Faster first-in-step price tracking, enabled by the adaptive gate protecting against outlier updates.
5. **Asymmetric Stale Direction Discount** — The attract side gets more stale discount than the protect side, improving retail flow capture.

## How to Use

### Prerequisites

- Python 3.12 (3.13+ may have compatibility issues with the Rust bindings)
- [Rust toolchain](https://rustup.rs/) (for the simulation engine)
- `pip`

### Setup

```bash
# 1. Clone this repo
git clone https://github.com/jiayaoqijia/amm-challenge-yq.git
cd amm-challenge-yq

# 2. Create a virtual environment
python3.12 -m venv .venv
source .venv/bin/activate

# 3. Clone the official challenge framework
git clone https://github.com/horacepan/amm-challenge.git amm-challenge-framework

# 4. Build the Rust simulation engine
cd amm-challenge-framework/amm_sim_rs
pip install maturin
maturin develop --release
cd ../..

# 5. Install the challenge framework
pip install -e amm-challenge-framework

# 6. Install benchmark dependencies
pip install numpy
```

### Run the Strategy

```bash
# Quick test (10 simulations)
amm-match run contracts/src/Strategy.sol --simulations 10

# Validate only (syntax + gas check)
amm-match validate contracts/src/Strategy.sol

# Full multi-seed benchmark (5 seeds x 99 sims)
python scripts/benchmark.py contracts/src/Strategy.sol --sims 99 --seeds 5 --seed-spacing 10000
```

## How to Contribute

See [CONTRIBUTING.md](CONTRIBUTING.md) for full guidelines.

**Quick start:**

1. Fork this repo and create a branch
2. Name your strategy file `yq-*.sol` (e.g., `yq-v2.sol`, `yq-fast.sol`)
3. Benchmark with 5+ seed cross-validation before submitting a PR
4. Report your mean edge in the PR description

## Strategy Architecture

Three-layer fee decomposition with 11 latent state variables:

1. **Base fee** (`fBase`): sigma + lambda + flow size (lambda x size)
2. **Symmetric widening** (`fMid`): toxicity (linear + quadratic + cubic), activity, sigma-tox interaction
3. **Directional skew**: buy/sell pressure + stale-price protection with asymmetric attract discount
4. **Trade-aligned boost**: extra fee on trades aligned with price divergence
5. **Tail compression**: asymmetric — protect side compresses less (0.93), attract side more (0.955)

### State Slots (11/32 used)

| Slot | Variable | Description |
|------|----------|-------------|
| 0 | bidFee | Current bid fee |
| 1 | askFee | Current ask fee |
| 2 | lastTs | Last timestamp |
| 3 | dirState | Directional pressure (centered at WAD) |
| 4 | actEma | Activity EMA |
| 5 | pHat | Estimated fair price |
| 6 | sigmaHat | Volatility estimate |
| 7 | lambdaHat | Trade arrival rate estimate |
| 8 | sizeHat | Trade size estimate |
| 9 | toxEma | Toxicity EMA |
| 10 | stepTradeCount | Trades in current step |

## Challenge Constraints

- **32 storage slots** (1KB persistent state)
- **250,000 gas limit** per call
- **Fees**: 0–10% (WAD precision, 1e18 = 100%)
- No external calls, assembly, or oracles

## References

- [AMM Fee Strategy Challenge](https://www.ammchallenge.com/)
