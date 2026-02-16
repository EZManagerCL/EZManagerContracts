

# Canonical Accounting in EZManager

This document provides a comprehensive, code-accurate reference for all accounting flows, value calculations, and fee logic in the EZManager protocol. All values are denominated in USDC unless otherwise noted.

---

## 1. Overview

EZManager’s accounting is designed for deterministic and auditable management of concentrated liquidity positions across multiple DEXs. All user and protocol value flows are tracked in USDC, with canonical state held in `CLCore`.


**Key contracts:**
- `CLCore`: Canonical state, position registry, and value logic
- `CLManager`: User entrypoint, fee enforcement, and event emission
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

---

## 3. Fee Logic

### 3.1. Protocol Fee

- **protocolFeeBps** (default 0.4%) is charged on position open, addCollateral, and changeRange.
- Fee is sent to `ProtocolReserve` and does **not** reduce `totalDepositedUSDC`.
- The position owner's principal (`totalDepositedUSDC`) is always the gross amount supplied, from the user's wallet into the protocol.

#### Example
If a user supplies 10,000 USDC and protocolFeeBps is 40 (0.4%):

	protocolFee = 10,000 * 0.004 = 40 USDC
	totalDepositedUSDC = 10,000 USDC
	40 USDC sent to ProtocolReserve

### 3.2. Bot Fee

- **botFeeBps** (default 0.2%) is paid to whitelisted bots for eligible actions (bot-initiated exit, collect, compound, changeRange).
- Bot fee bases are flow-specific:
  - `exitPosition`: a percentage of realized USDC proceeds excluding any dust refunded from `CLCore`.
  - `collectFeesToUSDC`: a percentage of `outUSDC` produced by swapping collected fees.
  - `compoundFees`: a percentage of the USDC-equivalent value of the fee tokens collected for that compound operation; funded by swapping a portion of those fee tokens to USDC and transferring it to the bot (principal is not used).
- Bot fee is capped at 1% (enforced in `setBotFeeBps`).
- For flows that also charge a protocol fee to the protocol reserve (`changeRange`), the manager withdraws a single combined fee and splits it between protocol reserve and bot (when caller is a bot). In other bot flows (`collectFeesToUSDC`, `compoundFees`, `exitPosition`) the protocol fee is not charged, so only the bot fee is applied when the caller is a bot.


### 3.3. Fee Enforcement

- Fee configuration is maintained in `CLCore`, while fee assessment and transfers are enforced by `CLManager`.
- Protocol and bot fees are always transferred before the user receives proceeds.
- All fee transfers are logged via events (`ProtocolFeePaid`, `BotFeePaid`).

Fee-exemption note:
- Fee exemptions (`CLCore.zeroFeeWallets`) are evaluated against the position owner for position flows.

---

## 4. Collateral Flows

### 4.1. Adding Collateral

- Increases `totalDepositedUSDC` by the gross USDC supplied.
- Protocol fee is charged and sent to reserve.
- Any leftover is tracked as dust.

#### Code Reference
```solidity
function adjustTotalDeposited(bytes32 key, int256 usdcDelta) external onlyManager { ... }
```

### 4.2. Removing Collateral

- Uses tracked dust first; any remaining target withdraw burns liquidity proportionally via the adapter.
- Guardrails: reverts if canonical `positionValueUSDC` is zero (`PositionValueZero`) or if the request would leave < MINIMUM_OPEN_USDC (`TooMuchWithdraw`).
- Burn sizing uses a quote (via `_quotedPositionValue`) to compute the withdrawal fraction, while caps and accounting rely on canonical core value (`positionValueUSDC`). The live quote uses adapter-side routing + TWAP expected-out logic (`ICLDexAdapter.getExpectedOutUSDC`, fee-adjusted TWAP output), not a spot quoter.
- Reduces `totalDepositedUSDC` by the measured drop in value (before vs. after burn), not simply the requested amount.
- USDC is transferred to the position owner;

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
- To track pending fees, use `pendingFees` and only include them in value after collection.
- For full accounting, monitor all relevant events and cross-check with on-chain state.

---

## 7. Example Flows

### 7.1. Open Position
1. User calls `openPosition` on `CLManager` with pool address, ticks, USDC amount, and slippageBps. The manager enforces both the dex and pool allowlists before any approvals or external calls.
2. Protocol fee is deducted and sent to reserve.
3. Adapter mints position, any leftover is tracked as dust.
4. Position is registered in `CLCore` with full `totalDepositedUSDC`.

### 7.2. Add Collateral
1. User calls `addCollateral`.
2. Protocol fee is deducted, rest is added to position.
3. `totalDepositedUSDC` is increased by gross supplied.

### 7.3. Remove Collateral
1. User calls `removeCollateral`.
2. USDC is returned, `totalDepositedUSDC` is reduced by value drop.

### 7.4. Collect Fees
1. User or bot calls `collectFeesToUSDC`.
2. Fees are swapped to USDC, bot fee is paid if bot.
3. USDC is transferred to owner.

### 7.5. Exit Position
1. User or bot calls `exitPosition`.
2. All liquidity is unwound, swapped to USDC.
3. Dust is refunded, bot fee is paid if bot.
4. Position is deregistered.

---

## 8. Security and Auditability

- All value flows are logged via events for auditability.
- Protocol and bot fees are capped and can only be changed by the Gnosis Safe multisig.
