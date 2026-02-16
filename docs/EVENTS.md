# Events Reference: Protocol Transparency and Monitoring

This document provides a deep technical walkthrough of all standardized events emitted by the protocol, including event signatures, field explanations, off-chain monitoring guidance, and practical examples.

---

## 1. CLCore Events

| Event | Signature & Fields | Description |
|---|---|---|
| `PositionRegistered` | event PositionRegistered(address indexed owner, bytes32 indexed key, uint256 tokenId) | New position registered |
| `PositionRemoved` | event PositionRemoved(address indexed owner, bytes32 indexed key, uint256 tokenId) | Position deregistered |
| `PositionUpdated` | event PositionUpdated(bytes32 indexed key, uint256 oldTokenId, uint256 newTokenId, int24 oldLower, int24 oldUpper) | NFT id or tick range updated |
| `ManagerUpdated` | event ManagerUpdated(address indexed manager) | Manager address changed |
| `AllowedDexUpdated` | event AllowedDexUpdated(address indexed dex, bool allowed) | DEX adapter allowlist changed |
| `AllowedBotUpdated` | event AllowedBotUpdated(address indexed bot, bool allowed) | Bot allowlist changed |
| `PoolStatusUpdated` | event PoolStatusUpdated(address indexed pool, PoolStatus status) | Pool lifecycle status updated (Allowed / Deprecated / NotAllowed) |
| `ProtocolFeeUpdated` | event ProtocolFeeUpdated(uint16 oldBps, uint16 newBps) | Protocol fee changed |
| `BotFeeUpdated` | event BotFeeUpdated(uint16 oldBps, uint16 newBps) | Bot fee changed |
| `DustAdded` | event DustAdded(address indexed owner, bytes32 indexed key, uint256 amount, uint256 timestamp) | USDC dust credited to position (emitted by CLCore) |
| `DustRefunded` | event DustRefunded(address indexed owner, bytes32 indexed key, uint256 amount, uint256 timestamp) | USDC dust withdrawn by owner (emitted by CLCore) |
| `TotalDepositedUpdated` | event TotalDepositedUpdated(bytes32 indexed key, int256 delta, uint256 currentValue, uint256 timestamp) | Collateral/principal changed (emitted by CLCore) |
| `BotAllowedForPositionUpdated` | event BotAllowedForPositionUpdated(bytes32 indexed key, bool allowed) | Per-position bot permission toggled |
| `BridgeTokensUpdated` | event BridgeTokensUpdated(address[] bridges) | List of bridge tokens updated |
| `ZeroFeeWalletUpdated` | event ZeroFeeWalletUpdated(address indexed wallet, bool isZeroFee) | Fee exemption status changed for a wallet |

---

## 2. CLManager Events

| Event | Signature & Fields | Description |
|---|---|---|
| `PositionOpened` | event PositionOpened(address indexed user, bytes32 indexed key, uint256 indexed tokenId, address dex, address pool, address token0, address token1, uint256 depositedUSDC, uint256 protocolFeeUSDC, uint256 dustAdded) | New position created |
| `PositionExited` | event PositionExited(address indexed user, bytes32 indexed key, uint256 indexed tokenId, uint256 returnedUSDC, uint256 feesCollected) | Position exited and deregistered |
| `PositionNftReturned` | event PositionNftReturned(address indexed user, bytes32 indexed key, uint256 indexed tokenId, uint256 returnedUSDC, uint256 feesCollected) | NFT returned to owner without unwinding (emergency path) |
| `FeesCollected` | event FeesCollected(address indexed user, bytes32 indexed key, uint256 indexed tokenId, uint256 fee0, uint256 fee1, uint256 usdcOut) | Fees collected and swapped to USDC (or partially collected as tokens in compound) |
| `FeesCompounded` | event FeesCompounded(address indexed user, bytes32 indexed key, uint256 indexed tokenId, uint256 compoundedUSDC, uint256 used0, uint256 used1) | Fees compounded into liquidity |
| `RangeChanged` | event RangeChanged(address indexed user, bytes32 indexed key, uint256 oldTokenId, uint256 newTokenId, int24 oldLower, int24 oldUpper, int24 newLower, int24 newUpper, uint256 positionValueBefore, uint256 positionValueAfter, uint256 protocolFeeUSDC, uint256 feesCollected) | Position range changed |
| `CollateralAdded` | event CollateralAdded(address indexed user, bytes32 indexed key, uint256 indexed tokenId, uint256 depositedUSDC, uint256 addedUSDC, uint256 totalCollateralUSDC, uint256 protocolFeeUSDC) | Collateral added to position |
| `CollateralRemoved` | event CollateralRemoved(address indexed user, bytes32 indexed key, uint256 indexed tokenId, uint256 returnedUSDC, uint256 feesCollected, uint256 removedUSDC, uint256 totalCollateralUSDC) | Collateral removed from position |
| `ProtocolFeePaid` | event ProtocolFeePaid(address indexed payer, bytes32 indexed key, uint256 tokenId, uint256 grossUSDC, uint256 feeUSDC, uint256 netUSDC, FeeType feeType) | Protocol fee paid to reserve |
| `BotFeePaid` | event BotFeePaid(address indexed bot, bytes32 indexed key, uint256 tokenId, uint256 feeUSDC, FeeType feeType) | Bot fee paid to bot address |

---

## 3. Adapter Events (Aerodrome & Uniswap)

