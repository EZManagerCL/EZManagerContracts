

# Canonical Accounting in EZManager

This document provides a comprehensive, code-accurate reference for all accounting flows, value calculations, and fee logic in the EZManager protocol. All values are denominated in USDC unless otherwise noted.

---

## 1. Overview

EZManager’s accounting is designed for deterministic and auditable management of concentrated liquidity positions across multiple DEXs. All user and protocol value flows are tracked in USDC, with canonical state held in `CLCore`.


**Key contracts:**
- `CLCore`: Canonical state, position registry, and value logic
- `CLManager`: User entrypoint, fee enforcement, and event emission
- `EZWrapper`: Optional ez wrapper and forwarding for wrapper-owned position proceeds
- `ReferralManager`: Persistent wallet referrer registry and referral balance accounting
- `Valuation`: On-chain USDC valuation for any token

---

## 2. Position State and Value

### 2.1. Position Structure

Each position is represented by a `Position` struct in `CLCore`:

```solidity
struct Position {
	address owner;
	uint256 tokenId;
	address token0;
	address token1;
	uint24 fee;       
	int24 tickSpacing;
	int24 tickLower;
	int24 tickUpper;
	uint256 totalDepositedUSDC;
	uint256 dustUSDC;    
	bool botAllowed;   
	uint48 openedAt;
	address dex;
	address pool;
}
```

### 2.2. Canonical Value Calculation

The **canonical value** of a position is computed by `CLCore.positionValueUSDC` as:

$$
	ext{valueUSDC} = \text{USDC-equivalent of token0} + \text{USDC-equivalent of token1} + \text{dustUSDC}
$$

**Note:** This value does **not** include pending fees. Pending fees are tracked and claimable, but not included in canonical value until compounded.

### 2.3. Dust Handling

- **dustUSDC** is tracked per position and represents leftover USDC after swaps, rounding, or liquidity operations.
- Dust is always included in canonical value and is withdrawn by the position owner before deregistration during the exit flow.
- Dust is credited via `addDustToPosition` and debited via `withdrawDustForPosition`.
- `addDustToPosition` follows a push model — the manager must transfer USDC into `CLCore` prior to calling (no internal pull). `withdrawDustForPosition` is a pull of a specified `amount` to the destination address.
- When CLManager exposes dust withdrawal to the position owner, the withdrawn amount also reduces `totalDepositedUSDC`, capped at current deposited accounting.

---

## 3. Fee Logic

### 3.1. Protocol Fee

- **protocolFeeBps** (default 0.4%) is charged on deposit-like flows: position open and addCollateral.
- On open and addCollateral, CLManager charges the capital-entry protocol fee and sends it to `ProtocolReserve`. The user's stored referrer is resolved for later referral attribution.
- CLManager applies fee discounts to nonzero protocol fee bps; a 100% discount fully exempts fees.
- Fee is sent to `ProtocolReserve`. It does **not** reduce `totalDepositedUSDC`.
- The position owner's principal (`totalDepositedUSDC`) is always the gross amount supplied, from the user's wallet into the protocol.

#### Example
If a user supplies 10,000 USDC and protocolFeeBps is 40 (0.4%):

	totalFee = 10,000 * 0.004 = 40 USDC
	totalDepositedUSDC = 10,000 USDC
	40 USDC sent to ProtocolReserve

If the registered position owner has a 25% CLManager wallet discount, the effective protocol fee is 30 bps (0.3%) and the same 10,000 USDC supply pays a 30 USDC total fee. `totalDepositedUSDC` is still 10,000 USDC.

### 3.1.1. Referral Fee Share

Referral fees are a share of the existing protocol fee, not an added fee. `ReferralManager` stores wallet referrers and claimable referral balances.

Default referral parameters:
- `referralShareBps = 2_000`: the stored referrer receives 20% of earned-fee protocol fees.
- `copyReferralShareBps = 5_000`: the copied/source position owner receives 50% of the capital-entry protocol fee charged on a copied open.

Formula:

```solidity
earnedProtocolFeeUSDC = realizedEarnedFeesUSDC * earnedFeesProtocolFeeBps / 10_000
referralFeeUSDC = earnedProtocolFeeUSDC * referralShareBps / 10_000
reserveFeeUSDC = earnedProtocolFeeUSDC - referralFeeUSDC
```

Claimable referral balance is only increased when `referralFeeUSDC` is nonzero.

`referrerUserCount` increments when a wallet is first assigned to a referrer and is exposed for UI/display. It is not used for payout rates.

Copy-position nuance: `copyPosition` pays a one-time source reward to the source position's effective owner. The source reward is funded from the copied open's capital-entry protocol fee and uses `copyReferralShareBps`, but it is conceptually a strategy-copy reward rather than the copier's long-term wallet-referrer payout. If the copier has no stored referrer, the source owner is stored as the copier's referrer for later non-copy actions. Existing wallet referrers are preserved.

