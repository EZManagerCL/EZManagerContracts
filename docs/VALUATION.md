# Valuation: On-Chain Price Oracle and Methodology

This document provides a detailed, descriptive overview of the `Valuation` contract and logic in the EZManager protocol. It covers the price oracle methodology, code references, and integration flows as implemented.

---


## 1. Purpose and Architecture

`Valuation` provides a robust, view-only USDC valuation for any token, using on-chain DEX pools (Uniswap V3/PancakeSwap and Aerodrome). It is used by `CLCore`, `CLManager`, and off-chain tools to ensure accounting is based on canonical, manipulation-resistant prices. All configuration and integration of the valuation logic is managed by the Timelock/Gnosis Safe multisig.

**Responsibilities:**
- Return USDC-equivalent value for any token/amount on a given DEX
- Scan allowlisted pools and cache the best pool edges (token -> connector) when refreshed. Cached edges are keyed by DEX factory address (resolved from the adapter’s `getFactory()`), and are used at runtime to avoid expensive chain scans.
- Use short TWAP (time-weighted average price) for price safety (60s default).
- Support both direct and bridge-token routed paths.
- Consult `CLCore.listAllowedPools()` / `isPoolAllowed()` to restrict valuation to pools tracked by the protocol. Pools have lifecycle statuses (`Allowed`, `Deprecated`, `NotAllowed`). Valuation ignores pools that are `NotAllowed`, and will consider `Allowed` and `Deprecated` pools for read-only valuation.

---

## 2. Key Functions and Flows

### 2.1. usdcValue
- Returns the USDC-equivalent value for a given token/amount on the specified DEX
- Handles direct and two-hop (via connectors) routes
 - The `dex` parameter is the adapter address (must be allowlisted in `CLCore.allowedDexes`). `Valuation` resolves the adapter’s factory and uses it to read cached edges.
 - Cached edges are keyed by the resolved DEX factory address, not by the adapter address.
 - At runtime `Valuation` consults cached edges (populated by `refreshAll()`) to choose either a direct edge or a two-hop path using a single connector. The chosen route is the one with the largest bottleneck score measured as the USDC-valued active depth around the TWAP tick — this active depth is estimated using the TWAP arithmetic-mean tick, the TWAP-derived sqrt price (TickMath), and the average active liquidity (`avgL`) computed over the same TWAP window length (not raw on-chain ERC20 balances).
 - If no valid cached route exists (direct or single-connector hop) runtime calls such as `usdcValue` and `getBestRoute` will revert. TWAP/quoting failures encountered during `refreshAll()` do not necessarily abort the entire refresh; `refreshAll()` attempts pools in a best-effort manner and emits `RefreshFailed(pool, reason)` for individual pools that couldn't be scored.
 - For extremely small inputs, the TWAP quoting math may legitimately round to 0; `usdcValue` returns 0 in that case instead of reverting.


---

## 3. Methodology and Safety

### 3.1. Pool Selection When Refreshed
 - `refreshAll()` is an owner-only operation that scans pools discovered via `CLCore.listAllowedPools()`, derives a set of non-connector tokens from those pools, and builds a per-factory cache of the best edges between token and connector pairs. For Uniswap-like factories it scans configured fee tiers; for Aerodrome factories it scans tick spacings.
 - For each candidate pool the score is the bottleneck: the minimum of the token-side and connector-side active depths. Active depths are estimated by computing a small symmetric tick band around the TWAP arithmetic-mean tick, converting that tick to a sqrt price via `TickMath`, and applying the observed average liquidity `avgL` (the average active liquidity over the same TWAP window) together with `SqrtPriceMath.getAmount0Delta` / `getAmount1Delta` to obtain token amounts inside the band. Those token-side depths are then quoted to USDC via the chosen connector→USDC anchor; the best-scoring pool per (token, connector) pair is cached.
 -  `refreshAll()` is best-effort at the run level — it will skip individual pools that can't be inspected (for example, due to `observe()` failing, out-of-range TWAP ticks, lack of an anchor connector->USDC pool, or zero active liquidity) and will emit `RefreshFailed(pool, reason)` for those failures rather than aborting the whole refresh. However, failed pools will not contribute to cache entries, so operators should ensure connectors and anchor pools are registered and healthy before running a refresh.

### 3.2. TWAP Calculation
 - `Valuation` derives prices and an active-liquidity estimate from a configurable TWAP window (default 60 seconds) via pool `observe()` and Uniswap's tick→sqrtPrice math. The `observe()` cumulatives are used to compute an arithmetic-mean tick (converted to a sqrt price via `TickMath`) and an `avgL` value (the average active liquidity over the same TWAP window length). Those values are combined with `SqrtPriceMath` helpers to estimate token-side depths within a small symmetric tick band around the TWAP tick; those depths are then quoted to USDC using the TWAP-derived price.
 - If `observe()` fails, the reported TWAP tick is out of `TickMath` bounds, or quoting math would under/overflow, the code treats the pool as unusable for scoring. In `refreshAll()` such errors are reported via `RefreshFailed` events and the refresh continues. At runtime, missing cached edges or failed anchors will cause `usdcValue` / `getBestRoute` to revert if no viable route exists.

### 3.3. Handling Edge Cases
- If no valid cached route exists (direct or single-connector hop), or if quoting via TWAP fails, `usdcValue` reverts.
- `Valuation` always re-checks `CLCore.isPoolAllowed()` when reading cached pools at runtime to avoid using pools that were later disabled. Pools that are not tracked by `CLCore` or that are `NotAllowed` are ignored during selection; `Allowed` and `Deprecated` pools are considered.

---

## 5. Integration in Protocol Flows

- All value calculations in `CLCore` and `CLManager` use `Valuation` for canonical pricing
- Ensures all accounting is based on manipulation-resistant, on-chain prices
- Used in positionValueUSDC, fee logic, and off-chain dashboards.

---


## 6. Security and Operational Details

- `Valuation` relies on TWAP-only quoting and does not silently fall back to spot prices. If TWAP data is unusable the call will revert. This is an intentional safety design to avoid returning manipulable prices.
- Calls to `Valuation` from other contracts generally do not wrap calls in `try/catch`, so reverts will bubble. This is an intentional design choice to ensure accounting is always 100% accurate.
- Because `refreshAll()` anchors values via connector->USDC pools, operators should ensure chosen connectors (USDC and configured bridge tokens) have reliable connector->USDC pools and healthy liquidity. `refreshAll()` will fail pools that cannot be anchored.
- The per-factory cached edges mean the runtime lookup is cheap and deterministic, but requires periodic refresh to capture pool changes.
- The TWAP window (`setTWAPSeconds`) and depth tick band (`setDepthTicks`) are owner-configured parameters that affect scoring and quoting behavior.

---
