# Ablation Study Results

**Date**: 2026-02-08
**Method**: 5 seeds x 99 sims each (offsets: 0, 10000, 20000, 30000, 40000)

## Baseline

- **Full strategy**: 522.49 edge
- Per-seed: 536.43, 517.66, 516.68, 530.17, 511.52

## Feature Ablation

| Feature | Mean Edge | Delta | Keep/Drop |
|---------|----------|-------|----------|
| Without improved_phat | 522.07 | -0.42 | KEEP |
| Without asymmetric_tail | 522.48 | -0.01 | neutral |
| Without burst_detection | 522.49 | +0.00 | neutral |
| Without fee_floor | 522.49 | +0.00 | neutral |
| Without interaction_terms | 522.49 | +0.00 | neutral |

## Notes

- BURST_TOX_SCALE and SIGMA_FLOOR_MULT were already disabled (=0)
- SIGMA_ACT_COEF was already 0
- Features with |delta| < 0.3 are neutral (within noise)
