# Errors Reference: Custom Errors and Revert Reasons

This reference lists the custom `error` declarations present in the `src/` Solidity contracts and a short description of where they are declared or used.

---

## CLCore (src/CLCore.sol)

- `NotManager()` : Caller is not the set manager (onlyManager modifier).
- `NotGuardian()` : Caller is not the set guardian (onlyGuardian modifier).
- `PositionAlreadyExists()` : Attempted register when position key exists.
- `PositionNotFound()` : Position lookup failed or tokenId==0.
- `NpmLookupFailed()` : Underlying NPM / pool discovery failed during adapter checks.
- `InvalidRegisterParams()` : Register params invalid (zero address owner, zero tokenId, etc).
- `InvalidTokenId()` : Token id mismatch or invalid (zero).
- `InvalidTickSpacing()` : Tick spacing provided is invalid (<= 0).
- `ApproveFailed()` : ERC20 or NPM approval failed.
- `RevokeFailed()` : NPM approval revocation failed.
- `InvalidTickRange()` : Provided tick range invalid (tickLower >= tickUpper).
- `TickAlignmentError()` : Tick range not aligned to tick spacing.
- `InvalidFee()` : Fee value invalid for pool (sentinel).
- `InsufficientCoreBalance()` : CORE does not hold required USDC (push-model enforced).
- `ReserveNotSet()` : Protocol reserve not set while protocolFeeBps > 0.
- `ArithmeticOverflow()` : Generic arithmetic safety sentinel (e.g. adjustTotalDeposited inputs).
- `PoolNotFound()` : Pool lookup failed for given tokens/fee/spacing.
- `PoolNotAllowed()` : Pool not tracked or explicitly revoked in CORE (NotAllowed).
- `PoolDeprecated()` : Attempted to open a new position on a pool that is `Deprecated` (phasing out).
- `FeeTooHigh()` : Fee exceeds configured maximum (100% or similar bounds).
- `ZeroAddress()` : Address(0) provided where forbidden.
- `InvalidBot()` : Bot address invalid (e.g. zero) when adding/removing.
- `BridgeTokensTooMany()` : Bridge tokens array length exceeds limit (3).
- `BridgeTokenDuplicate()` : Duplicate bridge token provided.
- `BridgeTokenIsUSDC()` : USDC cannot be added as a bridge token.
- `DustRemaining()` : Tried to deregister a position while dust was still tracked for it.

## CLManager (src/CLManager.sol)

- `NotGuardian()` : Caller is not the guardian.
- `NotOwner()` : Caller is not the position owner (or allowed bot for some flows).
- `UsdcDecimalsTooLow()` : USDC has fewer than 3 decimals in constructor (unsupported).
- `InvalidParams()` : Generic invalid parameters sentinel in manager.
- `PositionNotFound()` : Position registry lookup failed.
- `ReserveNotSet()` : Protocol reserve not configured.
- `NothingRemoved()` : No liquidity was removed during an exit or change range.
- `TooManyInBatch(uint256 maxKeys)` : Batch input exceeded `MAX_BATCH_KEYS`.
- `PositionValueZero()` : Position value computed as zero (disallowed in some flows).
- `TooMuchWithdraw()` : Withdrawal requested exceeds available.
- `BpsZero()` : Basis points value is zero where non-zero required.
- `NoTokensUnwound()` : Nothing to unwrap/withdraw in unwinding flows.
- `NoPositionMinted()` : Mint call returned tokenId == 0.
- `DexNotAllowed()` : Adapter not allowlisted in CORE.
- `PoolNotAllowed()` : Pool not allowlisted in CORE.
- `PoolDeprecated()` : Attempted to open a new position on a pool that is `Deprecated` (phasing out).
- `PoolNotFound()` : Pool lookup failed.
- `ZeroAmount()` : Zero amount where positive amount expected.
- `PositionTooSmall()` : Position size below `MINIMUM_OPEN_USDC`.
- `InvalidTickRange()` : Provided tick range invalid.
- `EmptyKeys()` : Keys array is empty where non-empty required.
- `ZeroAddress()` : Zero address provided.
- `TickAlignmentError()` : Tick alignment mismatch for provided spacing.
- `PoolNotInitialized()` : Pool is uninitialized (`slot0.sqrtPriceX96 == 0`), so minting is unsafe.

## Adapters

### AerodromeAdapter (src/AerodromeAdapter.sol)

- `ZeroAddress()` : Init param or setter input was zero.
- `NotManager()` : Caller is not the set manager.
- `NotGuardian()` : Caller is not the set guardian.
- `InvalidParam()` : Generic invalid param sentinel.
- `PoolNotFound()` : No pool found for tokens or routing fail.
- `QuoterFailed()` : Quoter invocation failed or reverted.
- `QuoterNotConfigured()` : Quoter address not set when required.
- `SlippageExceeded(uint256 expectedMinOut, uint256 actualOut)` : Swap slippage check failed.
- `PoolUninitialized()` : Pool is uninitialized (`slot0.sqrtPriceX96 == 0`), so TWAP/slippage bounds cannot be computed safely.
- `MintFailed(bytes reason)` : Mint call to NPM reverted; raw revert bytes attached.
- `IncreaseFailed(bytes reason)` : NPM increaseLiquidity call reverted; raw revert bytes attached.
- `NPMPositionsError()` : NPM.positions() lookup failed.
- `AlreadySet()` : One-time setter (setCore) called more than once.
- `BalanceTooLow()` : Adapter does not hold the required token balance for the requested action.
- `UnsupportedPair()` : Pair cannot be seeded/routed under the adapter’s bridge-token constraints.

