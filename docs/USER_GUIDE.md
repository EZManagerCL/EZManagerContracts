

# User Guide: EZManager Protocol

This guide provides a comprehensive, descriptive walkthrough for all user and bot interactions with the EZManager protocol. It details every major flow, permissioning, and integration as implemented.

---

## 1. Getting Started

### 1.1. Prerequisites
- USDC tokens (ERC20, 6 decimals)
- Supported wallet (EOA or contract)
- Familiarity with Uniswap V3, Aerodrome, or PancakeSwap pools
- Access to the deployed `CLManager` and `CLCore` contract addresses
- Optional access to `EZWrapper` for ez flows

### 1.2. Key Contracts
- `CLManager`: Main user entrypoint for position management
- `EZWrapper`: Optional wrapper for ez opens/adds/removes/exits and forwarded wrapper proceeds
- `ReferralManager`: Persistent referral registry and claimable referral balances
- `CLCore`: Canonical state and accounting
- `Valuation`: On-chain price oracle

---

## 2. Opening a Position

### 2.1. Flow Overview
1. User approves USDC to `CLManager`.
2. User calls `openPosition` with:
	- Pool address (tokens/fee inferred from the pool)
	- tickLower, tickUpper (range)
	- USDC amount
	- botAllowed
	- slippageBps (basis points)
	- optional candidate referrer when using the referral overload
3. The configured EZWrapper calls `openPositionEz` for ez opens.
4. CLManager checks both the DEX adapter allowlist (to derive dex adapter for pool) and the CLCore `allowedPools` registry before any token approvals or external calls. It will only proceed if a pool is set to Allowed (will revert on Deprecated and NotAllowed).
5. Capital-entry protocol fee is deducted and sent to `ProtocolReserve`. CLManager resolves and stores the user's wallet referrer for later referral attribution.
6. Adapter mints a new LP NFT and provides liquidity.
7. Any leftover USDC is tracked as dust in `CLCore`.
8. Position is registered in `CLCore` with full metadata.
9. `PositionOpened` event is emitted.

### 2.2. Importing an Existing LP NFT
1. User approves the LP NFT to `CLManager`.
2. User calls `importNft(tokenId, pool, botAllowed)` or `importNft(tokenId, pool, botAllowed, referrer)`.
3. CLManager validates the pool, resolves the DEX adapter, and checks that the NFT metadata matches the supplied pool.
4. CLManager initializes the user's stored referrer through ReferralManager when one is not already set.
5. The NFT is transferred to `CLCore` and registered to the caller.
6. No protocol or referral fee is charged on import.
7. Initial deposited accounting is set from the current principal position value, excluding pending fees.
8. The imported position uses the supplied `botAllowed` setting.
9. `PositionImported` event is emitted.

### 2.3. Example
```solidity
CLManager.openPosition(
	address pool,
	int24 tickLower,
	int24 tickUpper,
	uint256 usdcAmount,
	bool botAllowed,
	uint256 slippageBps
)
```

---

## 3. Managing Collateral

### 3.1. Adding Collateral
1. User approves USDC to `CLManager`.
2. User calls `addCollateral` with position key, USDC amount, and slippageBps.
3. Capital-entry protocol fee is deducted and sent to `ProtocolReserve`. If no wallet referrer is stored, `CLManager` stores and uses the default referrer.
4. Adapter increases liquidity in the pool.
5. `totalDepositedUSDC` is increased by gross supplied.
6. `CollateralAdded` event is emitted.

### 3.2. Removing Collateral
1. User calls `removeCollateral` with position key and USDC amount.
2. Adapter burns a fraction of liquidity and returns USDC.
3. If the burn realizes pending LP fees, `earnedFeesProtocolFeeBps` is charged only on that realized fee value.
4. `totalDepositedUSDC` is reduced by the measured drop in value, capped at the position's current deposited accounting.
5. `CollateralRemoved` and, when applicable, `ProtocolFeePaid` events are emitted.

### 3.3. Example
```solidity
CLManager.addCollateral(bytes32 key, uint256 usdcAmount, uint256 slippageBps);
CLManager.removeCollateral(bytes32 key, uint256 usdcAmount, uint256 slippageBps);
```

---

## 4. Changing Range

### 4.1. Flow
1. User or bot calls `changeRange` with new tickLower/tickUpper and slippageBps.
2. Adapter fully unwinds the position, collects all assets.
3. Adapter remints a new position with the new range.
4. No protocol fee is charged on principal or full position value. If pending earned fees exist, they are collected before the range change, and `earnedFeesProtocolFeeBps` is charged on those collected fees and split between ProtocolReserve and the stored referrer when applicable.
5. If a whitelisted bot calls the action, the bot fee uses `botFeeBps` with any wallet discount for the registered position owner. The collect/compound multiplier does not apply to changeRange.
6. If a whitelisted bot calls the action, the manager removes a bot-fee slice from the reminted NFT and pays the bot.
7. `RangeChanged` event is emitted.

