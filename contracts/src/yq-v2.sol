// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AMMStrategyBase} from "./AMMStrategyBase.sol";
import {TradeInfo} from "./IAMMStrategy.sol";

contract Strategy is AMMStrategyBase {
    // ============================================================
    //                    DECAY / UPDATE CONSTANTS
    // ============================================================
    uint256 constant ELAPSED_CAP = 8;
    uint256 constant SIGNAL_THRESHOLD = WAD / 500; // ~20 bps of reserve

    // Per-step EMA decay factors
    uint256 constant DIR_DECAY = 800000000000000000; // 0.80
    uint256 constant SIZE_DECAY = 700000000000000000; // 0.70
    uint256 constant TOX_DECAY = 910000000000000000; // 0.91
    uint256 constant SIGMA_DECAY = 824000000000000000; // 0.824
    uint256 constant LAMBDA_DECAY = 990000000000000000; // 0.99
    uint256 constant RESDEV_DECAY = 850000000000000000; // 0.85
    uint256 constant IMBAL_DECAY = 900000000000000000; // 0.90

    // Within-step blend factors
    uint256 constant SIZE_BLEND_DECAY = 818000000000000000; // 0.818
    uint256 constant TOX_BLEND_DECAY = 51000000000000000; // 0.051
    uint256 constant RESDEV_BLEND = 200000000000000000; // 0.20

    // pHat tracking
    uint256 constant PHAT_ALPHA = 260000000000000000; // 0.26 (first-in-step)
    uint256 constant PHAT_ALPHA_RETAIL = 50000000000000000; // 0.05 (subsequent)
    uint256 constant DIR_IMPACT_MULT = 2;

    // Adaptive Shock Gate
    uint256 constant GATE_SIGMA_MULT = 10 * WAD;
    uint256 constant MIN_GATE = 30000000000000000; // 0.03 WAD

    // Imbalance push scaling
    uint256 constant IMBAL_PUSH_MULT = 3;
    uint256 constant IMBAL_CAP = 3 * WAD;

    // ============================================================
    //                        STATE CAPS
    // ============================================================
    uint256 constant RET_CAP = WAD / 10; // 10%
    uint256 constant TOX_CAP = WAD / 5; // 20%
    uint256 constant TRADE_RATIO_CAP = WAD / 5; // 20%
    uint256 constant LAMBDA_CAP = 5 * WAD;
    uint256 constant STEP_COUNT_CAP = 64;
    uint256 constant RESDEV_CAP = WAD / 2; // 50%

    // ============================================================
    //                    FEE MODEL CONSTANTS
    // ============================================================

    // Base fee
    uint256 constant BASE_FEE = 3 * BPS; // 30 bps

    // Base layer (fBase)
    uint256 constant SIGMA_COEF = 200000000000000000; // 0.20
    uint256 constant LAMBDA_COEF = 12 * BPS;
    uint256 constant FLOW_SIZE_COEF = 4842 * BPS;

    // Reserve deviation (NEW)
    uint256 constant RESDEV_COEF = 8000 * BPS; // 0.80 WAD
    uint256 constant RESDEV_QUAD_COEF = 25000 * BPS; // 2.50 WAD

    // Signed imbalance (NEW)
    uint256 constant IMBAL_COEF = 15 * BPS;
    uint256 constant IMBAL_TOX_COEF = 80 * BPS;

    // Toxicity layer
    uint256 constant TOX_COEF = 250 * BPS;
    uint256 constant TOX_QUAD_COEF = 11700 * BPS;

    // Directional skew
    uint256 constant DIR_COEF = 20 * BPS;
    uint256 constant DIR_TOX_COEF = 100 * BPS;

    // Stale-price directional protection
    uint256 constant STALE_DIR_COEF = 6850 * BPS;
    uint256 constant STALE_ATTRACT_FRAC = 1124000000000000000; // 1.124

    // Soft regime switching
    uint256 constant SIGMA_REGIME_THRESHOLD = 3000000000000000; // 0.003 = 30 bps sigma
    uint256 constant SIGMA_HIGH_MULT = 3 * WAD; // 3.0x above threshold

    // Tail compression
    uint256 constant TAIL_KNEE = 500 * BPS;
    uint256 constant TAIL_SLOPE_PROTECT = 930000000000000000; // 0.93
    uint256 constant TAIL_SLOPE_ATTRACT = 955000000000000000; // 0.955

    // ============================================================
    //                     SLOT LAYOUT
    // ============================================================
    // slots[0]  = bidFee
    // slots[1]  = askFee
    // slots[2]  = lastTs
    // slots[3]  = dirState (centered at WAD, [0, 2*WAD])
    // slots[4]  = pHat
    // slots[5]  = sigmaHat
    // slots[6]  = lambdaHat
    // slots[7]  = sizeHat
    // slots[8]  = toxEma
    // slots[9]  = stepTradeCount
    // slots[10] = initialRatio (set once in afterInitialize)
    // slots[11] = reserveDevEma (NEW)
    // slots[12] = signedImbalance (centered at WAD) (NEW)

    function afterInitialize(uint256 initialX, uint256 initialY) external override returns (uint256, uint256) {
        slots[0] = BASE_FEE;
        slots[1] = BASE_FEE;
        slots[2] = 0;
        slots[3] = WAD; // neutral direction
        slots[4] = initialX > 0 ? wdiv(initialY, initialX) : 100 * WAD;
        slots[5] = 950000000000000; // 0.095% initial sigma
        slots[6] = 800000000000000000; // 0.8 initial lambda
        slots[7] = 2000000000000000; // 0.2% initial size
        slots[8] = 0; // toxEma
        slots[9] = 0; // stepTradeCount
        slots[10] = initialX > 0 ? wdiv(initialY, initialX) : 100 * WAD; // initialRatio
        slots[11] = 0; // reserveDevEma
        slots[12] = WAD; // signedImbalance = neutral
        return (BASE_FEE, BASE_FEE);
    }

    function afterSwap(TradeInfo calldata trade) external override returns (uint256, uint256) {
        // --- Phase 1: Load state ---
        uint256 prevBidFee = slots[0];
        uint256 prevAskFee = slots[1];
        uint256 lastTs = slots[2];
        uint256 dirState = slots[3];
        uint256 pHat = slots[4];
        uint256 sigmaHat = slots[5];
        uint256 lambdaHat = slots[6];
        uint256 sizeHat = slots[7];
        uint256 toxEma = slots[8];
        uint256 stepTradeCount = slots[9];
        uint256 initialRatio = slots[10];
        uint256 reserveDevEma = slots[11];
        uint256 signedImbalance = slots[12];

        // --- Phase 2: Time-step decay ---
        bool isNewStep = trade.timestamp > lastTs;
        if (isNewStep) {
            uint256 elapsedRaw = trade.timestamp - lastTs;
            uint256 elapsed = elapsedRaw > ELAPSED_CAP ? ELAPSED_CAP : elapsedRaw;

            dirState = _decayCentered(dirState, DIR_DECAY, elapsed);
            sizeHat = wmul(sizeHat, _powWad(SIZE_DECAY, elapsed));
            toxEma = wmul(toxEma, _powWad(TOX_DECAY, elapsed));
            reserveDevEma = wmul(reserveDevEma, _powWad(RESDEV_DECAY, elapsed));
            signedImbalance = _decayCentered(signedImbalance, IMBAL_DECAY, elapsed);

            if (stepTradeCount > 0 && elapsedRaw > 0) {
                uint256 lambdaInst = (stepTradeCount * WAD) / elapsedRaw;
                if (lambdaInst > LAMBDA_CAP) lambdaInst = LAMBDA_CAP;
                lambdaHat = wmul(lambdaHat, LAMBDA_DECAY) + wmul(lambdaInst, WAD - LAMBDA_DECAY);
            }

            stepTradeCount = 0;
        }

        bool firstInStep = stepTradeCount == 0;

        // --- Phase 3: Spot price and fee-implied price ---
        uint256 spot = trade.reserveX > 0 ? wdiv(trade.reserveY, trade.reserveX) : pHat;
        if (pHat == 0) pHat = spot;

        uint256 feeUsed = trade.isBuy ? prevBidFee : prevAskFee;
        uint256 gamma = feeUsed < WAD ? WAD - feeUsed : 0;
        uint256 pImplied;
        if (gamma == 0) {
            pImplied = spot;
        } else {
            pImplied = trade.isBuy ? wmul(spot, gamma) : wdiv(spot, gamma);
        }

        // --- Phase 4: Update pHat with adaptive shock gate ---
        {
            uint256 ret = pHat > 0 ? wdiv(absDiff(pImplied, pHat), pHat) : 0;
            uint256 alpha = firstInStep ? PHAT_ALPHA : PHAT_ALPHA_RETAIL;
            uint256 adaptiveGate = wmul(sigmaHat, GATE_SIGMA_MULT);
            if (adaptiveGate < MIN_GATE) adaptiveGate = MIN_GATE;
            if (ret <= adaptiveGate) {
                pHat = wmul(pHat, WAD - alpha) + wmul(pImplied, alpha);
            }
            if (firstInStep) {
                if (ret > RET_CAP) ret = RET_CAP;
                sigmaHat = wmul(sigmaHat, SIGMA_DECAY) + wmul(ret, WAD - SIGMA_DECAY);
            }
        }

        // --- Phase 5: Trade ratio, direction, size, and imbalance updates ---
        uint256 tradeRatio = trade.reserveY > 0 ? wdiv(trade.amountY, trade.reserveY) : 0;
        if (tradeRatio > TRADE_RATIO_CAP) tradeRatio = TRADE_RATIO_CAP;

        if (tradeRatio > SIGNAL_THRESHOLD) {
            // Direction state update
            uint256 push = tradeRatio * DIR_IMPACT_MULT;
            if (push > WAD / 4) push = WAD / 4;
            if (trade.isBuy) {
                dirState = dirState + push;
                if (dirState > 2 * WAD) dirState = 2 * WAD;
            } else {
                dirState = dirState > push ? dirState - push : 0;
            }

            // Size EMA update
            sizeHat = wmul(sizeHat, SIZE_BLEND_DECAY) + wmul(tradeRatio, WAD - SIZE_BLEND_DECAY);
            if (sizeHat > WAD) sizeHat = WAD;

            // Signed imbalance update (size-weighted, centered at WAD)
            uint256 imbalPush = tradeRatio * IMBAL_PUSH_MULT;
            if (imbalPush > WAD / 2) imbalPush = WAD / 2;
            if (trade.isBuy) {
                signedImbalance = signedImbalance + imbalPush;
                if (signedImbalance > IMBAL_CAP) signedImbalance = IMBAL_CAP;
            } else {
                signedImbalance = signedImbalance > imbalPush ? signedImbalance - imbalPush : 0;
            }
        }

        // --- Phase 6: Update toxicity EMA ---
        uint256 tox = pHat > 0 ? wdiv(absDiff(spot, pHat), pHat) : 0;
        if (tox > TOX_CAP) tox = TOX_CAP;
        toxEma = wmul(toxEma, TOX_BLEND_DECAY) + wmul(tox, WAD - TOX_BLEND_DECAY);
        uint256 toxSignal = toxEma;

        // --- Phase 7: Update reserve deviation EMA ---
        {
            uint256 currentRatio = trade.reserveX > 0 ? wdiv(trade.reserveY, trade.reserveX) : initialRatio;
            uint256 resDev = initialRatio > 0 ? wdiv(absDiff(currentRatio, initialRatio), initialRatio) : 0;
            if (resDev > RESDEV_CAP) resDev = RESDEV_CAP;
            reserveDevEma = wmul(reserveDevEma, WAD - RESDEV_BLEND) + wmul(resDev, RESDEV_BLEND);
        }

        // --- Phase 8: Increment step trade count ---
        stepTradeCount = stepTradeCount + 1;
        if (stepTradeCount > STEP_COUNT_CAP) stepTradeCount = STEP_COUNT_CAP;

        // --- Phase 9: Compute base fee with soft regime switching ---
        uint256 flowSize = wmul(lambdaHat, sizeHat);

        uint256 sigmaContrib;
        if (sigmaHat <= SIGMA_REGIME_THRESHOLD) {
            sigmaContrib = wmul(SIGMA_COEF, sigmaHat);
        } else {
            uint256 baseContrib = wmul(SIGMA_COEF, SIGMA_REGIME_THRESHOLD);
            uint256 excess = sigmaHat - SIGMA_REGIME_THRESHOLD;
            sigmaContrib = baseContrib + wmul(wmul(SIGMA_COEF, SIGMA_HIGH_MULT), excess);
        }

        uint256 fBase = BASE_FEE + sigmaContrib + wmul(LAMBDA_COEF, lambdaHat) + wmul(FLOW_SIZE_COEF, flowSize);

        // --- Phase 10: Mid fee with toxicity and reserve deviation ---
        uint256 fMid = fBase + wmul(TOX_COEF, toxSignal) + wmul(TOX_QUAD_COEF, wmul(toxSignal, toxSignal));

        // Reserve deviation: linear + quadratic
        fMid = fMid + wmul(RESDEV_COEF, reserveDevEma) + wmul(RESDEV_QUAD_COEF, wmul(reserveDevEma, reserveDevEma));

        // Signed imbalance contribution
        uint256 imbalDev;
        bool buyImbalance;
        if (signedImbalance >= WAD) {
            imbalDev = signedImbalance - WAD;
            buyImbalance = true;
        } else {
            imbalDev = WAD - signedImbalance;
            buyImbalance = false;
        }
        fMid = fMid + wmul(IMBAL_COEF, imbalDev);
        fMid = fMid + wmul(IMBAL_TOX_COEF, wmul(imbalDev, toxSignal));

        // --- Phase 11: Directional skew from dirState ---
        uint256 dirDev;
        bool sellPressure;
        if (dirState >= WAD) {
            dirDev = dirState - WAD;
            sellPressure = true;
        } else {
            dirDev = WAD - dirState;
            sellPressure = false;
        }

        uint256 skew = wmul(DIR_COEF, dirDev) + wmul(DIR_TOX_COEF, wmul(dirDev, toxSignal));

        uint256 bidFee;
        uint256 askFee;
        if (sellPressure) {
            bidFee = fMid + skew;
            askFee = fMid > skew ? fMid - skew : 0;
        } else {
            askFee = fMid + skew;
            bidFee = fMid > skew ? fMid - skew : 0;
        }

        // --- Phase 12: Imbalance-based directional skew ---
        {
            uint256 imbalSkew = wmul(IMBAL_COEF, imbalDev) / 2;
            if (buyImbalance) {
                bidFee = bidFee + imbalSkew;
                askFee = askFee > imbalSkew ? askFee - imbalSkew : 0;
            } else {
                askFee = askFee + imbalSkew;
                bidFee = bidFee > imbalSkew ? bidFee - imbalSkew : 0;
            }
        }

        // --- Phase 13: Stale-price directional protection ---
        {
            uint256 staleShift = wmul(STALE_DIR_COEF, toxSignal);
            uint256 attractShift = wmul(staleShift, STALE_ATTRACT_FRAC);
            if (spot >= pHat) {
                bidFee = bidFee + staleShift;
                askFee = askFee > attractShift ? askFee - attractShift : 0;
            } else {
                askFee = askFee + staleShift;
                bidFee = bidFee > attractShift ? bidFee - attractShift : 0;
            }
        }

        // --- Phase 14: Asymmetric tail compression ---
        if (sellPressure) {
            bidFee = clampFee(_compressTailWithSlope(bidFee, TAIL_SLOPE_PROTECT));
            askFee = clampFee(_compressTailWithSlope(askFee, TAIL_SLOPE_ATTRACT));
        } else {
            askFee = clampFee(_compressTailWithSlope(askFee, TAIL_SLOPE_PROTECT));
            bidFee = clampFee(_compressTailWithSlope(bidFee, TAIL_SLOPE_ATTRACT));
        }

        // --- Phase 15: Store state and return ---
        slots[0] = bidFee;
        slots[1] = askFee;
        slots[2] = trade.timestamp;
        slots[3] = dirState;
        slots[4] = pHat;
        slots[5] = sigmaHat;
        slots[6] = lambdaHat;
        slots[7] = sizeHat;
        slots[8] = toxEma;
        slots[9] = stepTradeCount;
        // slots[10] = initialRatio — never changes
        slots[11] = reserveDevEma;
        slots[12] = signedImbalance;

        return (bidFee, askFee);
    }

    // ============================================================
    //                      HELPER FUNCTIONS
    // ============================================================

    function _compressTailWithSlope(uint256 fee, uint256 slope) internal pure returns (uint256) {
        if (fee <= TAIL_KNEE) return fee;
        return TAIL_KNEE + wmul(fee - TAIL_KNEE, slope);
    }

    function _powWad(uint256 factor, uint256 exp) internal pure returns (uint256 result) {
        result = WAD;
        while (exp > 0) {
            if (exp & 1 == 1) result = wmul(result, factor);
            factor = wmul(factor, factor);
            exp >>= 1;
        }
    }

    function _decayCentered(uint256 centered, uint256 decayFactor, uint256 elapsed) internal pure returns (uint256) {
        uint256 mul = _powWad(decayFactor, elapsed);
        if (centered >= WAD) {
            return WAD + wmul(centered - WAD, mul);
        }
        uint256 below = wmul(WAD - centered, mul);
        return below < WAD ? WAD - below : 0;
    }

    function getName() external pure override returns (string memory) {
        return "yq-v2";
    }
}
