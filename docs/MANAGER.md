# CLManager: User Entrypoint and Flow Engine

This document provides a deep technical walkthrough of the `CLManager` contract, the user and bot entrypoint for all position management in the EZManager protocol.

---

## 1. Purpose and Architecture

`CLManager` is the only contract that users and bots interact with directly. It orchestrates all position lifecycle flows, enforces protocol and bot fees, manages permissioning, and emits all major events for off-chain monitoring.

**Responsibilities:**
- Open, exit, and change range for positions
- Add/remove collateral
- Collect and compound fees
- Permission and slippage checks.
- Emit standardized events for all flows

## 2. Key Flows and Functions

### 2.1. Opening a Position
- User approves USDC to CLManager.
- CLManager checks both the DEX adapter allowlist and the CLCore `allowedPools` registry before any token approvals or external calls. It will only proceed if a pool is set to Allowed (will revert on Deprecated and NotAllowed).
- Protocol fee is deducted and sent to ProtocolReserve.
- Adapter validates the pool parameters (`validateAndGetPoolParams`) and CLManager validates tick alignment, tick bounds, and pool initialization (`slot0.sqrtPriceX96 != 0`).
- Adapter seeds the initial token bundle from USDC (`seedPairFromUSDC`) using the configured bridge token set (from `CLCore.bridgeTokens()`); the adapter returns a remaining USDC loss budget for subsequent steps.
- CLManager computes an optimal rebalance plan via `RebalancePlanner.planFromTokenBundle` and mints the LP NFT via the adapter.
- Any leftover USDC is tracked as dust.
- Position is registered in CLCore.
- Emits `PositionOpened` event.

### 2.2. Exiting a Position
- Batch flow (`bytes32[] keys`) with `MAX_BATCH_KEYS` cap.
- Unwinds all liquidity to tokens via the adapter and swaps any non-USDC tokens into USDC.
- Bot fee is paid if called by a bot; the fee base excludes any dust refunded from CLCore.
- Dust is withdrawn from CLCore and included in the owner's USDC refund (dust event emitted by CLCore).
- Position is deregistered in CLCore.
- Emits `PositionExited` and `BotFeePaid` events (dust refund is logged by CLCore via `DustRefunded`)

### 2.3. Adding Collateral
- Protocol fee is deducted and sent to reserve
- Adapter increases liquidity
- `totalDepositedUSDC` is increased in CLCore
- Emits `CollateralAdded` event

### 2.4. Removing Collateral
- Uses tracked dust first; any remaining target is satisfied by burning a proportional share of liquidity.
- Guardrails: uses canonical `CORE.positionValueUSDC` for value checks and caps requests to always leave more than MINIMUM_OPEN_USDC after removal (`TooMuchWithdraw`).
- Withdrawal fraction is derived from a quote (`_quotedPositionValue`) to size burns accurately; this quoting path uses adapter-side routing + TWAP expected-out logic (`ICLDexAdapter.getExpectedOutUSDC`) so it is based on TWAP + swap fee (not spot quoter), and is not the canonical accounting value source.
- `totalDepositedUSDC` is reduced by the measured drop in canonical value (before vs. after burn).
- Emits `CollateralRemoved` event

### 2.5. Collecting Fees
- Batch flow (`bytes32[] keys`) with `MAX_BATCH_KEYS` cap.
- Adapter collects all pending fees and swaps them to USDC.
- Bot fee (when caller is a bot) is a percentage of `outUSDC` and is transferred to the bot before the remainder is sent to the position owner.
- USDC is transferred to the position owner
- Emits `FeesCollected` and `BotFeePaid` events

### 2.6. Compounding Fees
- Batch flow (`bytes32[] keys`) with `MAX_BATCH_KEYS` cap.
- Uses `CLCore.pendingFees(keys)` as a pre-check; positions with zero pending fees are skipped.
- Collects fees into tokens on the manager (`collectFeesToTokens`), then generates a rebalance plan and adds liquidity via the adapter.
- Bot fee (when caller is a bot) is derived from the USDC-equivalent value of the fee tokens collected for that compound operation and is funded by swapping a portion of those fee tokens to USDC and transferring it to the bot (principal is not used).
- Emits `FeesCompounded` and `BotFeePaid` events

### 2.7. Changing Range
- Adapter fully unwinds and remints position with new range
- Protocol fee is always enforced; when a bot calls, an additional bot fee is enforced.
- Fees are funded by removing a proportional share of the newly minted liquidity position to USDC and splitting the proceeds between protocol reserve and bot (when applicable).
- Slippage budgeting follows the same policy as other flows: large-notional steps apply a single sequential budget across swaps → mint/increase → dust conversion. Protocol/bot fee conversions are outside the user budget model. See `docs/SLIPPAGE.md`.
- Emits `RangeChanged` event

---

## 4. Permissioning and Modifiers

- **onlyKeyOwner**: Only the position owner can call
- **onlyKeyOwnerOrBot**: Only the owner or a whitelisted bot can call

---

## 5. Security and Best Practices

 - All flows are permissioned and logged via events
 - Protocol and bot fees are enforced automatically
 - Slippage protection is enforced on swaps and liquidity actions via adapter TWAP-based minima. Callers pass `slippageBps` (basis points); the manager derives a USDC-denominated loss budget and threads it through the flow so user-funded actions remain within the caller-provided tolerance.
 - Slippage budgeting rules per flow are documented in `docs/SLIPPAGE.md`.
- Pausable for emergency stops

---

## 6. Second-Pass Reinvestment

 - Second-pass reinvest: Manager may attempt a second add of leftover USDC after a mint/addLiquidity call. The second pass is performed only when the leftover USDC is a meaningful fraction of the operation's base USDC (`leftoverRatioBps > SECOND_PASS_THRESHOLD_BPS`) and the leftover amount is above `SECOND_PASS_MIN_USDC`. The second pass uses the remaining loss budget returned by the adapter from the first mint/increase.

Operators can tune these two parameters via `setSecondPassParams(uint256 thresholdBps_, uint256 minUsdc_)` on the manager.

## 7. Default Parameters (quick reference)

| Parameter | Default (on deploy) | Units / Notes |
|---|---:|---|
| `MINIMUM_OPEN_USDC` | `10 ** usdcDecimals` (e.g. $1 when USDC has 6 decimals) | Minimum gross USDC to open a position — token units |
| `SECOND_PASS_MIN_USDC` | `10 ** (usdcDecimals - 3)` (e.g. $0.001 when USDC has 6 decimals) | Minimum leftover (token units) to consider second pass |
| `SECOND_PASS_THRESHOLD_BPS` | `1` (0.01%) | Leftover must exceed this fraction of base to trigger second pass |
| `MAX_BATCH_KEYS` | `25` | Maximum keys processed in batch ops |

Notes:
- All USDC-denominated parameters are specified in token units (i.e., scaled by `usdcDecimals`). For human-readable USD amounts convert by dividing by `10 ** usdcDecimals`.

---

## 8. Additional User/Bot APIs

- `allowBotForPosition(bytes32 key, bool allowed)`: Owner-only toggle for a position’s `botAllowed` flag in `CLCore`.
- `withdrawDust(bytes32 key)`: Owner-only withdrawal of tracked `dustUSDC` from `CLCore` (also decrements `totalDepositedUSDC` by the dust amount).
- `returnNft(bytes32[] keys)`: Owner or protocol owner (when paused) can return the position NFT (and any tracked dust) to its owner; designed to remain callable during emergency pauses and to be tolerant to valuation failures (try/catch is always used for non-essential valuation snapshots).
