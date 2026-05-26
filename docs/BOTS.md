
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

- Ez-mode positions opened through EZWrapper are intentionally opened with bots enabled and cannot be toggled directly by the mapped user because EZWrapper is the registered position owner. Users who need direct per-position bot revocation should open through CLManager instead. Governance can remove a compromised bot from the global allowlist.
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
- **protocolFeeBps** (default 0.4%) is the capital-entry protocol fee charged on deposit-like flows (open, addCollateral). Normal open/add fees go to the protocol reserve; copied opens may pay a copy referral share from that fee.
- **earnedFeesProtocolFeeBps** (default 10%) is charged on realized LP fee value: fees earned when they are collected, compounded, realized during removeCollateral, moved during changeRange, or collected during exit. It excludes principal and position value moved only because the range changed.
- **botFeeBps** (deployed default 0.05%) is paid to the bot address for eligible actions.
- `collectFeesToUSDC` and `compoundFees` use `botFeeBps * botFeeMultiplierForEarnedFees` before wallet discounts. The multiplier defaults to `20` and is capped at `50`.
- CLManager wallet discounts reduce nonzero protocol and bot fee bps. A 100% discount fully exempts fees.
- Fee bases are flow-specific:
  - `exitPosition`: a percentage of realized USDC proceeds excluding any dust refunded from `CLCore`.
  - `collectFeesToUSDC`: a percentage of the USDC produced by swapping collected fees.
  - `compoundFees`: a percentage of the USDC-equivalent value of the fee tokens collected for that compound operation; funded by swapping a portion of those fee tokens to USDC and transferring it to the bot (principal is not used).
- Base bot fee is capped at 1% (enforced in `setBotFeeBps`); the collect/compound effective bot fee additionally uses the manager multiplier.

Example: with the deployed 0.05% base bot fee and default `20` collect/compound multiplier, a bot collect or bot compound pays 1% of the gross collected-fee value to the bot before wallet discounts. This uses the same gross basis as the earned-fee protocol fee, not the post-protocol-fee remainder. A 25% wallet discount on the registered position owner reduces that effective collect/compound bot fee to 0.75%. A bot exit does not use the multiplier, so it pays 0.05% of non-dust exit proceeds before discounts and 0.0375% with the same 25% wallet discount; any earned-fee protocol target is calculated separately before transfers.

Fee-exemption note:
- CLManager fee discounts are always evaluated against the registered position owner. For ez positions, the owner is EZWrapper, so the mapped user's discount does not apply.

### 3.2. Eligible Actions
- `exitPosition`: Bot receives fee from USDC proceeds
- `collectFeesToUSDC`: Bot receives fee from collected USDC
- `compoundFees`: Bot receives fee from compounded notional
- `changeRange`: No rebalance protocol fee is charged on principal; if pending earned fees exist, they are collected before the range change and the earned-fee protocol fee is split between the protocol reserve and the stored referrer when applicable. If a bot calls this action the bot also receives the base bot fee.

For changeRange, the protocol fee applies only to pending earned fees collected before the range change. A bot-called changeRange pays that earned-fee protocol fee from collected fee tokens first, then pays the proceeds from removing the base bot-fee fraction of reminted liquidity.

### 3.3. Fee Enforcement
- Bot fee configuration (bps and caps) is maintained in `CLCore`, while fee assessment and transfers are enforced by `CLManager` during bot-initiated flows.
- Bot fee is always transferred before user receives proceeds
- All bot fee transfers are logged via `BotFeePaid` event
- If a bot directly collects or exits an EZWrapper-owned wrapper position, CLManager transfers net proceeds to EZWrapper and EZWrapper forwards them to the mapped user.

---

## 4. Security and Best Practices

- Only the protocol owner (Timelock/Gnosis Safe multisig) can add or remove bots
- All bot actions are permissioned and logged via events
- Bot fee is capped and can only be changed by the Timelock/Gnosis Safe multisig

---
