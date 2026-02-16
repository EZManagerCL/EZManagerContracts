# CLCore: Canonical State and Accounting

This document provides a deep technical walkthrough of the `CLCore` contract, the canonical state and accounting engine for all positions in the EZManager protocol.

---

## 1. Purpose and Architecture

`CLCore` is the single source of truth for all position metadata, value, and permissioning. It is designed for deterministic, auditable accounting.

**Responsibilities:**
- Register and deregister positions (LP NFTs)
- Track all position metadata and canonical USDC value
- Enforce protocol and bot fee configuration
- Maintain allowlists for pools, DEX adapters, and bots
- Provide view functions for off-chain monitoring and integrations

---

## 2. Data Structures

### 2.1. Position
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
    bool botAllowed; // Per-position bot permission, defaults to false
    uint48 openedAt;
    address dex;
    address pool;
}
```
- **owner**: Position owner (EOA or contract)
- **tokenId**: LP NFT id
- **token0/token1**: Underlying tokens
- **fee/tickSpacing**: Pool parameters (Uniswap/Aerodrome)
- **tickLower/tickUpper**: Range for concentrated liquidity
- **totalDepositedUSDC**: Gross USDC supplied by owner
- **dustUSDC**: Tracked leftover USDC
- **botAllowed**: Whether bots are allowed to operate on this position
- **openedAt**: Timestamp of position creation
- **dex**: Adapter address

### 2.2. RegisterParams
Used for registering new positions.

### 2.3. PositionDetails
Enriched view with live amounts, fees, and valuation.

### 2.4. Permissioning
* **Owner**: The Timelock contract. Controls all admin settings.
* **Guardian**: The Multisig. Controls `pause()` / `unpause()`.
* **Manager**: The CLManager contract. Only address allowed to mutate position state.
* **allowedDexes**: Only these adapters can be referenced by positions.
* **allowedPools**: Pools are tracked with a lifecycle status (`Allowed`, `Deprecated`, `NotAllowed`). Read-only and valuation flows treat `Allowed` and `Deprecated` as allowed for inspection, but `CLManager` will refuse to open new positions on `Deprecated` pools — use `CLCore.setPoolStatus` to manage statuses.
* **allowedBots**: Only these addresses can perform bot-aware flows.
* **bridgeTokens**: Allowed intermediate tokens (e.g., WETH) for routing USDC.
* **zeroFeeWallets**: Wallets exempt from protocol fees (e.g. testing, promotions).

---

## 3. Core Functions

### 3.1. Registering a Position
- Requires the LP NFT be owned by `CLCore`.
- Generates a unique `key` using a monotonic counter.
- Validates tick spacing, tick alignment, and tick bounds (`[-887272, 887272]`).
- Emits `PositionRegistered`.

### 3.2. Deregistering a Position
- Removes position from registry and user index.
- Emits `PositionRemoved`.

### 3.2.1. Returning a Position NFT (Emergency)
- `CLCore.returnPosition` refunds tracked dust and returns the LP NFT to the stored `owner`.
- The NFT transfer uses `safeTransferFrom`; if the owner is a contract, it must implement `IERC721Receiver` to receive the NFT.

### 3.3. Adjusting Total Deposited
- Used for add/remove collateral flows.

### 3.4. Dust Management
- Tracks leftover USDC ("dust").
- Push model: Manager transfers funds to Core before calling `addDust`.

### 3.5. Metadata Updates
- Updates NFT id and tick range after re-minting (change range) and re-validates tick alignment and bounds.

### 3.6. Permissioning & Admin (Owner/Guardian)
*   `setManager(address)`: Set the manager contract.
*   `setGuardian(address)`: Set the guardian (multisig) for emergency pause.
*   `setValuation(address) / setProtocolReserve(address)`: Configure core dependencies.
*   `addAllowedDex / removeAllowedDex`: Whitelist adapters.
*   `setPoolStatus`: Manage pool lifecycle and status (Allowed / Deprecated / NotAllowed).
*   `addBot / removeBot`: Whitelist bots.
*   `setBridgeTokens`: Configure routing tokens.
*   `setZeroFeeWallet(address, bool)`: Toggle fee exemption for specific wallets.
*   `pause() / unpause()`: Guardian-only emergency stop.

### 3.7. Fee Configuration
- Owner can set protocolFeeBps and botFeeBps up to 1% cap.

## 4. Value and Fee Logic

### 4.1. Canonical Value Calculation
- Sums USDC-equivalent of token0, token1, and dustUSDC.
- **Does not include pending fees**.

### 4.2. Pending Fees
- Returns token0/token1 fees owed but not yet collected.

---
