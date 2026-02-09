#!/usr/bin/env python3
"""Multi-seed benchmark to avoid overfitting to default seed=0,1,...,n-1.

Runs the strategy across multiple seed offsets and reports individual + average edge.
"""

import argparse
import sys
from decimal import Decimal
from pathlib import Path

import amm_sim_rs
import numpy as np

from amm_competition.competition.match import MatchRunner, HyperparameterVariance
from amm_competition.evm.adapter import EVMStrategyAdapter
from amm_competition.evm.baseline import load_vanilla_strategy
from amm_competition.evm.compiler import SolidityCompiler
from amm_competition.evm.validator import SolidityValidator
from amm_competition.competition.config import (
    BASELINE_SETTINGS,
    BASELINE_VARIANCE,
    baseline_nominal_retail_rate,
    baseline_nominal_retail_size,
    baseline_nominal_sigma,
    resolve_n_workers,
)


def make_runner_with_seed_offset(n_simulations, config, n_workers, variance, seed_offset):
    """Create a MatchRunner with a custom seed offset."""
    runner = MatchRunner(
        n_simulations=n_simulations,
        config=config,
        n_workers=n_workers,
        variance=variance,
    )

    # Monkey-patch _build_configs to use seed_offset
    original_build = runner._build_configs

    def patched_build():
        configs = []
        for i in range(runner.n_simulations):
            seed = i + seed_offset
            rng = np.random.default_rng(seed=seed)

            retail_mean_size = (
                rng.uniform(variance.retail_mean_size_min, variance.retail_mean_size_max)
                if variance.vary_retail_mean_size
                else config.retail_mean_size
            )
            retail_arrival_rate = (
                rng.uniform(variance.retail_arrival_rate_min, variance.retail_arrival_rate_max)
                if variance.vary_retail_arrival_rate
                else config.retail_arrival_rate
            )
            gbm_sigma = (
                rng.uniform(variance.gbm_sigma_min, variance.gbm_sigma_max)
                if variance.vary_gbm_sigma
                else config.gbm_sigma
            )

            cfg = amm_sim_rs.SimulationConfig(
                n_steps=config.n_steps,
                initial_price=config.initial_price,
                initial_x=config.initial_x,
                initial_y=config.initial_y,
                gbm_mu=config.gbm_mu,
                gbm_sigma=gbm_sigma,
                gbm_dt=config.gbm_dt,
                retail_arrival_rate=retail_arrival_rate,
                retail_mean_size=retail_mean_size,
                retail_size_sigma=config.retail_size_sigma,
                retail_buy_prob=config.retail_buy_prob,
                seed=seed,
            )
            configs.append(cfg)
        return configs

    runner._build_configs = patched_build
    return runner


def main():
    parser = argparse.ArgumentParser(description="Multi-seed benchmark for AMM strategy")
    parser.add_argument("strategy", help="Path to Solidity strategy file (.sol)")
    parser.add_argument("--sims", type=int, default=99, help="Simulations per seed batch")
    parser.add_argument("--seeds", type=int, default=5, help="Number of different seed offsets to test")
    parser.add_argument("--seed-spacing", type=int, default=10000, help="Spacing between seed offsets")
    parser.add_argument("--seed-start", type=int, default=0, help="Starting seed offset")
    args = parser.parse_args()

    strategy_path = Path(args.strategy)
    source_code = strategy_path.read_text()

    # Validate + compile
    print("Compiling strategy...")
    compiler = SolidityCompiler()
    compilation = compiler.compile(source_code)
    if not compilation.success:
        print("Compilation failed:")
        for error in (compilation.errors or []):
            print(f"  - {error}")
        return 1

    user_strategy = EVMStrategyAdapter(bytecode=compilation.bytecode, abi=compilation.abi)
    strategy_name = user_strategy.get_name()
    print(f"Strategy: {strategy_name}")

    default_strategy = load_vanilla_strategy()

    config = amm_sim_rs.SimulationConfig(
        n_steps=BASELINE_SETTINGS.n_steps,
        initial_price=BASELINE_SETTINGS.initial_price,
        initial_x=BASELINE_SETTINGS.initial_x,
        initial_y=BASELINE_SETTINGS.initial_y,
        gbm_mu=BASELINE_SETTINGS.gbm_mu,
        gbm_sigma=baseline_nominal_sigma(),
        gbm_dt=BASELINE_SETTINGS.gbm_dt,
        retail_arrival_rate=baseline_nominal_retail_rate(),
        retail_mean_size=baseline_nominal_retail_size(),
        retail_size_sigma=BASELINE_SETTINGS.retail_size_sigma,
        retail_buy_prob=BASELINE_SETTINGS.retail_buy_prob,
        seed=None,
    )

    variance = HyperparameterVariance(
        retail_mean_size_min=BASELINE_VARIANCE.retail_mean_size_min,
        retail_mean_size_max=BASELINE_VARIANCE.retail_mean_size_max,
        vary_retail_mean_size=BASELINE_VARIANCE.vary_retail_mean_size,
        retail_arrival_rate_min=BASELINE_VARIANCE.retail_arrival_rate_min,
        retail_arrival_rate_max=BASELINE_VARIANCE.retail_arrival_rate_max,
        vary_retail_arrival_rate=BASELINE_VARIANCE.vary_retail_arrival_rate,
        gbm_sigma_min=BASELINE_VARIANCE.gbm_sigma_min,
        gbm_sigma_max=BASELINE_VARIANCE.gbm_sigma_max,
        vary_gbm_sigma=BASELINE_VARIANCE.vary_gbm_sigma,
    )

    n_workers = resolve_n_workers()

    # Run across multiple seed offsets
    edges = []
    seed_offsets = [args.seed_start + i * args.seed_spacing for i in range(args.seeds)]

    print(f"\nRunning {args.seeds} batches x {args.sims} sims (seed offsets: {seed_offsets})...\n")

    for offset in seed_offsets:
        # Need fresh strategy adapters for each run (reset EVM state)
        user_strat = EVMStrategyAdapter(bytecode=compilation.bytecode, abi=compilation.abi)
        default_strat = load_vanilla_strategy()

        runner = make_runner_with_seed_offset(
            n_simulations=args.sims,
            config=config,
            n_workers=n_workers,
            variance=variance,
            seed_offset=offset,
        )
        result = runner.run_match(user_strat, default_strat)
        avg_edge = result.total_edge_a / args.sims
        edges.append(float(avg_edge))
        print(f"  Seed offset {offset:>6}: Edge = {avg_edge:.2f}")

    print(f"\n{'='*50}")
    print(f"  Individual: {', '.join(f'{e:.2f}' for e in edges)}")
    print(f"  Mean edge:  {sum(edges)/len(edges):.2f}")
    print(f"  Min edge:   {min(edges):.2f}")
    print(f"  Max edge:   {max(edges):.2f}")
    print(f"  Spread:     {max(edges) - min(edges):.2f}")
    print(f"{'='*50}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
