# Contributing

Thanks for your interest in improving the yq AMM fee strategy! This document covers how to contribute effectively.

## Strategy Naming Convention

All strategy variants in this repo use the `yq-` prefix:

- `Strategy.sol` — the current best strategy (canonical)
- New variants: `yq-v2.sol`, `yq-fast.sol`, `yq-inventory.sol`, etc.

When you create a new strategy, name it `yq-<descriptor>.sol` and update the `getName()` return value to match (e.g., `"yq-v2"`).

## Workflow

1. **Fork** this repository
2. **Create a branch** from `main` (e.g., `feature/yq-inventory-signal`)
3. **Implement** your strategy in `contracts/src/yq-<name>.sol`
4. **Benchmark** with at least 5-seed cross-validation:
   ```bash
   python scripts/benchmark.py contracts/src/yq-<name>.sol --sims 99 --seeds 5 --seed-spacing 10000
   ```
5. **Open a PR** with your benchmark results (mean edge, per-seed breakdown)

## Benchmarking Requirements

Single-seed results are unreliable. All contributions must include:

- **Minimum 5 seeds** x 99 simulations each (495 total)
- **Report**: mean edge, per-seed edges, and delta vs current `Strategy.sol`
- Gains under 0.3 points are within noise — provide 10+ seeds for small improvements

## Code Style

- Solidity `^0.8.24`
- SPDX header: `// SPDX-License-Identifier: MIT`
- Use WAD precision (1e18) for all fixed-point math
- Inherit from `AMMStrategyBase`
- Keep within 32 storage slots and 250k gas

## Submitting Issues

- **Bug reports**: Include strategy file, simulation command, and error output
- **Feature proposals**: Describe the signal or mechanism, expected impact, and any academic references
- **Benchmark results**: Share interesting findings even if they didn't improve the score — documenting dead ends helps everyone

## Code of Conduct

Please review our [Code of Conduct](CODE_OF_CONDUCT.md) before participating.