### 3.2. Bot Fee

- **botFeeBps** (deployed default 0.05%) is paid to whitelisted bots for eligible actions (bot-initiated exit, collect, compound, changeRange).
- `collectFeesToUSDC` and `compoundFees` use `botFeeBps * botFeeMultiplierForEarnedFees` before wallet discounts. The multiplier defaults to `20` and is capped at `50`.
- CLManager applies fee discounts to nonzero bot fee bps; a 100% discount fully exempts fees.
- Bot fee bases are flow-specific:
  - `exitPosition`: a percentage of realized USDC proceeds excluding any dust refunded from `CLCore`.
  - `collectFeesToUSDC`: a percentage of `outUSDC` produced by swapping collected fees.
  - `compoundFees`: a percentage of the USDC-equivalent value of the fee tokens collected for that compound operation; funded by swapping a portion of those fee tokens to USDC and transferring it to the bot (principal is not used).
- Base bot fee is capped at 1% (enforced in `setBotFeeBps`); collect/compound effective bot fee is additionally scaled by the manager multiplier.
- Realized LP fee value means LP fees that are collected to USDC, compounded, realized during `removeCollateral`, realized during `changeRange`, or realized during `exitPosition`. It excludes principal, deposited capital, withdrawn capital, and position value moved only because the range changed.
- Earned-fee protocol fees are charged independently from bot fees on `collectFeesToUSDC`, `compoundFees`, `removeCollateral` when pending fees are realized by the liquidity decrease, `changeRange` when pending fees are collected before the range change, and `exitPosition` when pending fees are collected. The default `earnedFeesProtocolFeeBps` is 1,000 bps (10%) before wallet discounts. When the effective user has a stored referrer, `referralShareBps` of the earned-fee protocol fee is credited to that referrer and the remainder goes to `ProtocolReserve`.
- For `collectFeesToUSDC` and `compoundFees`, protocol and bot fees are both calculated from the same gross collected-fee basis. For `exitPosition`, protocol and bot targets use their own configured bases, but those targets are calculated before fee transfer. For `removeCollateral`, the earned-fee protocol fee is charged from returned USDC only on the pending-fee value realized by the burn. For `compoundFees` and `changeRange`, collected fee-token sales used to fund earned-fee protocol fees use `min(slippageBps, maxProtocolFeeSlippageBps)`; accepted bad execution within that capped budget can reduce both user value and the USDC ultimately received by protocol or bot fee recipients. For `changeRange`, the earned-fee protocol fee is charged from collected fee tokens before unwind/remint; any bot fee is charged separately by removing the base bot-fee fraction of reminted liquidity.

#### Examples

With `earnedFeesProtocolFeeBps = 1_000`, `referralShareBps = 2_000`, `botFeeBps = 5` (0.05%), and `botFeeMultiplierForEarnedFees = 20`, a 1,000 USDC collected-fee output creates a 100 USDC earned-fee protocol target before wallet discounts. When a stored referrer applies, 20 USDC is credited to the referrer and 80 USDC goes to reserve. A bot-called collect also pays 10 USDC to the bot before wallet discounts. The protocol and bot targets are both calculated from the original 1,000 USDC basis.

Exit uses the base bot fee directly. With `botFeeBps = 5`, a bot exit that realizes 10,000 USDC of non-dust proceeds before fees pays 5 USDC to the bot before wallet discounts; a 25% wallet discount reduces that to 3.75 USDC. If the same exit also collects pending fees, the earned-fee protocol target is calculated separately before either fee is transferred.

ChangeRange does not charge a rebalance protocol fee on principal or full position value. With `earnedFeesProtocolFeeBps = 1_000`, collecting 1,000 USDC-equivalent of pending earned fees before changeRange creates a 100 USDC protocol target before wallet discounts; a 25% wallet discount reduces that target to 75 USDC. Bot-called changeRange also removes the independent base bot-fee fraction of reminted liquidity and pays the realized USDC proceeds to the bot.

### 3.3. Fee Enforcement

- Fee configuration is maintained in `CLCore`, while fee assessment and transfers are enforced by `CLManager`.
- Protocol and bot fees are always transferred before the user receives proceeds.
- Fee transfers are logged via events (`ProtocolFeePaid`, `ReferralFeePaid`, `BotFeePaid`).

Fee-exemption note:
- CLManager fee discounts (`discountedFeeWallets`) are always evaluated against the registered position owner. A 100% discount fully exempts fees. For ez positions, the owner is EZWrapper, so the mapped user's discount does not apply.

---

## 4. Collateral Flows

### 4.1. Importing an Existing NFT

- `importNft` registers an existing caller-owned LP NFT after validating the NFT metadata against an allowed pool.
- Imports initialize the caller's wallet referrer through ReferralManager when one is not already set.
- Imports do not charge protocol or referral fees.
- The position is registered with `totalDepositedUSDC = 0`, then CLManager sets initial deposited accounting to the current principal position value, excluding pending fees.
- Imported positions use the caller-supplied `botAllowed` setting.

