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

---

## 2. CLManager Events

| Event | Signature & Fields | Description |
|---|---|---|
| `PositionOpened` | event PositionOpened(address indexed user, bytes32 indexed key, uint256 indexed tokenId, address dex, address pool, address token0, address token1, uint256 depositedUSDC, uint256 protocolFeeUSDC, address referrer, uint256 referralFeeUSDC, uint256 dustAdded) | New position created |
| `PositionExited` | event PositionExited(address indexed user, bytes32 indexed key, uint256 indexed tokenId, uint256 returnedUSDC, uint256 feesCollected, uint256 protocolFeeUSDC, uint256 referralFeeUSDC) | Position exited and deregistered |
| `PositionNftReturned` | event PositionNftReturned(address indexed user, bytes32 indexed key, uint256 indexed tokenId, uint256 returnedUSDC, uint256 feesCollected) | NFT returned to owner without unwinding (emergency path) |
| `FeesCollected` | event FeesCollected(address indexed user, bytes32 indexed key, uint256 indexed tokenId, uint256 fee0, uint256 fee1, uint256 usdcOut, uint256 protocolFeeUSDC, uint256 referralFeeUSDC) | Fees collected and swapped to USDC (or collected as tokens in compound) |
| `FeesCompounded` | event FeesCompounded(address indexed user, bytes32 indexed key, uint256 indexed tokenId, uint256 compoundedUSDC, uint256 used0, uint256 used1, uint256 protocolFeeUSDC, uint256 referralFeeUSDC, uint256 dustAdded) | Fees compounded into liquidity |
| `RangeChanged` | event RangeChanged(address indexed user, bytes32 indexed key, uint256 oldTokenId, uint256 newTokenId, int24 oldLower, int24 oldUpper, int24 newLower, int24 newUpper, uint256 positionValueBefore, uint256 positionValueAfter, uint256 protocolFeeUSDC, uint256 referralFeeUSDC, uint256 feesCollected) | Position range changed |
| `CollateralAdded` | event CollateralAdded(address indexed user, bytes32 indexed key, uint256 indexed tokenId, uint256 depositedUSDC, uint256 addedUSDC, uint256 totalCollateralUSDC, uint256 protocolFeeUSDC, address referrer) | Collateral added to position |
| `CollateralRemoved` | event CollateralRemoved(address indexed user, bytes32 indexed key, uint256 indexed tokenId, uint256 returnedUSDC, uint256 feesCollected, uint256 protocolFeeUSDC, uint256 referralFeeUSDC, uint256 removedUSDC, uint256 totalCollateralUSDC) | Collateral removed from position |
| `ProtocolFeePaid` | event ProtocolFeePaid(address indexed payer, bytes32 indexed key, uint256 tokenId, uint256 grossUSDC, uint256 feeUSDC, uint256 netUSDC, FeeType feeType) | Protocol reserve fee paid |
| `BotFeePaid` | event BotFeePaid(address indexed bot, bytes32 indexed key, uint256 tokenId, uint256 feeUSDC, FeeType feeType) | Bot fee paid to bot address |
| `ReferralFeePaid` | event ReferralFeePaid(address indexed referrer, address indexed user, bytes32 indexed key, uint256 grossUSDC, uint256 referralFeeUSDC, uint256 netUSDC, FeeType feeType) | Referral fee credited from an applicable protocol fee |
| `PositionCopied` | event PositionCopied(address indexed user, bytes32 indexed sourceKey, bytes32 indexed key, address sourceOwner, bool botAllowed) | Source position pool/range copied for the caller with source-owner referral attribution |
| `PositionImported` | event PositionImported(address indexed user, bytes32 indexed key, uint256 indexed tokenId, address dex, address pool, address token0, address token1, uint256 importedUSDC, address referrer) | Existing LP NFT imported into CLCore tracking |
| `PlannerUpdated` | event PlannerUpdated(address indexed planner) | Rebalance planner dependency changed |
| `ValuationUpdated` | event ValuationUpdated(address indexed valuation) | Valuation dependency changed |
| `GuardianUpdated` | event GuardianUpdated(address indexed guardian) | CLManager guardian changed |
| `EZWrapperUpdated` | event EZWrapperUpdated(address indexed ezWrapper) | EZWrapper dependency changed |
| `ReferralManagerUpdated` | event ReferralManagerUpdated(address indexed referralManager) | ReferralManager dependency changed |
| `DiscountedWalletBpsUpdated` | event DiscountedWalletBpsUpdated(address indexed wallet, uint16 discountBps) | Wallet fee discount changed |
| `BotFeeMultiplierForEarnedFeesUpdated` | event BotFeeMultiplierForEarnedFeesUpdated(uint16 multiplier) | Collect/compound bot-fee multiplier changed |
| `EarnedFeesProtocolFeeBpsUpdated` | event EarnedFeesProtocolFeeBpsUpdated(uint16 feeBps) | Earned-fee protocol fee changed |
| `MaxProtocolFeeSlippageBpsUpdated` | event MaxProtocolFeeSlippageBpsUpdated(uint16 slippageBps) | Protocol-fee sale slippage cap changed |
| `MinimumOpenUSDCUpdated` | event MinimumOpenUSDCUpdated(uint256 minimumOpenUSDC) | Minimum open size changed |
| `MaxBatchKeysUpdated` | event MaxBatchKeysUpdated(uint256 maxBatchKeys) | Batch size cap changed |

