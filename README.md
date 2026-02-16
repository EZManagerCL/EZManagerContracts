
# EZManager Protocol

---

## Modular Documentation Suite

This protocol is fully documented in the `docs/` directory, with deep, code-accurate markdown files for every major component and flow:

- [ACCOUNTING.md](docs/ACCOUNTING.md): Canonical USDC accounting, invariants, and flows
- [USER_GUIDE.md](docs/USER_GUIDE.md): Step-by-step user and bot flows
- [MANAGER.md](docs/MANAGER.md): Manager contract, permissioning, and flows
- [CORE.md](docs/CORE.md): CLCore contract, data structures, and accounting
- [ALLOWED_POOLS.md](docs/ALLOWED_POOLS.md): Administrative model for tracking and managing allowed pools.
- [ADAPTERS.md](docs/ADAPTERS.md): Adapter interface, DEX integration, and extension
- [ROUTING.md](docs/ROUTING.md): Describes how pools are selected for swaps/valuation.
- [REBALANCE.md](docs/REBALANCE.md): Computes optimal swap amounts for rebalancing.
- [VALUATION.md](docs/VALUATION.md): Price oracle methodology, pool selection, and TWAP
- [BOTS.md](docs/BOTS.md): Automation, bot fee logic, and permissioning
- [SECURITY.md](docs/SECURITY.md): Architecture, permissioning, and best practices
- [SLIPPAGE.md](docs/SLIPPAGE.md): Slippage budgeting rules per flow
- [EVENTS.md](docs/EVENTS.md): Event reference, field explanations, and monitoring
- [ERRORS.md](docs/ERRORS.md): Error signatures, revert reasons, and code references

---