### 4.2. Example
```solidity
CLManager.changeRange(bytes32 key, int24 newTickLower, int24 newTickUpper, uint256 slippageBps);
```

With the deployed defaults, a direct owner changeRange pays no rebalance fee on principal. Pending earned fees are collected before the range change and pay the default 10% earned-fee protocol fee before wallet-specific discounts. If a bot performs the same changeRange, the manager separately removes the default base bot-fee fraction of the reminted liquidity and pays the realized USDC proceeds to the bot.

---

## 5. Fee Management

### 5.1. Collecting Fees
1. User or bot calls `collectFeesToUSDC` with position keys and slippageBps (batch; capped by `MAX_BATCH_KEYS`).
2. Adapter collects all pending fees, swaps to USDC.
3. The earned-fee protocol fee is split between ProtocolReserve and the stored referrer when applicable. The default is 10% before wallet-specific discounts.
4. Bot fee is paid if called by a whitelisted bot. Collect bot fees use the same gross collected-USDC basis as the protocol fee, with `botFeeBps * botFeeMultiplierForEarnedFees` before wallet discounts.
5. Net USDC is transferred to the owner.
6. `FeesCollected`, `ProtocolFeePaid`, and `BotFeePaid` events are emitted.

For EZWrapper-owned wrapper positions, direct bot collects are forwarded by EZWrapper to the mapped user.

### 5.2. Compounding Fees
1. User or bot calls `compoundFees` with position keys and slippageBps (batch; capped by `MAX_BATCH_KEYS`).
2. Fees are collected to tokens and added back into liquidity via the adapter.
3. The earned-fee protocol fee is funded from collected fee tokens and split between ProtocolReserve and the stored referrer when applicable. The default is 10% before wallet-specific discounts.
4. Bot fee is paid if called by a bot. Compound bot fees use the same gross collected-fee-token value as the protocol fee, with `botFeeBps * botFeeMultiplierForEarnedFees` before wallet discounts.
5. `FeesCompounded`, `ProtocolFeePaid`, and `BotFeePaid` events are emitted.

### 5.3. Example
```solidity
CLManager.collectFeesToUSDC(bytes32[] keys, uint256 slippageBps);
CLManager.compoundFees(bytes32[] keys, uint256 slippageBps);
```

With the deployed defaults, collect and compound bot actions use the 0.05% base bot fee multiplied by the default `20` multiplier, so the effective bot fee is 1% of the same gross basis used for the earned-fee protocol fee before wallet-specific discounts. If a position owner has a 25% CLManager wallet discount, the effective collect/compound bot fee is 0.75%. For EZWrapper-owned positions, discounts are evaluated against EZWrapper as the registered owner, not the mapped user.

---

## 6. Exiting a Position

### 6.1. Flow
1. User or bot calls `exitPosition` with position keys and slippageBps.
2. Adapter unwinds all liquidity, swaps to USDC.
3. Bot fee is paid if called by a bot. Exit uses `botFeeBps` directly on non-dust exit proceeds, with wallet discounts, and does not use the collect/compound multiplier. If pending fees are collected during exit, the earned-fee protocol target and bot target are calculated before either fee is transferred.
4. Dust is refunded to the owner.
5. Position is deregistered in `CLCore`.
6. `PositionExited`, `DustRefunded`, `ProtocolFeePaid`, and `BotFeePaid` events are emitted when applicable.

For EZWrapper-owned wrapper positions, direct bot exits are forwarded by EZWrapper to the mapped user.

### 6.2. Example
```solidity
CLManager.exitPosition(bytes32[] keys, uint256 slippageBps);
```

---

## 7. Permissions and Roles

### 7.1. Position Owner
- Only the position owner can perform most actions.
- Owner can always exit, collect, compound, add/remove collateral, and change range.

### 7.2. Bots
- Whitelisted bots (see `CLCore.allowedBots`) can perform exit, collect, compound, and changeRange for users, but only when the position owner has enabled bots for that position.
- **Per-position permission:** Each `CLCore.Position` stores `botAllowed` (defaults to `false`). A bot may act on a position only if it is globally allowlisted *and* the position's `botAllowed` flag is `true`. Position owners can toggle this via `CLManager.allowBotForPosition(bytes32 key, bool allowed)`, which emits `BotAllowedForPositionUpdated`.
- Bot fee is paid to the bot address for eligible actions. Collect and compound use the collect/compound multiplier; exit and changeRange use the base bot fee.
- CLManager fee discounts are always evaluated against the registered position owner. A 100% discount fully exempts fees. For ez positions, the owner is EZWrapper, so the mapped user's discount does not apply.
- Funds aside from the bot fee are never sent to the bot. Directly owned positions receive proceeds at the position owner address; wrapper-owned positions receive proceeds through EZWrapper, which forwards them to the mapped user.

