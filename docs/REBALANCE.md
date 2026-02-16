

# RebalancePlanner: Optimal Liquidity and Swap Planning

This document provides a detailed, descriptive overview of the `RebalancePlanner` contract and logic in the EZManager protocol. It covers the algorithms, integration flows, and code references as implemented.

---


## 1. Purpose and Architecture

`RebalancePlanner` is responsible for computing the optimal swap amounts and token allocation for concentrated liquidity positions, maximizing efficiency and minimizing dust. The contract is invoked by `CLManager` to plan mint/add/rebalance flows. All integration and configuration of the planner is managed by the Timelock/Gnosis Safe multisig.

**Responsibilities:**
- Compute optimal swap amounts for a given range and token bundle
- Require callers to supply the exact token balances (USDC or bridge-token paired assets)
- Use "implicit tick walking" probes (SqrtPriceMath) plus damped Newton iterations with exact Uniswap V3 math (no external quoters)
- Produce deterministic swap plans for adapters and manager while remaining stable across liquidity cliffs

---


## 2. Key Functions and Flows

### 2.1. planFromTokenBundle
- Computes the optimal swap for an arbitrary token0/token1 bundle using the exact target pool
- Callers supply the concrete token0/token1 bundle they intend to mint/increase with (in protocol flows, seeding from USDC is handled by adapters)
- Returns deterministic swap instructions expressed as token0→token1 and token1→token0 amounts

### 2.2. Internal Solver
- Uses a damped Newton-Raphson iteration to equalize liquidity contributed by token0 and token1
- Applies exact V3 math (TickMath/SqrtPriceMath) to probe through ticks without explicit tick walking
- Caps iterations and early stops, only consuming them when the imbalance is large (whale trades)

---


## 3. Algorithmic Details

### 3.1. Newton Iteration for Optimal Swap
- The solver maximizes the minimum liquidity contributed by token0 and token1 within the target range.
- Each iteration converts the bundle into "liquidity units" using current sqrt price, computing the ideal balance.
- Damping plus implicit probes adapt to liquidity cliffs.

### 3.2. Overshoot Protection
- When a probe causes the solver to flip directions (indicating a cliff), it automatically backtracks by half the last move.
- This "shock absorber" prevents oscillations and lets the solver approach thin liquidity safely.

### 3.3. Deterministic Inputs
- Since adapters perform any USDC→bridge-token seeding, the planner operates purely on concrete token balances.
- No on-chain Quoter calls are required, reducing gas significantly.
- Pool context (tick spacing, fees, liquidity) is fetched directly from the target pool, and pool addresses are gated via the adapter factory plus CLCore's `allowedPools` allowlist.

Defensive ordering note:
- The planner reads `pool.token0()` / `pool.token1()` and swaps the provided amounts internally when the caller supplies `token0`/`token1` in the opposite order, ensuring the solver’s `amount0`/`amount1` always correspond to the pool’s ordering.

### 3.4. Handling Rounding and Dust
- Any leftover tokens after the optimal swap are handled by `CLManager` as dust and credited to the position.

---


## 4. Practical Examples

### 4.1. Planning from Token Bundle
```solidity
// Example: providing 5,000 token0 and 7,000 token1
planFromTokenBundle(dex, pool, token0, token1, tickLower, tickUpper, 5_000e18, 7_000e18);
// Returns: swap plan (token0ToToken1, token1ToToken0)
```

---


## 5. Integration in Protocol Flows

- `CLManager` calls `RebalancePlanner` before minting or adding liquidity to ensure positions are optimally balanced for the target range, reducing dust and maximizing capital efficiency.
- Adapters receive these swap instructions from `CLManager`.

---


## 6. Security and Operational Details

- All calculations performed by `RebalancePlanner` are pure/view-only and cannot move funds.
- Because adapters handle all swapping for bridge tokens, the planner operates deterministically on provided balances.
- Returned swap plans are enforced by adapters, which also handle any dust or rounding edge cases.

---
