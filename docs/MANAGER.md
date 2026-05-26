# CLManager: User Entrypoint and Flow Engine

This document provides a deep technical walkthrough of the `CLManager` contract, the user and bot entrypoint for all position management in the EZManager protocol.

---

## 1. Purpose and Architecture

`CLManager` is the main contract that users and bots interact with directly. It orchestrates all position lifecycle flows, enforces protocol and bot fees, manages permissioning, and emits all major events for off-chain monitoring. `EZWrapper` is an additional ez wrapper entrypoint documented in `EZ_WRAPPER.md`; referral accounting is documented in `REFERRAL_MANAGER.md`.

**Responsibilities:**
- Open, exit, and change range for positions
- Add/remove collateral
- Collect and compound fees
- Permission and slippage checks.
- Emit standardized events for all flows

## 2. Key Flows and Functions

### 2.1. Opening a Position
- User approves USDC to CLManager.
- `openPosition` registers the position to `msg.sender` and accepts the initial `botAllowed` flag. An overload accepts a candidate referrer that CLManager resolves through `ReferralManager`.
- `openPositionEz` is restricted to the configured EZWrapper, registers the position to EZWrapper, and accepts the real user address for referral attribution.
- CLManager checks both the DEX adapter allowlist and the CLCore `allowedPools` registry before any token approvals or external calls. It will only proceed if a pool is set to Allowed (will revert on Deprecated and NotAllowed).
- Capital-entry protocol fee is deducted and sent to ProtocolReserve. CLManager resolves and stores the user's wallet referrer for later referral attribution.
- Adapter validates the pool parameters (`validateAndGetPoolParams`) and CLManager validates tick alignment, tick bounds, and pool initialization (`slot0.sqrtPriceX96 != 0`).
- Adapter seeds the initial token bundle from USDC (`seedPairFromUSDC`) using the configured bridge token set (from `CLCore.bridgeTokens()`); the adapter returns a remaining USDC loss budget for subsequent steps.
- CLManager computes an optimal rebalance plan via `RebalancePlanner.planFromTokenBundle` and mints the LP NFT via the adapter.
- Any leftover USDC is tracked as dust.
- Position is registered in CLCore.
- Emits `PositionOpened` event.

### 2.1.1. Importing an Existing NFT
- `importNft` registers an existing LP NFT owned by the caller.
- The caller supplies the initial `botAllowed` setting. An overload accepts a candidate referrer; without a candidate, CLManager uses the default referrer when the caller has no stored referrer.
- Imports initialize referral state but do not charge protocol or referral fees.
- CLManager resolves the DEX adapter from the supplied pool, checks the CLCore allowed-pool registry, and rejects deprecated pools.
- The NFT token pair and fee or tick spacing must match the resolved pool.
- The caller must approve CLManager to transfer the NFT.
- CLManager transfers the NFT to CLCore, registers the position to the caller, and records initial deposited accounting from the current principal position value, excluding pending fees.
- Imported positions use the caller-supplied `botAllowed` setting.
- Emits `PositionImported`.

### 2.1.2. Copying a Position
- `copyPosition` opens a new directly owned position using an existing source position's pool and tick range.
- If the source position is directly owned, the source owner is used as the candidate referrer.
- If the source position is EZWrapper-owned, the mapped user returned by `EZWrapper.userForKey(sourceKey)` is used as the candidate referrer.
- The copied/source position owner receives a source reward funded from the copied open's capital-entry protocol fee using `ReferralManager.copyReferralShareBps`. If the caller has no stored wallet referrer, the effective source owner is also stored as the caller's referrer. Existing wallet referrers are preserved for later non-copy actions.
- Emits `PositionCopied` and the normal open/referral events.

### 2.2. Exiting a Position
- Batch flow (`bytes32[] keys`) with `MAX_BATCH_KEYS` cap.
- Unwinds all liquidity to tokens via the adapter and swaps any non-USDC tokens into USDC.
- If pending fees are collected as part of exit, the earned-fee protocol fee is charged on that collected fee amount and split between ProtocolReserve and the stored referrer when applicable.
- Bot fee is paid if called by a bot; the fee base excludes any dust refunded from CLCore. Protocol and bot targets are calculated before fee transfer, so bot fee does not use post-protocol-fee proceeds as its basis.
- Dust is withdrawn from CLCore and included in the owner's USDC refund (dust event emitted by CLCore). When the owner is the configured EZWrapper and the caller is a bot, CLManager credits EZWrapper, which forwards the mapped user's proceeds.
- Position is deregistered in CLCore.
- Emits `PositionExited`, `ProtocolFeePaid`, and `BotFeePaid` events (dust refund is logged by CLCore via `DustRefunded`)