### 7.3. EZWrapper Users
- `ezOpen` opens wrapper-owned positions with bots enabled and stores the returned key for the caller.
- Ez mode intentionally gives enabled bots control over wrapper-owned positions. Users who need per-position bot revocation should use direct CLManager opens instead; governance can remove compromised bots from the global allowlist.
- `ezAdd`, `ezRemove`, and `ezExit` only work for the user mapped to the stored key.
- `ezReturnNft` lets the mapped user emergency-return a wrapper-owned LP NFT through CLManager and receive the NFT plus any tracked dust.
- `copyPosition` is exposed by CLManager. It copies another position's pool and range, but the copied position is owned directly by the caller and is not stored as an ez position. The copied/source position owner receives a source reward funded from the copied open's capital-entry protocol fee using `ReferralManager.copyReferralShareBps`. If the caller has no stored referrer, that source owner is also stored as the caller's wallet referrer for later non-copy actions.
- Referral fees are claimed through ReferralManager. Direct bot action proceeds for wrapper-owned positions are forwarded through EZWrapper.

### 7.4. Referrers
- Referral fees are paid from existing protocol fees; users do not pay an additional fee when a referral applies.
- The default earned-fee referral share is 20% of the earned-fee protocol fee.
- The default copy referral share is 50% of the capital-entry protocol fee charged on a copied open.
- Assigned wallet count is exposed separately through `ReferralManager.referrerUserCount` for UI/display and does not affect payouts.
- Referrers claim accrued USDC from `ReferralManager.claimReferralFees`.

### 7.5. Protocol
 - Only the protocol owner, a Timelock/Gnosis Safe multisig, can set pool statuses, add/remove bots, and approve adapters. Changes are logged via `PoolStatusUpdated` and other on-chain events for transparency.
 - **DEX + pool registry enforcement:** Only adapters and pools tracked by `CLCore` are considered by the system. `CLManager` enforces adapter allowlist and blocks opening new positions on pools that `CLCore` marks `Deprecated`.

---

## 8. Events and Monitoring

All major actions emit standardized events for off-chain monitoring:

| Event                       | Description                                      |
|-----------------------------|--------------------------------------------------|
| `PositionOpened`            | New position created                             |
| `PositionImported`          | Existing LP NFT imported into CLCore tracking    |
| `PositionExited`            | Position exited and deregistered                 |
| `FeesCollected`             | Fees collected and swapped to USDC               |
| `FeesCompounded`            | Fees compounded into liquidity                   |
| `RangeChanged`              | Position range changed                           |
| `CollateralAdded`           | Collateral added to position                     |
| `CollateralRemoved`         | Collateral removed from position                 |
| `ProtocolFeePaid`           | Protocol reserve fee paid                        |
| `BotFeePaid`                | Bot fee paid to bot address                      |
| `PositionCopied`            | Source position pool/range copied for a caller   |
| `DustAdded`                 | USDC dust credited to position                   |
| `DustRefunded`              | USDC dust withdrawn by owner                     |
| `EzPositionOpened`          | Wrapper-owned position opened for a user         |
| `EzNftReturned`             | Wrapper-owned LP NFT returned to the mapped user |
| `ReferralFeePaid`           | Referral fee credited from an applicable protocol fee |
| `ReferralFeeAccrued`        | Nonzero referral balance credit recorded |
| `ReferralFeesClaimed`       | Referral balance claimed                               |
| `BotActionProceedsForwarded` | Direct bot action proceeds forwarded by EZWrapper |

Note: `DustAdded` and `DustRefunded` are emitted by `CLCore` when the manager pushes or refunds dust; the user flows above surface them alongside CLManager events for completeness.

---

## 9. Example User Flows

### Open, Compound, and Exit
```solidity
// Approve USDC to CLManager
USDC.approve(address(CLManager), 10_000e6);

// Open a new position
bytes32 key = CLManager.openPosition(...);

bytes32[] memory keys = new bytes32[](1);
keys[0] = key;

// Compound fees
CLManager.compoundFees(keys, 50); // example slippageBps

// Exit position
CLManager.exitPosition(keys, 50); // example slippageBps
```

---


## 10. Off-Chain Integration

- All major protocol actions emit standardized events, which can be monitored for real-time accounting and automation by users, auditors, and bots.
- `CLCore.positionValueUSDC` provides the canonical position value.
- `CLCore.pendingFees` tracks uncollected fees for each position.
- `CLCore.positions(key)` exposes full position metadata on-chain (or use `CLCore.getPosition(key)` to retrieve the `Position` struct).

---


## 11. Protocol Security and Operations

- All critical protocol configuration actions are performed by the Timelock/Gnosis Safe multisig.
- Only whitelisted DEX adapters and bots, as managed by the multisig, are permitted for user flows.
- All user and bot actions are subject to the permissioning and event logging described in the protocol contracts.

---