### UniswapAdapter (src/UniswapAdapter.sol)

- `NotManager()` : Caller is not the set manager.
- `NotGuardian()` : Caller is not the set guardian.
- `ZeroAddress()` : Zero address provided.
- `InvalidParam()` : Generic invalid parameter sentinel.
- `AlreadySet()` : One-time setter (setCore) called more than once.
- `SlippageExceeded(uint256 expectedMinOut, uint256 actualOut)` : Swap slippage check failed.
- `QuoterFailed()` : Quoter invocation failed.
- `QuoterNotConfigured()` : Quoter address not set when required.
- `PoolNotFound()` : No Uniswap V3 pool found for tokens.
- `PoolUninitialized()` : Pool is uninitialized (`slot0.sqrtPriceX96 == 0`), so TWAP/slippage bounds cannot be computed safely.
- `MintFailed(bytes reason)` : Mint call to NPM reverted; raw revert bytes attached.
- `IncreaseFailed(bytes reason)` : NPM increaseLiquidity call reverted; raw revert bytes attached.
- `NPMPositionsError()` : NPM.positions() lookup failed.
- `BalanceTooLow()` : Adapter does not hold the required token balance for the requested action.
- `UnsupportedPair()` : Pair cannot be seeded/routed under the adapter’s bridge-token constraints.

## ProtocolReserve (src/ProtocolReserve.sol)

- `LengthMismatch()` : Recipient and percentage arrays length mismatch in `setShares`.
- `InvalidRecipientAddress()` : Zero-address recipient provided.
- `TotalNot100()` : Sum of percentages must equal 10000 (100%).
- `NoBalance()` : Attempt to sweep when reserve balance is zero.
- `NoShares()` : Attempt to sweep when no shares configured.
- `EmptyShares()` : Attempt to set empty shares array.

## Valuation (src/Valuation.sol)

- `ZeroAddress()` : Zero address provided where non-zero is required (constructor, setCore).
- `ValuationFailed()` : Generic valuation failure sentinel for unexpected internal errors.
- `CoreNotSet()` : CORE address has not been configured when valuation or refresh logic requires it.
- `DexNotAllowed()` : DEX adapter is not allowlisted in CORE.
- `DexFactoryNotFound()` : Adapter factory lookup via `ICLDexAdapter.getFactory()` failed or returned zero.
- `AlreadySet()` : One-time setter (setCore) called more than once.
- `InvalidTWAPSeconds()` : TWAP seconds configuration is invalid (zero) or used in an invalid context.
- `InvalidDepthTicks()` : Depth tick band configuration is invalid.
- `CorePoolsLookupFailed()` : `ICLCore.listAllowedPools()` reverted or could not be read.
- `NoPoolsToRefresh()` : `listAllowedPools()` returned an empty set, so `refreshAll()` has nothing to process.
- `InvalidEdgeInputs()` : Edge-scoring inputs are invalid (zero addresses or identical token/connector).
- `PoolHasZeroReserves()` : Candidate pool for edge scoring has zero token or connector reserves.
- `AnchorPoolNotFound()` : No connector→USDC pool found for anchoring valuations.
- `QuotingFailed()` : TWAP-based quote through a pool returned an unusable value (e.g. zero) during scoring.
- `InvalidPoolTokens()` : Cached/queried pool tokens do not match the expected tokenIn/tokenOut pair.
- `TWAPObservationFailed()` : `observe()` call failed or returned malformed TWAP data.
- `TWAPTickOutOfRange()` : Arithmetic mean tick computed from TWAP is outside `TickMath` bounds.
- `RouteNotFound()` : No viable cached route (direct or via connector) was found for the requested pair.

## RebalancePlanner (src/RebalancePlanner.sol)

- `UsdcDecimalsTooLow()` : USDC has fewer than 3 decimals in constructor (unsupported).
- `UnsupportedPool()` : Pool tokens do not match expectations or bridge config.
- `PoolNotFound()` : Pool lookup failed.
- `InvalidTicks()` : Tick range invalid or inconsistent with spacing.
- `InvalidInput()` : Invalid input amounts or parameters.
- `MissingDexAdapter()` : Adapter address missing.
- `ZeroAddress()` : Zero address provided where non-zero required.
- `FeeFetchFailed()` : Could not determine pool fee.
- `Slot0Failed()` : Failed to read pool slot0 (sqrtPrice/tick).
- `AlreadySet()` : One-time setter called twice.

---

## Practical guidance

- When decoding revert bytes caught from adapters (e.g. `IncreaseFailed(bytes)`), note the adapter rethrows the raw revert payload from the underlying NPM or pool. The inner bytes may not match selectors declared in this repo — they can be pool/NPM-specific or include Solidity `Error(string)` payloads. Use `data/error_selectors.json` and the repository's `debug/decode_revert.js` to help map selectors.