## Table of Contents
- [Introduction](#introduction)
- [Architecture Overview](#architecture-overview)
- [Core Contracts](#core-contracts)
  - [CLCore](#clcore)
  - [CLManager](#clmanager)
  - [Adapters](#adapters)
    - [UniswapAdapter](#uniswapadapter)
    - [AerodromeAdapter](#aerodromeadapter)
  - [RebalancePlanner](#rebalanceplanner)
  - [Valuation](#valuation)
  - [ProtocolReserve](#protocolreserve)
- [Deployment and Initialization](#deployment-and-initialization)
- [User Flows](#user-flows)
  - [Opening a Position](#opening-a-position)
  - [Adding/Removing Collateral](#addingremoving-collateral)
  - [Changing Range](#changing-range)
  - [Fee Collection and Compounding](#fee-collection-and-compounding)
  - [Exiting a Position](#exiting-a-position)
- [Security](#security)
- [Events and Error Handling](#events-and-error-handling)

---

## Introduction

EZManager is a modular protocol for managing concentrated liquidity positions across multiple DEXs (Uniswap V3, Aerodrome, PancakeSwap). It provides a unified interface for users and automation bots to open, manage, rebalance, and exit positions, with canonical accounting in USDC. The protocol is designed for safety, transparency, and extensibility, supporting advanced features like fee compounding, protocol/bot fees, and robust permissioning.

## Architecture Overview

EZManager is composed of several core contracts:
- **CLCore**: Canonical state and accounting for all positions. Holder of all position NFTs and tracked dust.
- **CLManager**: User-facing contract for opening, managing, and exiting positions.
- **Adapters**: Per-DEX adapters (Uniswap/PancakeSwap, Aerodrome) that abstract DEX-specific logic.
- **RebalancePlanner**: Computes optimal swap amounts for rebalancing.
- **Valuation**: Provides USDC-equivalent valuation for any token using DEX pools.
- **ProtocolReserve**: Stores and distributes protocol fees to shareholders.

## Core Contracts

### CLCore

**Purpose:**
- Holds all position NFTs and tracked USDC dust.
- Tracks all positions, their metadata, and canonical USDC accounting.
 - Maintains allowlists for DEX adapters and bots, and a lifecycle-tracked `allowedPools` registry for pools. Pools in `allowedPools` have a status (`Allowed`, `Deprecated`, `NotAllowed`); `CLCore.isPoolAllowed` returns true for `Allowed` and `Deprecated` pools (so valuation and other read-only flows continue), while `CLManager` will refuse to open new positions on `Deprecated` pools via `CLCore.isPoolDeprecated`.
- Provides view functions for position details, value, and pending fees.
- Handles protocol and bot fee configuration.

**Key Data Structures:**
- `Position`: Main position data.
- `RegisterParams`: Used for registering new positions.
- `PositionDetails`: Enriched view with live amounts, fees, and valuation.

**Key Functions:**
- `registerPosition`, `deregisterPosition`, `updateTokenMetadata`, `adjustTotalDeposited`
- `addDustToPosition`, `withdrawDustForPosition`
- `getPositionDetails`, `positionValueUSDC`, `pendingFees`
- Permissioning / allowlists: `setManager`, `addBot`, `removeBot`, `setPoolStatus`, `addAllowedDex`, `removeAllowedDex`, `setBridgeTokens`  
- Fee config: `setProtocolFeeBps`, `setBotFeeBps`

**Events:**
- Position lifecycle, fee updates, admin changes

### CLManager

**Purpose:**
- User entrypoint for all position management flows.
- Handles opening, managing (range, fees, collateral, permissions) and exiting positions.
- Enforces protocol and bot fees, slippage, and permissioning.
- Restricts pairs to USDC-direct pools or bridge-token routed pairs; pools must be pre-allowlisted in CLCore.

**Key Flows:**
- `openPosition`: Opens a new position, seeds with USDC, handles protocol fee, and registers in CLCore.
- `exitPosition`: Unwinds all liquidity, swaps to USDC, refunds dust, and deregisters.
- `addCollateral`/`removeCollateral`: Adjusts position's USDC collateral.
- `collectFeesToUSDC`/`compoundFees`: Collects/compounds fees for one or more positions.
- `changeRange`: Fully unwinds and remints a position with a new tick range.

**Modifiers:**
- `onlyKeyOwner`, `onlyKeyOwnerOrBot` for permissioned actions.

**Events:**
- PositionOpened, PositionExited, FeesCollected, FeesCompounded, RangeChanged, CollateralAdded/Removed, ProtocolFeePaid, BotFeePaid

### Adapters

Adapters abstract DEX-specific logic and expose a unified interface for CLManager. Each adapter implements the `ICLDexAdapter` interface.

#### UniswapAdapter
- Integrates Uniswap V3 pools and also powers the PancakeSwap variant via an `isPancakeSwap` flag (router signature differences only).
- Handles minting, adding/removing liquidity, swaps, and fee collection.
- Uses best-liquidity pool selection and slippage protection.

#### AerodromeAdapter
- Integrates Aerodrome Slipstream pools.
- Similar to UniswapAdapter but uses tickSpacing instead of fee.
- Handles minting, adding/removing liquidity, swaps, and fee collection.

### RebalancePlanner

**Purpose:**
- Computes optimal swap amounts to balance token0/token1 for a given range.
- Expects callers to supply the actual token bundle (USDC or bridge-token paired) prior to planning.
- Uses an iterative Newton-style solver with exact V3 math (no external quoter calls).
- Adds "implicit tick walking" probes plus overshoot backtracking to stay stable across liquidity cliffs.

**Key Functions:**
- `planFromTokenBundle`: Plans rebalance from arbitrary token0/token1 amounts.

### Valuation

**Purpose:**
- View-only USDC valuation for tokens using Uniswap V3 and Aerodrome pools (via adapters).
- Uses a cached routing model anchored to connectors: USDC plus `CLCore.bridgeTokens()`.
- Selects the best route (direct when connector is involved, or a single-connector hop) based on a bottleneck pool TVL measured in USDC.
- Price inputs are TWAP-based (short, configurable window) derived from pool sqrt-price TWAPs and deterministic V3 math — no external quoter reliance.
- Cache population (`refreshAll`) is owner-only and best-effort: it scans `CLCore.listAllowedPools()` to derive supported non-connector tokens, discovers per-factory edge candidates, skips pools that cannot be scored (for example, due to failed TWAP observations, out-of-range ticks, missing connector→USDC anchors, or zero active liquidity), and emits `RefreshFailed(pool, reason)` for those failures to be monitored. At runtime, `usdcValue` and `getBestRoute` revert if no viable cached route exists.

**Key Functions:**
- `usdcValue(dex, token, amount)` — view function that returns a USDC-equivalent value using the best cached route and TWAP; may return 0 for extremely small amounts; reverts if dex is not allowed or no viable cached route exists.
- `getBestRoute(dex, tokenIn, tokenOut)` — returns (poolA, poolB, scoreUSDC) for the best cached route (direct or 1-connector hop); requires CORE set and dex approved by CLCore.
- `setTWAPSeconds(seconds)` — admin: adjust the TWAP window used for price derivation.
- `setCore(core)` — admin: configure CORE (one-time).
- `refreshAll()` — owner-only: refresh cached edges from `CLCore.listAllowedPools()` (best-effort; emits `Refreshed` and `RefreshFailed`).

### ProtocolReserve

**Purpose:**
- Stores protocol fees in USDC.
- Allows owner to set share recipients and sweep reserves.

**Key Functions:**
- `setShares`, `sweepReserves`, `usdcBalance`, `getShares`

## Deployment and Initialization

Deployment is managed by the `Deploy.sol` script, which:
- Deploys all core contracts and adapters (Uniswap, Aerodrome, PancakeSwap via the UniswapAdapter variant).
- Wires permissions, connects contracts, and sets initial allowlists. After setup, transfers ownership to timelock with multisig as proposer.
- Persists deployed addresses to `addresses.json`.

## User Flows

### Opening a Position
1. User calls `openPosition` on `CLManager` with pool address, DEX adapter, tick range, USDC amount, and slippage.
2. Protocol fee is deducted and sent to `ProtocolReserve`.
3. Adapter mints a new position and transfers the NFT to `CLCore`.
4. `CLCore.registerPosition` verifies it owns the NFT (`ownerOf(tokenId) == CLCore`) before registering with full metadata and totalDepositedUSDC.
5. Any leftover USDC after mint is tracked as dust.

### Adding/Removing Collateral
- **Add:** User calls `addCollateral`, which increases totalDepositedUSDC and adds liquidity via the adapter.
- **Remove:** User calls `removeCollateral`, which burns a fraction of liquidity and returns USDC, reducing totalDepositedUSDC.

### Changing Range
- User or bot calls `changeRange` to fully unwind and remint a position with a new tick range.
- Protocol or bot fee is applied as appropriate on the total value of the newly minted position.

### Fee Collection and Compounding
- **Collect:** Owner or bot calls `collectFeesToUSDC` (batch) to collect fees, swap them to USDC, and transfer proceeds to the owner (bot receives a fee share when the caller is a bot).
- **Compound:** Owner or bot calls `compoundFees` (batch) to collect fees to tokens and add them back into liquidity (bot receives a fee share when the caller is a bot; the fee is derived from the collected fees and does not use principal).

### Exiting a Position
- Owner or bot calls `exitPosition` to unwind all liquidity, swap to USDC, refund dust, and deregister the position.
- Bot receives a fee cut on total value removed if caller was bot.

## Security

- Permissioning is enforced for all sensitive actions (`onlyOwner`, `onlyGuardian`, `onlyManager`, `onlyKeyOwner`, `onlyKeyOwnerOrBot`).
- Pausable pattern is used for emergency stops. Guardian (multisig) can call this instantly for quick exploit mitigation.
- All major contracts are owned by a timelock contract, so all admin functions aside from pause are subject to a minimum 2 day timelock.
- In case of emergency, even when paused, users can withdraw their position NFTs from the protocol. Timelock owner can also send position NFTs to their key owners in case of unrecoverable exploit and necessary contract migration.
- Slippage protection is enforced via on-chain TWAP oracles.
- Users only ever directly interact with CLManager, which interacts with other contracts.

## Events and Error Handling

- All major actions emit detailed events for transparency and off-chain indexing/accounting. See [EVENTS.md](docs/EVENTS.md) for a full event reference and monitoring guidance.
- Custom errors are used for gas efficiency and clarity. See [ERRORS.md](docs/ERRORS.md) for a comprehensive error signature and revert reason reference.
- All revert reasons are descriptive and consistent across contracts.

---
