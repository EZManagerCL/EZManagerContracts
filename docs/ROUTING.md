# Routing

This document describes how routing logic works across valuation and adapter
modules. It focuses on how best pools are selected, how bridge tokens are
considered, and how the TWAP-driven liquidity scoring is applied.

## Overview

- Routing lives in Valuation.sol and is consumed by on-chain adapters.
- All decisions rely on allowlisted pools exposed by the core contract.
- Prices come from TWAP readings; no spot or oracle-lagged quotes are used.
- Routes are limited to a single hop or one bridge token (two pools total).

## Key Concepts

### Allowlisted Pools

The core contract supplies the canonical allowlist. Routing code never touches
unauthorised pools. Every route candidate is immediately discarded if the pool
is not allowlisted.

### Dex Context

Each routing pass builds a Dex Context comprising the DEX factory address, a
boolean flag indicating Aerodrome-style deployments, and the tick spacing list
used when Aerodrome pools are queried.

### Route Structure

Routes are constrained to two shapes:

1. Direct: tokenIn → tokenOut through a single pool.
2. Bridge: tokenIn → bridgeToken → tokenOut using two pools.

Bridge tokens must be distinct from the endpoints and appear in the bridge list
from core. Both hops must reference allowlisted pools.

### TWAP Valuation

- Each pool exposes a 60-second TWAP by default (configurable).
- Scoring converts the pool’s estimated active depth into USDC using TWAP spot quotes.
- TWAP quotes are also used to price actual swaps when valuations are returned.

## Scoring Flow

1. Enumerate candidate pools:
  - For Uniswap-style DEXs, loop fee tiers.
  - For Aerodrome, loop tick spacings.
2. Evaluate each candidate route:
  - For each candidate pool, estimate the active depth around the TWAP tick using the pool's TWAP-derived sqrt-price and the observed active liquidity (`avgL`) rather than the raw ERC20 balances. This approximates the liquidity that is actually available within a small symmetric tick band around the TWAP.
  - Convert each estimated token-side depth to a USDC amount using TWAP-based quotes.
  - Direct routes score as the smaller of the two token-side USDC values.
  - Bridge routes take the minimum score across the two legs, ensuring the bottleneck hop drives selection.
3. Track the route with the highest USDC depth score.

## Example Walkthrough

### Inputs

- `tokenIn`: WETH
- `tokenOut`: USDC
- Allowlisted pools:
  - `WETH/USDC` fee 500
  - `WETH/USDT` fee 3000
  - `USDT/USDC` fee 100
- Bridge tokens: [USDT]

### Route Evaluation

1. Direct Path
  - Pool: WETH/USDC (fee 500)
  - Estimated active depth around the TWAP tick is computed from TWAP-derived price and average active liquidity over the TWAP window (not raw ERC20 balances).
  - If the estimated token-side depths map to ~250,000 USDC on both sides, score = 250,000.

2. Bridge Path
  - First hop: WETH/USDT (fee 3000) estimated bottleneck depth is ~260,000 USDC.
  - Second hop: USDT/USDC (fee 100) estimated bottleneck depth is ~255,000 USDC.
  - Bridge score uses the minimum leg value, so score = 255,000.

### Selection

- The bridge path yields higher USDC depth, so it becomes the best route.
- Adapters receive (poolA = WETH/USDT, poolB = USDT/USDC, scoreUSDC = 255000).

## USDC Valuation Flow

- usdcValue requests the deepest route from the valuation contract for token → USDC.
- If a direct pool is chosen, the amount is multiplied by that pool’s TWAP price to produce USDC.
- If a bridge route is chosen, the amount is first priced through pool A into the bridge token, then through pool B into USDC.

## Adapter Usage

Adapters request `getBestRoute` and rely on the returned pools to:

- Select fees for swap execution.
- Clamp slippage using TWAP-derived minima.
- Token-to-token and token-to-USDC conversions.

Because the valuation module already filters for liquidity and allowlisted
status, adapters only need to handle direct versus bridged semantics
appropriately. Note that `refreshAll()` is best-effort at the run level and will
emit `RefreshFailed(pool, reason)` for individual pools that cannot be scored
(for example, due to failed TWAP observations, out-of-range ticks, missing
connector->USDC anchors, or zero active liquidity). Failed pools will be skipped
when populating cached edges.

## Summary

The routing subsystem balances simplicity and robustness by limiting routes to
one bridge hop, relying on allowlisted pools, and valuing flows in USDC using
TWAP metrics. Adapters and valuation stay in sync through a shared context and
scoring model, guaranteeing consistent decisions across the system.