| Event | Signature & Fields | Description |
|---|---|---|
| `ManagerUpdated` | event ManagerUpdated(address indexed who) | Manager address changed |
| `GuardianUpdated` | event GuardianUpdated(address indexed who) | Adapter guardian changed |
| `ValuationUpdated` | event ValuationUpdated(address indexed valuation) | Valuation contract updated |
| `TwapSecondsUpdated` | event TwapSecondsUpdated(uint32 twapSeconds) | Adapter TWAP window changed |
| `CoreSet` | event CoreSet(address indexed core) | CORE address set |
| `Minted` | event Minted(uint256 indexed tokenId, address token0, address token1, int24/uint24 tickSpacing/fee, int24 tickLower, int24 tickUpper, uint256 used0, uint256 used1, uint256 leftoverUSDC) | New LP NFT minted (includes fee/spacing depending on adapter) |
| `Increased` | event Increased(uint256 indexed tokenId, uint256 used0, uint256 used1) | Liquidity increased |
| `Removed` | event Removed(uint256 indexed tokenId, uint256 bps, uint256 out0, uint256 out1) | Liquidity removed (fractional) |
| `Unwound` | event Unwound(uint256 indexed tokenId, address to, uint256 out0, uint256 out1) | Position fully unwound |
| `Swapped` | event Swapped(address indexed tokenIn, address tokenOut, uint256 amountIn, int24/uint24 tickSpacing/fee, uint256 minOut, uint256 out) | Swap executed. Param 4 is tickSpacing (Aerodrome) or fee (Uniswap) |

---

## 4. ProtocolReserve Events

| Event | Signature & Fields | Description |
|---|---|---|
| `ReservesSwept` | event ReservesSwept(address[] recipients, uint256[] amounts, uint256 total) | Reserves distributed to recipients |
| `SharesUpdated` | event SharesUpdated(address[] recipients, uint256[] bps) | Recipient shares configuration updated |

---

## 5. Valuation Events

| Event | Signature & Fields | Description |
|---|---|---|
| `TWAPSecondsUpdated` | event TWAPSecondsUpdated(uint32 twapSeconds) | TWAP window duration changed |
| `DepthTicksUpdated` | event DepthTicksUpdated(int24 depthTicks) | Depth tick band used for scoring changed |
| `CoreSet` | event CoreSet(address indexed core) | CORE address configured |
| `Refreshed` | event Refreshed(address indexed dexFactory, uint256 tokensCount, uint256 connectorsCount) | Cache refresh completed for a discovered factory |
| `RefreshFailed` | event RefreshFailed(address indexed pool, bytes reason) | A pool failed scoring during refresh (best-effort refresh continues) |

---

## 6. FeeType Enum Mapping

`CLManager.sol` defines an on-chain `FeeType` enum used in fee-related events (`ProtocolFeePaid`, `BotFeePaid`). The enum values map to the following actions:

| Enum Value | Meaning / Action |
|------------|------------------|
| `FeeType.Open` | Protocol fee charged on `openPosition` |
| `FeeType.Collect` | Bot fee charged when collecting fees to USDC (`collectFeesToUSDC`) |
| `FeeType.CollateralAdd` | Protocol fee charged on `addCollateral` |
| `FeeType.ChangeRange` | Fees charged during `changeRange` (re-mint flow) |
| `FeeType.Exit` | Bot fee charged during `exitPosition` |
| `FeeType.Compound` | Bot fee charged during `compoundFees` |

## 7. Event Field Reference

- **user** (CLManager events): The position owner for the relevant key. Exception: `PositionOpened.user` is the caller who supplied USDC and becomes the initial owner.
- **owner** (CLCore events): The position owner.
- **payer** (`ProtocolFeePaid`): The position owner who is considered the fee payer for that action (for deposit-like flows this is the caller/owner; for bot-initiated `changeRange` this is still the position owner).
- **bot** (`BotFeePaid`): The bot address receiving the fee (the caller when the caller is an allowlisted bot).

Note on `ProtocolFeePaid.payer` semantics:
- For deposit-like flows (`open`, `collateralAdd`), `payer` is the caller who supplied USDC (the position owner).
- For `changeRange`, `payer` is explicitly set to the position owner in the emitted event even when a whitelisted bot performs the action; the bot's compensation is emitted separately via `BotFeePaid`.

- **key**: Position key (indexed)
- **tokenId**: NFT id for the position (when present and relevant)
- **dex**: DEX adapter address
- **token0/token1/token/tokenIn/tokenOut**: Token addresses involved in the action
- **depositedUSDC:** The gross USDC amount the position owner supplied to the protocol for a deposit-like flow (e.g., `openPosition` or `addCollateral`).
- **addedUSDC:** The measured increase in the canonical position value after a collateral addition.
- **returnedUSDC:** The total USDC transferred back to the position owner as a result of an operation (for example during `removeCollateral` or `exitPosition`).
- **removedUSDC:** The observed decrease in canonical position value caused by a removal operation. (e.g `removeCollateral`)
- **feesCollected:** Flow-specific:
  - `PositionExited` / `PositionNftReturned` / `RangeChanged`: snapshot of `CLCore.getPositionDetails(key).pendingFeesUSDC` taken at the start of the flow.
  - `CollateralRemoved`: estimated fees collected during the liquidity decrease, measured as the decrease in `pendingFeesUSDC` before vs. after the burn.
- **feeUSDC:** USDC-denominated fee amounts. Context varies by event: in `ProtocolFeePaid` this is the protocol fee transferred to the `ProtocolReserve`; in `BotFeePaid` this is the bot's fee transferred to the caller bot.
- **compoundedUSDC:** The USDC-equivalent amount that was successfully compounded back into liquidity during a compound flow. This is the net value added to the position from compounding after adapter rounding/leftover AND any bot fees applied to the compounded notional.
- **protocolFeeUSDC**: Protocol fee sent to reserve
- **dustAdded/dustRefunded**: USDC dust movements
- **liquidity**: Raw liquidity value for the position
- **action/feeType**: String describing the action or fee type

---