### 2.3. Adding Collateral
- Capital-entry protocol fee is deducted and sent to ProtocolReserve. CLManager resolves the user's wallet referrer, storing the default referrer first if none is set.
- Adapter increases liquidity
- `totalDepositedUSDC` is increased in CLCore
- Emits `CollateralAdded` event

### 2.4. Removing Collateral
- Uses tracked dust first; any remaining target is satisfied by burning a proportional share of liquidity.
- Guardrails: uses canonical `CORE.positionValueUSDC` for value checks and caps requests to always leave more than MINIMUM_OPEN_USDC after removal (`TooMuchWithdraw`).
- Withdrawal fraction is derived from a quote (`_quotedPositionValue`) to size burns accurately; this quoting path uses adapter-side routing + TWAP expected-out logic (`ICLDexAdapter.getExpectedOutUSDC`) so it is based on TWAP + swap fee (not spot quoter), and is not the canonical accounting value source.
- If the liquidity decrease realizes pending LP fees, `earnedFeesProtocolFeeBps` is charged only on that realized fee value.
- `totalDepositedUSDC` is reduced by the measured drop in canonical value (before vs. after burn), capped at the position's current deposited accounting.
- Emits `CollateralRemoved` and, when realized fees are charged, `ProtocolFeePaid`.

### 2.5. Collecting Fees
- Batch flow (`bytes32[] keys`) with `MAX_BATCH_KEYS` cap.
- Adapter collects all pending fees and swaps them to USDC.
- Protocol fee and bot fee are both calculated from the same gross `outUSDC` basis. The protocol side uses `earnedFeesProtocolFeeBps`, defaults to 10%, applies wallet discounts, and is split between ProtocolReserve and the stored referrer when applicable.
- Bot fee (when caller is a bot) also uses gross `outUSDC` as its basis with `botFeeBps * botFeeMultiplierForEarnedFees`, then wallet discounts are applied. The multiplier defaults to `20` and is capped at `50`.
- USDC is transferred to the position owner. When the owner is the configured EZWrapper and the caller is a bot, CLManager credits EZWrapper, which forwards the mapped user's proceeds.
- Emits `FeesCollected`, `ProtocolFeePaid`, and `BotFeePaid` events

### 2.6. Compounding Fees
- Batch flow (`bytes32[] keys`) with `MAX_BATCH_KEYS` cap.
- Uses `CLCore.pendingFees(keys)` as a pre-check; positions with zero pending fees are skipped.
- Collects fees into tokens on the manager (`collectFeesToTokens`), then generates a rebalance plan and adds liquidity via the adapter.
- Protocol fee and bot fee are both calculated from the same gross USDC-equivalent value of the collected fee tokens. The protocol side uses `earnedFeesProtocolFeeBps`, defaults to 10%, applies wallet discounts, is funded only from collected fee tokens, and is split between ProtocolReserve and the stored referrer when applicable.
- Bot fee (when caller is a bot) uses the same gross collected-fee basis with `botFeeBps * botFeeMultiplierForEarnedFees`, then wallet discounts are applied. Fee-token conversions fund the earned-fee protocol target, any referral share, and the bot fee using `min(slippageBps, maxProtocolFeeSlippageBps)`; principal is not used.
- Emits `FeesCompounded`, `ProtocolFeePaid`, and `BotFeePaid` events

### 2.7. Changing Range
- Adapter fully unwinds and remints position with new range
- No rebalance protocol fee is charged on principal or full position value.
- If pending fees exist, they are collected to tokens before the range change and the protocol fee target is calculated from those collected fees using `earnedFeesProtocolFeeBps`, defaults to 10%, and applies wallet discounts.
- When a bot calls, the manager removes the base `botFeeBps` fraction of the reminted liquidity and pays the realized USDC proceeds to the bot; the collect/compound bot fee multiplier does not apply.
- Before unwind/remint, the manager collects pending LP fees to tokens and charges the earned-fee protocol fee only from those collected fee tokens. Any remaining collected fee tokens are included in the remint bundle.
- Slippage budgeting follows the same policy as other flows: large-notional steps apply a single sequential budget across swaps → mint/increase → dust conversion. Earned-fee protocol-fee sale swaps are capped by `maxProtocolFeeSlippageBps`. See `docs/SLIPPAGE.md`.
- Emits `RangeChanged` event

