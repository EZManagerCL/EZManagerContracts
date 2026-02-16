# Security: Governance, Permissioning, and Operational Flows

Throughout the EZManager protocol, the contract owner is a Timelock contract, which is proposed to by a Gnosis Safe multisig. This ensures decentralized and robust control with a time delay for sensitive actions, while allowing the multisig to act quickly as a "guardian" for emergency pauses.

---

## 1. Governance Architecture

The protocol uses a two-tier governance structure to balance security and responsiveness:

1.  **Timelock (Owner)**
    *   Owns all core contracts (CLCore, CLManager, Adapters, Valuation, RebalancePlanner).
    *   Functions protected by  (e.g., changing fees, whitelisting adapters, allowing new pools) must go through the Timelock.
    *   Provides a time delay for users to exit if they disagree with a proposed change.

2.  **Multisig (Proposer & Guardian)**
    *   **Proposer**: The multisig is the proposer for the Timelock. It initiates actions that can be executed by the Timelock after the delay.
    *   **Guardian**: The multisig is directly assigned the `guardian` role on all contracts (CLCore, CLManager, Adapters). This allows it to call `pause()` and `unpause()` instantly, bypassing the Timelock delay for emergency response.

---

## 2. Permissioning and Roles

*   **Owner (Timelock)**: Has ultimate control over protocol configuration.
    *   Set Manager / Guardian
    *   Add/Remove Allowed Pools & Dexes
    *   Set Protocol/Bot Fees
    *   Configure Rebalance/Valuation params
*   **Guardian (Multisig)**: Has emergency control.
    *   Pause / Unpause contracts
*   **Manager (CLManager contract)**: The only address allowed to mutate `CLCore` state for position lifecycle.
*   **Bots**: Whitelisted addresses (added by Owner) that can perform specific maintenance tasks.
    *   Require two-layer permissioning: Global Allowlist (Core) + Per-Position Flag (User opt-in).

---

## 3. Pausable Pattern and Emergency Stops

*   All major contracts implement OpenZeppelin's `Pausable` if they have non-admin state changing operations.
*   **Who pauses?** Only the `guardian` (Multisig) can pause or unpause.
*   **Effect**: When paused, most state-changing user actions (open, exit, compound) revert with `EnforcedPause()`.
*   **Admin functions**: Generally remain available during a pause to allow for fixes or parameter updates.

---

## 4. Slippage Protection

*   **Oracle-Based**: All swaps and liquidity actions enforce slippage protection using on-chain TWAP (Time-Weighted Average Price) oracles derived from pool `observe()` data. Valuation/TWAP failures are treated as hard failures for pricing flows — operators should ensure pools used for oracle pricing have healthy TWAP observations.
*   **User-Defined**: Callers provide `slippageBps` (basis points).
*   **Enforcement**: Adapters compare actual outputs against oracle-derived minima. If the discrepancy exceeds the user's tolerance, the transaction reverts with `SlippageExceeded`.
*   **Budgeting**: When a flow requires multiple sequential operations, the protocol derives a per-flow USDC-denominated loss budget from `slippageBps` and consumes it sequentially based on realized shortfall vs TWAP-expected output. The remaining loss budget is carried forward through subsequent steps. See `docs/SLIPPAGE.md`.

---

## 5. Event Logging and Auditability

*   **Transparency**: All permissioning changes (adding bots, changing fees, updating allowlists) emit events.
*   **Monitoring**: Off-chain systems should monitor specific events like `ManagerUpdated`, and `GuardianUpdated` to detect governance actions.
