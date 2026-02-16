

# Adapters: DEX Integration and Extension

This document provides a deep technical walkthrough of the adapter architecture in EZManager, covering the unified interface, DEX-specific logic, extension patterns, permissioning, and event/error references. Current adapters are `UniswapAdapter.sol` and `AerodromeAdapter.sol`.

---

## 1. Purpose and Architecture

Adapters abstract all DEX-specific logic and expose a unified interface to `CLManager` and `CLCore`. This enables seamless integration of new DEXs and ensures all position management flows are consistent.

**Responsibilities:**
- Mint, increase, remove, and unwind LP positions
- Handle swaps, slippage, and fee collection
- Expose pool and NPM addresses for each DEX
- Enforce permissioning for manager contracts
- Emit standardized events for all flows

---

## 2. Supported Adapters

### 2.1. UniswapAdapter
- Integrates Uniswap V3 pools and also powers the PancakeSwap variant via an `isPancakeSwap` flag (router signature differences only)
 - Uses slippage protection. Slippage is provided by callers as a `slippageBps` parameter (basis points) and forwarded from the manager to adapters.
- Emits `Minted`, `Increased`, `Removed`, `Unwound`, `Swapped` events

### 2.2. AerodromeAdapter
- Integrates Aerodrome Slipstream pools
- Uses tickSpacing instead of fee
- Handles Aerodrome-specific pool and tick logic
- Emits same event set as UniswapAdapter

---

## 3. Common Features and Patterns

- **Pool Validation**: `validateAndGetPoolParams(pool)` reads pool parameters and verifies the pool address is consistent with the adapter’s factory-derived pool for the given tokens and fee/tickSpacing. Adapters also reject `token0 == token1` pairs (`UnsupportedPair`).
- **Seeding From USDC**: `seedPairFromUSDC` converts USDC into a valid token bundle for minting/adding liquidity. If neither token is USDC, a bridge token must be involved (configured via `CLCore.bridgeTokens()`); when both tokens are bridge tokens, the adapter picks the seed token using allowlisted liquidity scoring.
- **Supported Pair Shapes (for seeding)**:
  - USDC-direct: one of `token0`/`token1` is USDC (no initial swap required).
  - USDC ↔ bridge: one side is a bridge token and the other side is a non-connector token (seed swap produces the bridge token).
  - bridge ↔ bridge: both sides are bridge tokens; the seed token is chosen based on allowlisted liquidity scoring from USDC.
  - Other shapes are rejected with `UnsupportedPair()`.
- **Slippage Protection**: Swaps and liquidity actions enforce slippage via on-chain TWAP oracles (`observe()` on the relevant pool). The lookback window is configurable via `setTwapSeconds` (default 60s). Adapters revert with `PoolUninitialized()` when a pool has `slot0.sqrtPriceX96 == 0` and revert with `SlippageExceeded(expectedMinOut, actualOut)` when outputs violate the TWAP-derived minimum.
- **Slippage Budgeting**: Adapters enforce a shared per-flow budget by consuming a remaining USDC loss budget (`remainingLossUSDC`) sequentially across multi-step actions (seeding → rebalance swap → mint/increase → dust conversion). See `docs/SLIPPAGE.md`.
- **Budget Outputs**: Adapter entrypoints thread `remainingLossUSDC` through the flow:
  - `seedPairFromUSDC(..., remainingLossUSDC)` returns `remainingLossUSDCOut`
  - `mintPosition(..., remainingLossUSDC)` and `addLiquidity(..., remainingLossUSDC)` return `remainingLossUSDCOut`
  - `swapExactUSDCForToken(..., remainingLossUSDC)` returns `(amountOutToken, remainingLossUSDCOut)`
  - `swapExactInToUSDC(..., remainingLossUSDC)` returns `(amountOutUSDC, remainingLossUSDCOut)`
  - `collectFeesToUSDC(..., remainingLossUSDC)` returns `(fee0, fee1, usdcOut, remainingLossUSDCOut)`
- **Permissioning**: Only manager (set by the Timelock/Gnosis Safe multisig) can call state-changing functions. Owner (Timelock/multisig) can call admin functions. Guardian (direct multisig) can pause/unpause.
- **Event Emission**: All major actions emit standardized events for off-chain monitoring
- **External Quotes**: Adapters expose `quoteToToken(...)` for convenience quoting off-chain through getBestRoute; this quoting path is not used for on-chain slippage enforcement (which uses TWAP-derived minima). Adapters also expose `getExpectedOutUSDC(tokenIn, amountIn, usdc)` to return the fee-adjusted TWAP expected output for swapping a token to USDC using Valuation-selected routing (direct or one-bridge hop). This is used by the manager for sizing in `removeCollateral` without relying on spot quoter pricing.

---

## 4. Example Flows and Pseudocode

### 4.1. Minting a Position
```solidity
// Called by CLManager during openPosition
adapter.mint(...);
```

### 4.2. Adding Liquidity
```solidity
adapter.addLiquidity(...);
```

### 4.3. Removing Liquidity (USDC share)
```solidity
adapter.removeLiquidityBpsUSDC(...);
```

### 4.4. Swapping to/from USDC
```solidity
adapter.swapExactUSDCForToken(...);
adapter.swapExactInToUSDC(...);
```

---

## 5. Security and Best Practices

- All state-changing functions are permissioned (onlyManager, set by the Timelock/Gnosis Safe multisig)
 - Slippage protection is enforced on all swaps and liquidity actions. Callers provide `slippageBps` (basis points) which adapters use to validate minOut values and revert when slippage bounds are exceeded.
- Pausable for emergency stops (controlled by the Gnosis Safe multisig)

---
