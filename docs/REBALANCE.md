
# RebalancePlanner: Optimal Liquidity and Swap Planning

This document provides a detailed overview of the `RebalancePlanner` contract and its solver behavior in EZManager.

---

## 1. Purpose and Architecture

`RebalancePlanner` computes the optimal swap amounts for a concrete token bundle and target concentrated-liquidity range.

**Responsibilities:**
- Compute deterministic swap instructions for mint/add flows
- Operate directly on token0/token1 balances after seeding from USDC
- Use exact concentrated-liquidity math instead of external quoters
- Validate the concrete pool against the configured adapter/factory before solving
- Stay stable across thin-liquidity, initialized-tick boundaries, and pool-specific bitmap behavior

The planner is constructed with `CLCore` and caches the bridge tokens fixed there at deployment. The planner only supports pools where at least one side is USDC or one side is one of those bridge tokens.

---

## 2. Main Entry Point

### 2.1. `planFromTokenBundle`

```solidity
planFromTokenBundle(
    dex,
    pool,
    token0,
    token1,
    tickLower,
    tickUpper,
    amount0,
    amount1
)
```

The planner:

- validates the pool context
- checks that the supplied pair is USDC-linked or bridge-token-linked
- aligns caller-supplied tokens with the pool's actual ordering
- computes the optimal swap direction and size
- returns:

```solidity
struct RebalanceParams {
    uint256 token0ToToken1;
    uint256 token1ToToken0;
}
```

Only one side is non-zero in a valid plan.

---

## 3. Inputs and Trust Boundaries

- Adapters handle USDC seeding and any bridge-token routing before the planner runs
- The planner works on the concrete token bundle that will actually be minted or added
- Pool context is fetched directly from the target pool and validated through the adapter/DEX wiring
- Token ordering is normalized internally: if the caller supplies `(token1, token0)`, the planner swaps the working amounts to match the pool's canonical ordering
- For Uniswap-style pools, the planner validates the pool by `(tokenA, tokenB, fee)`
- For Aerodrome/Slipstream pools, the planner validates the pool by `(tokenA, tokenB, tickSpacing)` and uses the factory's current `getSwapFee(pool)` as the math fee when available

The planner does not move funds and does not depend on external quote contracts.

---

## 4. Solver Behavior

### 4.1. Objective

The solver ranks candidate states after pricing dust in token1 terms. When two candidates differ, it prefers:

- mintable states over non-mintable states
- higher achievable liquidity
- lower total dust value
- smaller absolute signed dust imbalance between the two sides
- smaller gross swap amount

### 4.2. Segment Solve

The implementation uses:

- exact V3 math
- a deterministic phase flow: enter range if needed, walk initialized segments until the solution is bracketed, then solve inside the active segment
- exact swap-step simulation using `SwapMath.computeSwapStep`
- the closed-form quadratic from `POSSIBLE_CLOSED_FORM.md` to solve for the target in-range sqrt price
- a small local exact-evaluation correction around the predicted gross input to absorb integer swap rounding

The planner uses one explicit walk limit:

- `MAX_WALK_TICKS`: shared boundary-walk budget across both entry-from-outside and in-range segment walking before terminal approximation

### 4.3. Tick Cross Handling

If the target swap crosses an initialized tick, the planner walks to that boundary, applies the tick's liquidity delta, and then continues in the next active segment. Once the active segment brackets the solution, the planner solves the closed form inside that segment against the pre-step state. This keeps the in-range solve aligned with the pool's actual active liquidity.

For Slipstream pools, tick crossing uses the pool `ticks()` liquidity net without adding any separate staked-liquidity delta. If the pool does not expose a readable tick bitmap, the planner hard-fails with `UnsupportedBitmap()` instead of silently approximating from incomplete state.

If a tick crossing would require invalid active-liquidity math, the planner hard-fails with `InvalidPoolLiquidityState()` instead of panicking on arithmetic. This covers cases such as:

- removing more active liquidity than remains during a crossing
- adding enough liquidity to overflow `uint128`
- malformed liquidity-net values that would overflow crossing math

### 4.4. Entry From Outside the Range

If the current price starts below `tickLower`, the planner first spends token1 to move toward the lower bound. If the current price starts above `tickUpper`, it first spends token0 to move toward the upper bound.

If the bundle runs out before reaching the target boundary, or if all usable inventory is consumed while entering the range, the planner returns that one-sided entry swap directly.

### 4.5. Early Returns and Bounds

The planner returns an all-zero plan when:

- pool liquidity is zero
- the current bundle already scores as balanced for the requested range

Returned swap amounts are always clamped to the caller's original `amount0` / `amount1` balances.

---

## 5. Practical Integration

The planner is used by:

- `CLManager.openPosition`
- `CLManager.addCollateral`
- `CLManager.compoundFees`
- `CLManager.changeRange`

Adapters receive the resulting `RebalanceParams` and execute any required rebalance swap before minting or increasing liquidity.

---

## 6. Operational Notes

- The planner is deterministic for a given pool state and token bundle
- Dust handling remains outside the planner and is handled by manager/adapter flows
- The planner reads `slot0()` through a low-level staticcall so it can decode only `sqrtPriceX96` and `tick` across pool variants with different return layouts
- Invalid pool wiring, invalid ticks, missing DEX adapter wiring, unreadable `slot0`, or missing fee data all hard-fail before solving
- The owner can tune the exact walk depth via `setMaxWalkTicks(uint256)`
- Token ordering is normalized internally, so callers do not need to pre-sort supplied amounts as long as token addresses are correct