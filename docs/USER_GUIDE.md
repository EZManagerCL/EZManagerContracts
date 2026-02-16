

# User Guide: EZManager Protocol

This guide provides a comprehensive, descriptive walkthrough for all user and bot interactions with the EZManager protocol. It details every major flow, permissioning, and integration as implemented.

---

## 1. Getting Started

### 1.1. Prerequisites
- USDC tokens (ERC20, 6 decimals)
- Supported wallet (EOA or contract)
- Familiarity with Uniswap V3, Aerodrome, or PancakeSwap pools
- Access to the deployed `CLManager` and `CLCore` contract addresses

### 1.2. Key Contracts
- `CLManager`: User entrypoint for all position management
- `CLCore`: Canonical state and accounting
- `ProtocolReserve`: Protocol fee storage
- `Valuation`: On-chain price oracle

---

## 2. Opening a Position

### 2.1. Flow Overview
1. User approves USDC to `CLManager`.
2. User calls `openPosition` with:
	- Pool address (tokens/fee inferred from the pool)
	- tickLower, tickUpper (range)
	- USDC amount
	- slippageBps (basis points)
3. CLManager checks both the DEX adapter allowlist (to derive dex adapter for pool) and the CLCore `allowedPools` registry before any token approvals or external calls. It will only proceed if a pool is set to Allowed (will revert on Deprecated and NotAllowed).
4. Protocol fee is deducted and sent to `ProtocolReserve`.
5. Adapter mints a new LP NFT and provides liquidity.
6. Any leftover USDC is tracked as dust in `CLCore`.
7. Position is registered in `CLCore` with full metadata.
8. `PositionOpened` event is emitted.

### 2.2. Example
```solidity
CLManager.openPosition(
	address pool,
	int24 tickLower,
	int24 tickUpper,
	uint256 usdcAmount,
	uint256 slippageBps
)
```

---

## 3. Managing Collateral

### 3.1. Adding Collateral
1. User approves USDC to `CLManager`.
2. User calls `addCollateral` with position key, USDC amount, and slippageBps.
3. Protocol fee is deducted and sent to reserve.
4. Adapter increases liquidity in the pool.
5. `totalDepositedUSDC` is increased by gross supplied.
6. `CollateralAdded` event is emitted.

### 3.2. Removing Collateral
1. User calls `removeCollateral` with position key and USDC amount.
2. Adapter burns a fraction of liquidity and returns USDC.
3. `totalDepositedUSDC` is reduced by the measured drop in value.
4. `CollateralRemoved` event is emitted.

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
4. Any protocol or bot fees are enforced.
5. `RangeChanged` event is emitted.

### 4.2. Example
```solidity
CLManager.changeRange(bytes32 key, int24 newTickLower, int24 newTickUpper, uint256 slippageBps);
```

---

## 5. Fee Management

### 5.1. Collecting Fees
1. User or bot calls `collectFeesToUSDC` with position keys and slippageBps (batch; capped by `MAX_BATCH_KEYS`).
2. Adapter collects all pending fees, swaps to USDC.
3. Bot fee is paid if called by a whitelisted bot.
4. USDC is transferred to the owner.
5. `FeesCollected` and `BotFeePaid` events are emitted.

### 5.2. Compounding Fees
1. User or bot calls `compoundFees` with position keys and slippageBps (batch; capped by `MAX_BATCH_KEYS`).
2. Fees are collected to tokens and added back into liquidity via the adapter.
3. Bot fee is paid if called by a bot.
4. `FeesCompounded` and `BotFeePaid` events are emitted.

### 5.3. Example
```solidity
CLManager.collectFeesToUSDC(bytes32[] keys, uint256 slippageBps);
CLManager.compoundFees(bytes32[] keys, uint256 slippageBps);
```

---

## 6. Exiting a Position

### 6.1. Flow
1. User or bot calls `exitPosition` with position key and slippageBps.
2. Adapter unwinds all liquidity, swaps to USDC.
3. Bot fee is paid if called by a bot.
4. Dust is refunded to the owner.
5. Position is deregistered in `CLCore`.
6. `PositionExited`, `DustRefunded`, and `BotFeePaid` events are emitted.

### 6.2. Example
```solidity
CLManager.exitPosition(bytes32[] calldata keys, uint256 slippageBps);
```

---

## 7. Permissions and Roles

### 7.1. Position Owner
- Only the position owner can perform most actions.
- Owner can always exit, collect, compound, add/remove collateral, and change range.

### 7.2. Bots
- Whitelisted bots (see `CLCore.allowedBots`) can perform exit, collect, compound, and changeRange for users, but only when the position owner has enabled bots for that position.
- **Per-position permission:** Each `CLCore.Position` stores `botAllowed` (defaults to `false`). A bot may act on a position only if it is globally allowlisted *and* the position's `botAllowed` flag is `true`. Position owners can toggle this via `CLManager.allowBotForPosition(bytes32 key, bool allowed)`, which emits `BotAllowedForPositionUpdated`.
- Bot fee is paid to the bot address for eligible actions.
- Funds aside from the bot fee are never sent to the bot, always directly to the position owner.

### 7.3. Protocol
 - Only the protocol owner, a Timelock/Gnosis Safe multisig, can set pool statuses, add/remove bots, and approve adapters. Changes are logged via `PoolStatusUpdated` and other on-chain events for transparency.
 - **DEX + pool registry enforcement:** Only adapters and pools tracked by `CLCore` are considered by the system. `CLManager` enforces adapter allowlist and blocks opening new positions on pools that `CLCore` marks `Deprecated`.

---

## 8. Events and Monitoring

All major actions emit standardized events for off-chain monitoring:

| Event                | Description                                      |
|----------------------|--------------------------------------------------|
| `PositionOpened`     | New position created                             |
| `PositionExited`     | Position exited and deregistered                 |
| `FeesCollected`      | Fees collected and swapped to USDC               |
| `FeesCompounded`     | Fees compounded into liquidity                   |
| `RangeChanged`       | Position range changed                           |
| `CollateralAdded`    | Collateral added to position                     |
| `CollateralRemoved`  | Collateral removed from position                 |
| `ProtocolFeePaid`    | Protocol fee paid to reserve                     |
| `BotFeePaid`         | Bot fee paid to bot address                      |
| `DustAdded`          | USDC dust credited to position                   |
| `DustRefunded`       | USDC dust withdrawn by owner                     |

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