### 4.2. Adding Collateral

- Increases `totalDepositedUSDC` by the gross USDC supplied.
- Capital-entry protocol fee is charged and sent to ProtocolReserve. The user's wallet referrer is resolved and stored when needed.
- Any leftover is tracked as dust.

#### Code Reference
```solidity
function adjustTotalDeposited(bytes32 key, int256 usdcDelta) external onlyManager { ... }
```

### 4.3. Removing Collateral

- Uses tracked dust first; any remaining target withdraw burns liquidity proportionally via the adapter.
- Guardrails: reverts if canonical `positionValueUSDC` is zero (`PositionValueZero`) or if the request would leave < MINIMUM_OPEN_USDC (`TooMuchWithdraw`).
- Burn sizing uses a quote (via `_quotedPositionValue`) to compute the withdrawal fraction, while caps and accounting rely on canonical core value (`positionValueUSDC`). The live quote uses adapter-side routing + TWAP expected-out logic (`ICLDexAdapter.getExpectedOutUSDC`, fee-adjusted TWAP output), not a spot quoter.
- Reduces `totalDepositedUSDC` by the measured drop in value (before vs. after burn), capped at the position's current deposited accounting, not simply the requested amount.
- If the liquidity decrease realizes pending LP fees, the earned-fee protocol fee is charged on that realized fee value before net USDC is returned to the owner.
- Net USDC is transferred to the position owner.

#### Example
If position value drops by 1,000 USDC after removal, `totalDepositedUSDC` is reduced by 1,000.

---

## 5. Pending Fees

- Pending fees (token0/token1) are tracked per position but **not** included in canonical value until compounded.
- Use `pendingFees(bytes32[] keys)` to query owed fees.
- Fees are realized via `collectFeesToUSDC` or `compoundFees` in `CLManager`.

---

## 6. Off-Chain Integration

- Off-chain systems should treat `CLCore.positionValueUSDC` and `CLCore.positions(key)` (or `CLCore.getPosition(key)`) as the single source of truth for position value and principal.
- For EZWrapper ez-flow positions, use `EZWrapper.getKeysForUser(user)` for user-key attribution. Direct bot action proceeds are forwarded by EZWrapper. Use `ReferralManager` for referral balances.
- To track pending fees, use `pendingFees` and only include them in value after collection.
- For full accounting, monitor all relevant events and cross-check with on-chain state.

---

## 7. Example Flows

### 7.1. Open Position
1. User calls `openPosition` on `CLManager` with pool address, ticks, USDC amount, bot permission flag, and slippageBps. The manager enforces both the dex and pool allowlists before any approvals or external calls.
2. Capital-entry protocol fee is deducted and sent to ProtocolReserve. The user's wallet referrer is resolved and stored when needed.
3. Adapter mints position, any leftover is tracked as dust.
4. Position is registered in `CLCore` with full `totalDepositedUSDC`.

### 7.2. Import Existing NFT
1. User approves the LP NFT to `CLManager`.
2. User calls `importNft` with the token id, pool, and bot permission setting.
3. CLManager transfers the NFT to `CLCore`, registers the position, and initializes `totalDepositedUSDC` from current principal position value, excluding pending fees.

### 7.3. Add Collateral
1. User calls `addCollateral`.
2. Capital-entry protocol fee is deducted and sent to ProtocolReserve. If no wallet referrer is stored, CLManager stores and uses the default referrer.
3. `totalDepositedUSDC` is increased by gross supplied.

### 7.4. Remove Collateral
1. User calls `removeCollateral`.
2. USDC is returned and `totalDepositedUSDC` is reduced by value drop.

### 7.5. Collect Fees
1. User or bot calls `collectFeesToUSDC`.
2. Fees are swapped to USDC and the earned-fee protocol fee is split between ProtocolReserve and the stored referrer when applicable.
3. Bot fee is paid if bot.
4. Net USDC is transferred to owner. For direct bot actions on EZWrapper-owned wrapper positions, EZWrapper forwards proceeds to the mapped user.

### 7.6. Exit Position
1. User or bot calls `exitPosition`.
2. All liquidity is unwound, swapped to USDC.
3. Dust is refunded, the earned-fee protocol fee is charged on collected pending fees, and bot fee is paid if bot.
4. Active referred capital is debited by the remaining `totalDepositedUSDC`, then the position is deregistered. For direct bot exits on EZWrapper-owned wrapper positions, EZWrapper forwards proceeds to the mapped user and removes the key from user-key tracking.

---

## 8. Security and Auditability

- All value flows are logged via events for auditability.
- Protocol and bot fees are capped and can only be changed by the Gnosis Safe multisig.
- Referral balances are claimed through `ReferralManager`; EZWrapper forwards direct bot action proceeds to mapped users.
