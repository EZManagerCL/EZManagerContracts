
# BOTS: Automation, Permissioning, and Fee Logic

This document provides a deep technical walkthrough of the bot automation system in EZManager, covering bot permissioning, fee logic, event and error references, security, and practical examples.

---

## Trust Assumptions

Bots are permissioned automation actors controlled by the protocol owner. See `TRUST_ASSUMPTIONS.md` for the canonical, project-wide trust model. Key points summarized here:

- The owner multisig (Timelock/Gnosis Safe) is the only actor that may add or remove addresses from `CLCore.allowedBots`.
- A bot can only operate on a position when it is both globally allowlisted and the position `botAllowed` flag is `true` (position owner opt-in).

---

## 1. Purpose and Architecture

Bots are whitelisted addresses that can perform privileged actions on behalf of users or the protocol. They enable automated maintenance, fee compounding, range management, and other flows that benefit from off-chain automation.

**Responsibilities:**
- Perform eligible actions for users (exit, collect, compound, changeRange)
- Receive bot fee for automation
- Ensure all actions are permissioned and logged

---

## 2. Bot Permissioning and Registration

### 2.1. Registration
- Only the protocol owner (Timelock/Gnosis Safe multisig) can add or remove bots
- Bots are tracked in `CLCore.allowedBots`
- All changes are logged via `AllowedBotUpdated` event

### 2.2. Permissioned Actions and Per-Position Allow Flag
- Whitelisting is two-layered: a bot must be globally allowlisted *and* the position must explicitly permit bots.

- Per-position flag: `CLCore.Position` contains `bool botAllowed`. New positions default to `false` when registered. A bot may act on a position only when both:
  1. `CLCore.allowedBots(botAddress) == true` (global allowlist), and
  2. `position.botAllowed == true` (per-position flag).

- Position owners can toggle this per-position permission via the owner-only manager API:
```solidity
function allowBotForPosition(bytes32 key, bool allowed) external onlyKeyOwner
```
This calls `CLCore.setBotAllowedForPosition(bytes32,bool)` and emits `BotAllowedForPositionUpdated`.

- Permissioned actions (bots granted both global + per-position permission) include:
  - `exitPosition`
  - `collectFeesToUSDC`
  - `compoundFees`
  - `changeRange`

- Enforcement: Some functions use the `onlyKeyOwnerOrBot` modifier (which checks both global and per-position settings via `CORE.getPosition(key)`), while others (batch operations) perform equivalent inline checks; the effective requirement is the same in all bot-aware flows.

---

## 3. Bot Fee Logic

### 3.1. Fee Structure
- **protocolFeeBps** (default 0.4%) is charged on certain owner-initiated flows (open, addCollateral, changeRange) and is sent to the protocol reserve.
- **botFeeBps** (default 0.2%) is paid to the bot address for eligible actions. Bot fees are additive to protocol fees where applicable; `changeRange` takes a single combined fee and splits it between reserve and bot when the caller is a bot.
- Fee bases are flow-specific:
  - `exitPosition`: a percentage of realized USDC proceeds excluding any dust refunded from `CLCore`.
  - `collectFeesToUSDC`: a percentage of the USDC produced by swapping collected fees.
  - `compoundFees`: a percentage of the USDC-equivalent value of the fee tokens collected for that compound operation; funded by swapping a portion of those fee tokens to USDC and transferring it to the bot (principal is not used).
- Bot fee is capped at 1% (enforced in `setBotFeeBps`)

Fee-exemption note:
- Fee exemptions (`CLCore.zeroFeeWallets`) are evaluated against the position owner for position flows, so a bot calling on behalf of a zero-fee owner does not get paid bot fees for that owner’s position.

### 3.2. Eligible Actions
- `exitPosition`: Bot receives fee from USDC proceeds
- `collectFeesToUSDC`: Bot receives fee from collected USDC
- `compoundFees`: Bot receives fee from compounded notional
- `changeRange`: Protocol fee is always applied; if a bot calls this action the bot receives an additional bot fee on top of the protocol fee being sent to reserve (additive).

### 3.3. Fee Enforcement
- Bot fee configuration (bps and caps) is maintained in `CLCore`, while fee assessment and transfers are enforced by `CLManager` during bot-initiated flows.
- Bot fee is always transferred before user receives proceeds
- All bot fee transfers are logged via `BotFeePaid` event

---

## 4. Security and Best Practices

- Only the protocol owner (Timelock/Gnosis Safe multisig) can add or remove bots
- All bot actions are permissioned and logged via events
- Bot fee is capped and can only be changed by the Timelock/Gnosis Safe multisig

---