---

## 3. EZWrapper Events

| Event | Signature & Fields | Description |
|---|---|---|
| `GuardianUpdated` | event GuardianUpdated(address indexed guardian) | EZWrapper guardian changed |
| `BotActionProceedsForwarded` | event BotActionProceedsForwarded(address indexed user, bytes32 indexed key, uint256 amount, bool positionClosed) | Direct bot action proceeds forwarded to a wrapper user |
| `EzPositionOpened` | event EzPositionOpened(address indexed user, bytes32 indexed key, address pool, int24 tickLower, int24 tickUpper, uint256 usdcAmount, address referrer) | Wrapper-owned position opened for a user |
| `EzCollateralAdded` | event EzCollateralAdded(address indexed user, bytes32 indexed key, uint256 usdcAmount) | Collateral added through the wrapper |
| `EzCollateralRemoved` | event EzCollateralRemoved(address indexed user, bytes32 indexed key, uint256 withdrawUsdc, uint256 returnedUsdc) | Collateral removed through the wrapper |
| `EzPositionExited` | event EzPositionExited(address indexed user, bytes32 indexed key, uint256 returnedUsdc) | Wrapper-owned position exited |
| `EzNftReturned` | event EzNftReturned(address indexed user, bytes32 indexed key, uint256 indexed tokenId, uint256 dustReturned) | Wrapper-owned LP NFT and dust returned to mapped user |

---

## 4. ReferralManager Events

| Event | Signature & Fields | Description |
|---|---|---|
| `GuardianUpdated` | event GuardianUpdated(address indexed guardian) | ReferralManager guardian changed |
| `ManagerUpdated` | event ManagerUpdated(address indexed manager) | Active CLManager changed |
| `DefaultReferrerUpdated` | event DefaultReferrerUpdated(address indexed defaultReferrer) | Default referrer changed |
| `ReferralShareBpsUpdated` | event ReferralShareBpsUpdated(uint16 referralShareBps) | Earned-fee referral share changed |
| `CopyReferralShareBpsUpdated` | event CopyReferralShareBpsUpdated(uint16 copyReferralShareBps) | Copy referral share changed |
| `ReferrerSet` | event ReferrerSet(address indexed user, address indexed referrer) | Wallet referrer initialized |
| `ReferrerUserCountUpdated` | event ReferrerUserCountUpdated(address indexed referrer, uint256 userCount) | Referrer's assigned wallet count changed |
| `ReferralFeeAccrued` | event ReferralFeeAccrued(address indexed referrer, address indexed user, bytes32 indexed key, uint256 grossUSDC, uint256 referralFee, uint256 netUSDC, FeeType feeType) | Nonzero referral balance credit recorded |
| `ReferralFeesClaimed` | event ReferralFeesClaimed(address indexed referrer, uint256 amount) | Referral balance claimed |

---

## 5. Adapter Events (Aerodrome & Uniswap)

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

## 6. Valuation Events

| Event | Signature & Fields | Description |
|---|---|---|
| `TWAPSecondsUpdated` | event TWAPSecondsUpdated(uint32 twapSeconds) | TWAP window duration changed |
| `DepthTicksUpdated` | event DepthTicksUpdated(int24 depthTicks) | Depth tick band used for scoring changed |
| `CoreSet` | event CoreSet(address indexed core) | CORE address configured |
| `Refreshed` | event Refreshed(address indexed dexFactory, uint256 tokensCount, uint256 connectorsCount) | Cache refresh completed for a discovered factory |
| `RefreshFailed` | event RefreshFailed(address indexed pool, bytes reason) | A pool failed scoring during refresh (best-effort refresh continues) |

---

## 7. FeeType Enum Mapping

`CLManager.sol` defines an on-chain `FeeType` enum used in fee-related events (`ProtocolFeePaid`, `BotFeePaid`, `ReferralFeePaid`). `ReferralManager.sol` uses the same numeric `FeeType` mapping for `ReferralFeeAccrued`. The enum values map to the following actions:

| Enum Value | Meaning / Action |
|------------|------------------|
| `FeeType.Open` | Protocol fee charged on `openPosition` |
| `FeeType.Collect` | Earned-fee protocol fee and/or bot fee charged when collecting fees to USDC (`collectFeesToUSDC`) |
| `FeeType.CollateralAdd` | Protocol fee charged on `addCollateral` |
| `FeeType.ChangeRange` | Earned-fee protocol fee and/or bot fee charged during `changeRange` (re-mint flow) |
| `FeeType.Exit` | Earned-fee protocol fee and/or bot fee charged during `exitPosition` |
| `FeeType.Compound` | Earned-fee protocol fee and/or bot fee charged during `compoundFees` |
| `FeeType.CollateralRemove` | Earned-fee protocol fee charged on pending fees realized during `removeCollateral` |

## 8. Event Field Reference

- **user** (CLManager events): The position owner for the relevant key. For `openPositionEz`, this is EZWrapper because the wrapper owns the CLCore position; EZWrapper events carry the mapped user.
- **user** (EZWrapper events): The user mapped to an ez-flow key.
- **user** (ReferralManager events): The wallet whose referrer was used for the referral credit.
- **owner** (CLCore events): The position owner.
- **payer** (`ProtocolFeePaid`): The address whose action/value paid the protocol fee. For direct deposit-like flows this is the caller supplying USDC; for `openPositionEz` this is the EZWrapper caller; for earned-fee protocol fees (`collectFeesToUSDC`, `compoundFees`, `removeCollateral`, `changeRange`, `exitPosition`) this is the position owner.
- **bot** (`BotFeePaid`): The bot address receiving the fee (the caller when the caller is an allowlisted bot).

Note on `ProtocolFeePaid.payer` semantics:
- For deposit-like flows (`open`, `collateralAdd`), `payer` is the caller who supplied USDC. In ez opens, `PositionOpened.user` is EZWrapper while `ProtocolFeePaid.payer` is also EZWrapper; `EzPositionOpened.user` carries the mapped user.
- For earned-fee protocol fees, `payer` is explicitly set to the position owner even when a whitelisted bot performs the action; the bot's compensation is emitted separately via `BotFeePaid`.

- **key**: Position key (indexed)
- **sourceKey:** Source position key for copyPosition.
- **sourceOwner:** Owner or mapped user receiving the source reward for the copied open.
- **referrer:** Wallet used for referral fee attribution. In normal open/add flows this is the stored wallet referrer; in copy flows this may be the copied source owner for source-reward attribution.
- **tokenId**: NFT id for the position (when present and relevant)
- **dex**: DEX adapter address
- **token0/token1/token/tokenIn/tokenOut**: Token addresses involved in the action
- **depositedUSDC:** The gross USDC amount the position owner supplied to the protocol for a deposit-like flow (e.g., `openPosition` or `addCollateral`).
- **addedUSDC:** The measured increase in the canonical position value after a collateral addition.
- **returnedUSDC:** The total USDC transferred back to the position owner as a result of an operation (for example during `removeCollateral` or `exitPosition`).
- **removedUSDC:** The observed decrease in canonical position value caused by a removal operation. (e.g `removeCollateral`)
- **protocolFeeUSDC:** Protocol fee amount sent to ProtocolReserve for the flow. On `PositionOpened` copy flows, `referralFeeUSDC` is the source-owner reward and `protocolFeeUSDC` is the reserve remainder.
- **feesCollected:** Flow-specific:
  - `PositionExited` / `PositionNftReturned` / `RangeChanged`: snapshot of `CLCore.getPositionDetails(key).pendingFeesUSDC` taken at the start of the flow.
  - `CollateralRemoved`: estimated fees collected during the liquidity decrease, measured as the decrease in `pendingFeesUSDC` before vs. after the burn. When nonzero, this is the basis for any `FeeType.CollateralRemove` protocol fee.
- **feeUSDC:** USDC-denominated fee amounts. Context varies by event: in `ProtocolFeePaid` this is the reserve portion of the protocol fee; in `BotFeePaid` this is the bot's fee transferred to the caller bot.
- **referralFee/referralFeeUSDC:** USDC credited to a referrer in ReferralManager.
- **netUsdc/netUSDC:** USDC remaining after the fee represented by that event. For `ProtocolFeePaid`, this is after the gross protocol fee target (`feeUSDC + referralFeeUSDC` when a referral split applies); any separate `BotFeePaid` event is applied independently according to the flow.
- **compoundedUSDC:** The USDC-equivalent amount that was successfully compounded back into liquidity during a compound flow. This excludes residual USDC tracked as `dustAdded`.
- **protocolFeeUSDC**: Protocol fee amount sent to ProtocolReserve. On earned-fee events, the gross earned-fee protocol target is `protocolFeeUSDC + referralFeeUSDC`.
- **dustAdded/dustRefunded**: USDC dust movements
- **liquidity**: Raw liquidity value for the position
- **action/feeType**: String describing the action or fee type

---
