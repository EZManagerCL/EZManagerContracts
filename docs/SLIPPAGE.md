# Slippage Budgeting

This document describes how a caller-provided `slippageBps` budget is enforced across multi-step protocol flows.

Policy:
- User-funded multi-step actions enforce a single shared budget across sequential sub-operations by tracking a remaining USDC loss budget.
- Protocol/bot fee conversions are outside the user budget model (they do not consume the user-funded `remainingLossUSDC`), but still enforce slippage using a separate loss budget derived from the notional being swapped and the caller-provided `slippageBps`.

## Conventions

- `slippageBps` is a basis-point tolerance (`BPS = 10_000`).
- All user-supplied `slippageBps` values are clamped to `0..9999` before use.
- The manager derives an absolute slippage budget in USDC token units (`remainingLossUSDC`) and threads it through the flow.
- A flow may apply budgets at multiple layers:
  - **Manager-level** (between multiple swaps or between seeding and later steps).
  - **Adapter-level** (between rebalance swaps and mint/increase, or between hop 1 and hop 2 in a bridged route).

## Budget Initialization (USDC Loss Budget)

For a given flow, the manager defines a `baseUSDC` amount (USDC token units) for the user-funded slippage-protected work and derives a loss budget:

- `slippageBps = min(slippageBps, BPS - 1)`
- `remainingLossUSDC = ceil(baseUSDC * slippageBps / BPS)`

`remainingLossUSDC` is the remaining USDC-denominated shortfall that may be realized (vs TWAP expectations) across all user-funded operations in the flow.

## Realized Budget Consumption (Per Swap)

For each swap, adapters compute a TWAP-expected output and use `remainingLossUSDC` to derive a per-swap `minOut` that is consistent with the remaining budget.

Definitions:

- `expectedOut`: TWAP-expected output for the exact `amountIn`, using the same assumptions used to compute `minOut` (same TWAP window, same fee modeling, same decimals handling).
- `expectedOutUSDC`: `VALUATION.usdcValue(adapter, tokenOut, expectedOut)`.
- `actualOut`: the amount actually received from the swap.

Per swap:

- If `expectedOutUSDC == 0`: `lossBpsCap = BPS - 1`
- Else: `lossBpsCap = min(BPS - 1, ceil(remainingLossUSDC * BPS / expectedOutUSDC))`
- `minOut = expectedOut * (BPS - lossBpsCap) / BPS`

After execution:

- If `actualOut >= expectedOut`: `usedLossUSDC = 0`
- Else: `usedLossUSDC = ceil(expectedOutUSDC * (expectedOut - actualOut) / expectedOut)`
- Defensive clamp: `usedLossUSDC = min(usedLossUSDC, remainingLossUSDC)`
- Update: `remainingLossUSDC = remainingLossUSDC - usedLossUSDC`

All `ceil(...)` operations use conservative rounding so budget is never accidentally increased due to truncation.

## Budgeting Map (Per Flow)

### `CLManager.openPosition`

- Step 0: manager derives `remainingLossUSDC` from a `baseUSDC` defined for this flow.
- Step 1: `seedPairFromUSDC(..., remainingLossUSDC)` (adapter)
  - If the pair is not USDC-direct, the adapter performs a USDC→seed-token swap and returns `remainingLossUSDCOut`.
- Step 2: `mintPosition(..., remainingLossUSDCOut)` (adapter)
  - Adapter consumes `remainingLossUSDC` sequentially across:
    - any rebalance swap
    - mint mins (`amount0Min` / `amount1Min`)
    - dust conversion (sequential per dust swap) using the remaining budget after rebalance/mint
  - Returns `remainingLossUSDCOut`.
- Step 3 (optional): second pass uses the remaining loss budget returned by the adapter from step 2; see `CLManager._maybeSecondPass`.

### `CLManager.addCollateral`

- Same budgeting structure as `openPosition`, but `addLiquidity` is called instead of `mintPosition`.

### `CLManager._maybeSecondPass` (open/add/compound/changeRange follow-on)

- Uses the `remainingLossUSDC` budget passed in by the parent flow (no recomputation) and threads it through `seedPairFromUSDC` and `addLiquidity`.

### `CLManager.exitPosition`

- Step 1: `unwindToTokens(...)` (adapter)
  - Produces up to two non-USDC token balances to swap.
- Step 2: manager swaps each non-USDC token to USDC using `swapExactInToUSDC(..., remainingLossUSDC)`
  - The manager uses a single sequential `remainingLossUSDC` budget across the swaps.

### `CLManager.collectFeesToUSDC`

- Single adapter call per position: `collectFeesToUSDC(..., remainingLossUSDC)` (adapter)
  - The adapter applies a single `remainingLossUSDC` budget sequentially across the internal swaps required to convert fee tokens to USDC.

### `CLManager.compoundFees` (bot-fee sell + reinvest)

- Step 1: fee collection to tokens: `collectFeesToTokens(...)` (adapter)
  - No slippage budget; this is a pure collect.
- Step 2 (bot only): manager sells a portion of collected fee tokens to USDC to pay the bot via `swapExactInToUSDC`
  - This conversion is outside the user budget model; the manager derives a fresh `remainingLossUSDC` from the expected USDC value of the tokens being sold and applies it sequentially across the required swap(s).
- Step 3: reinvest remaining fees: `addLiquidity(..., remainingLossUSDC)` (adapter)
  - Adapter applies the flow's `remainingLossUSDC` budget sequentially across the rebalance swap (if any), the liquidity mins, and dust conversion.
- Step 4: optional second pass uses `_maybeSecondPass` (see above).

### `CLManager.changeRange`

- Step 1: `unwindToTokens(...)` (adapter) to retrieve the full position token bundle.
- Step 2: `mintPosition(..., remainingLossUSDC)` (adapter)
  - Adapter applies the flow's `remainingLossUSDC` budget sequentially across the rebalance swap (if any), the mint mins, and dust conversion.
- Step 3: fee assessment (protocol + optional bot fee) via `removeLiquidityBpsUSDC(..., slippageBps)` (adapter)
  - This conversion is outside the user budget model; the manager derives a fresh `remainingLossUSDC` from the expected USDC notional being removed and uses it for any token→USDC conversions required inside the adapter.
- Step 4: optional second pass uses `_maybeSecondPass` (see above).

## Adapter Internal Splits (Common Patterns)

### Two-hop routing (bridged swaps)

When an adapter performs a bridged token swap using two pools, it applies a single `remainingLossUSDC` budget sequentially:

- hop 1 consumes loss budget based on realized shortfall vs TWAP-expected output
- hop 2 uses the remaining loss budget after hop 1 and consumes additional loss budget based on its own realized shortfall

### Mint/increase with a rebalance plan

When an adapter is asked to mint or increase liquidity with a `RebalanceParams` plan, it applies a single `remainingLossUSDC` budget:

- any rebalance swap consumes loss budget based on realized shortfall vs TWAP-expected output
- liquidity action mins (`amount0Min` / `amount1Min`) are computed using a per-action `lossBpsCap` derived from the remaining loss budget