With default settings, owner-called changeRange pays no protocol fee unless pending earned fees are collected before the range change. Bot-called changeRange pays the earned-fee protocol fee from collected fee tokens first, then pays the proceeds from removing the base bot-fee fraction of reminted liquidity.

---

## 4. Permissioning and Modifiers

- **onlyKeyOwner**: Only the position owner can call
- **onlyKeyOwnerOrBot**: Only the owner or a whitelisted bot can call
- **onlyEZWrapper**: Only the configured EZWrapper can call ez open flows

---

## 5. Security and Best Practices

 - All flows are permissioned and logged via events
 - Protocol and bot fees are enforced automatically. Earned-fee protocol fees may be split between ProtocolReserve and ReferralManager using ReferralManager's configured share. CLManager fee discounts are always evaluated against the registered position owner, and a 100% discount fully exempts fees. For ez positions, the owner is EZWrapper, so the mapped user's discount does not apply.
 - Slippage protection is enforced on swaps and liquidity actions via adapter TWAP-based minima. Callers pass `slippageBps` (basis points); the manager derives a USDC-denominated loss budget and threads it through the flow so user-funded actions remain within the caller-provided tolerance.
 - Slippage budgeting rules per flow are documented in `docs/SLIPPAGE.md`.
- Pausable for emergency stops

---

## 6. Residual Dust

 - Residual USDC left after mint/addLiquidity calls is tracked as per-position dust in CLCore.

## 7. Default Parameters (quick reference)

| Parameter | Default (on deploy) | Units / Notes |
|---|---:|---|
| `MINIMUM_OPEN_USDC` | `10 ** usdcDecimals` (e.g. $1 when USDC has 6 decimals) | Minimum gross USDC to open a position — token units |
| `MAX_BATCH_KEYS` | `25` | Maximum keys processed in batch ops |
| `earnedFeesProtocolFeeBps` | `1_000` (10%) | Protocol fee applied to realized LP fee value: earned fees collected, compounded, realized during removeCollateral, moved during changeRange, or collected during exit |
| `maxProtocolFeeSlippageBps` | `1_500` (15%) | Maximum slippage tolerance used for swaps made specifically to fund earned-fee protocol fees |

Notes:
- All USDC-denominated parameters are specified in token units (i.e., scaled by `usdcDecimals`). For human-readable USD amounts convert by dividing by `10 ** usdcDecimals`.

---

## 8. Additional User/Bot APIs

- `allowBotForPosition(bytes32 key, bool allowed)`: Owner-only toggle for a position’s `botAllowed` flag in `CLCore`.
- `setEZWrapper(address ezWrapper_)`: Owner-only one-time setter for the EZWrapper allowed to call `openPositionEz`.
- `setReferralManager(address referralManager_)`: Owner-only setter for the persistent ReferralManager contract used for wallet referrers and referral balances. ReferralManager must be configured before open, import, ez-open, or copy flows can run.
- `setDiscountedWalletBps(address wallet, uint16 discountBps)`: Owner-only setter for wallet-specific fee discounts applied to nonzero protocol and bot fee bps.
- `setEarnedFeesProtocolFeeBps(uint16 feeBps)`: Owner-only setter for the protocol fee charged on earned fees. The default is `1_000` (10%) and the cap is `2_000` (20%).
- `setMaxProtocolFeeSlippageBps(uint16 slippageBps)`: Owner-only setter for the slippage cap applied to swaps made specifically to fund earned-fee protocol fees. The default is `1_500` (15%) and the value must be less than `10_000`.
- `setBotFeeMultiplierForEarnedFees(uint16 multiplier)`: Owner-only setter for the collect/compound bot fee multiplier. The value defaults to `20` and is capped at `50`.
- `withdrawDust(bytes32 key)`: Owner-only withdrawal of tracked `dustUSDC` from `CLCore` (also decrements `totalDepositedUSDC` by the dust amount, capped at current deposited accounting).
- `returnNft(bytes32[] keys)`: Owner or protocol owner (when paused) can return the position NFT (and any tracked dust) to its owner; designed to remain callable during emergency pauses and to be tolerant to valuation failures (try/catch is always used for non-essential valuation snapshots). This is a fee-free custody exit: it does not collect pending LP fees or charge `earnedFeesProtocolFeeBps`, and any later fee collection happens outside CLManager accounting.
