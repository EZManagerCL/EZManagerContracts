# Pool Lifecycle and Administrative Guidance

This document describes the protocol's canonical administrative model for tracking and managing pools in `CLCore` (the `allowedPools` registry). It explains lifecycle statuses, how to set them, expected on-chain behaviour, and operational best-practices for safely introducing, phasing out, and removing pools.

Summary
- `CLCore` tracks pool addresses in a single registry named `allowedPools`.
- Each pool has a lifecycle `PoolStatus` with the values: `NotAllowed`, `Allowed`, `Deprecated`.
- `isPoolAllowed(pool)` returns `true` for `Allowed` and `Deprecated` pools so read-only flows (valuation, monitoring) continue to function.
- `isPoolDeprecated(pool)` is a helper used by `CLManager` to block opening new positions on `Deprecated` pools; existing positions remain supported for normal maintenance and exits.
- Admins change a pool's lifecycle by calling `CLCore.setPoolStatus(address pool, PoolStatus status)` which emits `PoolStatusUpdated(pool, status)`.

Statuses and Semantics
- `NotAllowed` (default)
  - The pool is not tracked by the protocol. Most operations that require a tracked pool will revert with `PoolNotAllowed`.
  - Use this to represent unregistered or fully removed pools.

- `Allowed`
  - The pool is fully supported for new position openings, valuation, swaps, and all read/write flows.
  - This is the normal operational status for production pools.

- `Deprecated` ("Phasing out")
  - The pool is still usable for read-only flows (valuation, monitoring) and existing positions remain supported for maintenance (collect, compound, changeRange) and exit.
  - New position openings are disallowed. `CLManager.openPosition` will call `CLCore.isPoolDeprecated(pool)` and revert with `PoolDeprecated` when attempting to open new positions on a `Deprecated` pool.
  - Use this status when you intend to gracefully stop onboarding new liquidity into a pool without disrupting existing positions.

- `NotAllowed`
  - The pool is explicitly not allowed or untracked and should be treated as unusable by both read and write flows.
  - Operations that depend on pool being tracked will revert with `PoolNotAllowed`.
  - Use this status for removing pools when there are no currently open positions on them.

Admin Workflow
1. Adding a new production pool
   - Call `CLCore.setPoolStatus(pool, CLCore.PoolStatus.Allowed)` to register and mark as Allowed.
   - Off-chain systems should index `PoolStatusUpdated` events and refresh valuations and adapter routing after the change.

2. Phasing out a pool (graceful deprecation)
   - Call `CLCore.setPoolStatus(pool, CLCore.PoolStatus.Deprecated)`.
   - This prevents new opens while allowing current positions to be serviced and exited.
   - Notify integrators to avoid presenting the pool as an option for new users.
   - Do not remove this status unless there are no positions in the system on the deprecated pool.

3. Revoking or removing a pool
  - Call `CLCore.setPoolStatus(pool, CLCore.PoolStatus.NotAllowed)` to fully revoke or untrack.
  - Optionally, later set to `NotAllowed` to remove it from `listAllowedPools()` enumeration if desired.

Events and Monitoring
- `PoolStatusUpdated(address indexed pool, PoolStatus status)` is emitted on every status change.
- Off-chain indexers should treat `PoolStatusUpdated` as the canonical source of truth for pool lifecycle.
- For monitoring:
  - Alert on transitions: `Allowed -> Deprecated` and `Deprecated -> NotAllowed`.
  - Ensure dashboards and UIs hide pools marked `Deprecated` from lists of pools to open for new positions.

UI/UX Guidance
- When a pool is `Deprecated`, show existing user positions normally but remove the pool from "open new position" pickers.
- If a pool is `NotAllowed`, surface an urgent notice and provide explicit guidance for owners to exit their positions.

Operational Notes
- Prefer `Deprecated` to an immediate `NotAllowed` state when removing a pool from future onboarding; it enables graceful migration for existing position owners and avoids surprising users.
- Use `NotAllowed` for emergency or compliance-driven removals.
- Consider coordinating deprecation with liquidity providers and external indexers to avoid frontend surprises.

Examples (Admin CLI)
- Mark as allowed:
  - `clCore.setPoolStatus(POOL_ADDRESS, CLCore.PoolStatus.Allowed)`
- Deprecate a pool:
  - `clCore.setPoolStatus(POOL_ADDRESS, CLCore.PoolStatus.Deprecated)`
- Revoke a pool:
  - `clCore.setPoolStatus(POOL_ADDRESS, CLCore.PoolStatus.NotAllowed)`

Security Considerations
- Only the protocol owner (timelock multisig) should call `setPoolStatus`.
- Record all status changes in off-chain change logs and cross-reference with on-chain `PoolStatusUpdated` events for auditability.

FAQs
- Q: Why keep `Deprecated` visible to valuation/read-only flows?
  - A: Valuation and monitoring should continue to work for existing positions even when new positions are blocked. This preserves off-chain accounting and allows proper exits and maintenance.

- Q: Can `Deprecated` pools later be re-enabled?
  - A: Yes — an admin may set the status back to `Allowed` if desired.


