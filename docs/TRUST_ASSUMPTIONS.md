# Trust Assumptions

This document records the protocol-level trust assumptions to use when reasoning about protocol security. These assumptions reflect the deployment and governance model used by the EZManager protocol.

1) Owner / Timelock (Administrative + Time-delayed)
- The protocol owner should be a Timelock contract. A Gnosis Safe multisig acts as the Timelock proposer/guardian.
- Owner (Timelock) powers:
  - Add or remove DEX adapters in `CLCore.allowedDexes`.
  - Add or remove pools in `CLCore.allowedPools`.
  - Add or remove bots in `CLCore.allowedBots`.
  - Configure `CLCore` fees (`protocolFeeBps`, `botFeeBps`) and set the `protocolReserve` address.
  - Set system contracts (`manager`, `valuation`, `EZWrapper`, `referralManager`) and the `guardian` address.

2) Guardian (Multisig Fast-Path)
- `guardian` is an on-chain address stored in `CLCore`, `CLManager`, `EZWrapper`, and `ReferralManager`. It is set to be a Gnosis Safe multisig.
- Guardian powers:
  - Call `pause()` / `unpause()` on `CLCore`, `CLManager`, `EZWrapper`, `ReferralManager`, and adapters to halt user-facing flows immediately.
  - Guardian is a fast-response control and does not replace the timelock for administrative, time-delayed governance.

3) `CLManager` (Trusted Execution Layer)
- `CLManager` is the canonical manager contract permitted to mutate `CLCore` state (it is the `manager` address recorded in `CLCore`).
- Only the `manager` may call `CLCore` functions that change position state (e.g., `registerPosition`, `deregisterPosition`, `addDustToPosition`, `withdrawDustForPosition`, `adjustTotalDeposited`, `setBotAllowedForPosition`).
- `CLManager` enforces reentrancy guards, pausability (`whenNotPaused`), slippage/min checks, and bot permission checks (`CLCore.allowedBots` + per-position `botAllowed`).
- `CLManager.openPositionEz` is restricted to the configured EZWrapper.

4) `EZWrapper` (Optional Wrapper)
- `EZWrapper` may own positions in `CLCore` while tracking the mapped user for each wrapper-owned key.
- Only `CLCore.manager()` may credit EZWrapper bot action proceeds.
- Bot action proceeds credited by CLManager are forwarded by EZWrapper to the mapped user.

5) `ReferralManager` (Persistent Referral Accounting)
- `ReferralManager` stores wallet referrers, configured referral shares, and referral balances independently from manager deployments.
- Only the configured manager may resolve/store manager-flow referrers and credit referral fees.
- Referrers claim referral balances directly from `ReferralManager`.
- The referral model is permissionless and does not attempt to prove distinct beneficial ownership across wallets. Self-referral through separate wallets is an accepted risk.

6) Adapters (DEX-specific logic)
- Adapters are trusted integrations and are whitelisted in `CLCore.allowedDexes` by the `owner`.

7) Bots (Permissioned, Opt-In)
- Bots are off-chain automation actors that must be allowlisted in `CLCore.allowedBots` by the `owner`.
- A bot can operate on a specific position only when the position's `botAllowed` flag is true (set via `CLCore.setBotAllowedForPosition`).

8) Zero-fee wallets & protocol reserve
- `CLManager.discountedFeeWallets` can be set by the `owner` to reduce nonzero protocol and bot fee bps, including 100% discounts for testing/promotions.
- `protocolReserve` (set by owner) receives protocol fees after any configured referral split.

9) Pools and Bridge Tokens
- Pools must be whitelisted by the `owner` in `CLCore.allowedPools` before they can be used for new positions.
- Any pools set to Allowed are well-established pools with high liquidity and standard ERC20s
- `CLCore.bridgeTokens` (managed by owner) are the permitted intermediate tokens for routing swaps.

10) Practical user-facing trust boundaries
- The primary trust boundary is the `owner` (timelock): it can whitelist adapters/pools/bots and change fees/admin parameters. The timelock delay is the main mitigation for owner misconfiguration.
- The `guardian` multisig can pause activity immediately to limit damage during an incident but cannot perform timelocked administrative operations.
- `CLManager` is trusted to perform state transitions correctly but can only do so within the guardrails enforced by `CLCore` (onlyManager pattern, pausability, slippage checks).
