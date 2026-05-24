# ReferralManager: Persistent Referral Accounting

This document describes the `ReferralManager` contract. `ReferralManager` is the persistent wallet-referrer registry and claimable referral balance book used by CLManager.

---

## 1. Purpose and Architecture

`ReferralManager` owns referral state that should survive CLManager or EZWrapper replacements:

- wallet-level referrer mapping
- default referrer
- referral share bps for earned-fee protocol fees
- copy referral share bps for copied opens
- claimable referral balances

Referral fees are a share of existing protocol fees. They do not add an extra user fee. EZWrapper does not store referral state or referral balances.

---

## 2. Wallet Referrers

Normal referral state is wallet-level:

- Each user wallet may have one stored referrer.
- Once a wallet referrer is stored, later candidates are ignored.
- If a user opens or imports with a valid candidate and no referrer is stored, that candidate is stored.
- If a user opens or imports with no candidate, a zero candidate, a self-referrer candidate, or a forbidden system-address candidate and no referrer is stored, the configured default referrer is stored.
- `referrerUserCount[referrer]` tracks the number of wallets assigned to each referrer for UI/display only. It does not affect payout rates.
- The default referrer is required system configuration. Opens and imports that need default-referrer resolution revert when the default referrer is not configured to a valid address.
- Manager open/import/copy flows revert if `ReferralManager` is not configured.
- `InvalidReferrer` is used when no valid referrer can be resolved, usually because the configured default referrer is unset or invalid.

Accepted risk: the protocol does not store same-address self-referrals as wallet referrers, but it does not try to prove that two different wallet addresses are controlled by different people. Preventing sybil self-referrals would require allowlists, signed referral codes, or identity checks that are intentionally outside this permissionless referral design.

Imports initialize wallet referrers, but do not charge protocol or referral fees.

For `addCollateral`, CLManager resolves the effective user's referrer through ReferralManager. If no referrer is stored, the configured default referrer is stored and used for later earned-fee referral attribution.

---

## 3. Earned-Fee Referral Credits

Referral payouts are credited when CLManager charges an earned-fee protocol fee and the effective user has a stored referrer.

Default referral parameter:

- `referralShareBps = 2_000`: the stored referrer receives 20% of the earned-fee protocol fee.

Formula:

```solidity
earnedProtocolFeeUSDC = realizedEarnedFeesUSDC * earnedFeesProtocolFeeBps / 10_000
referralFeeUSDC = earnedProtocolFeeUSDC * referralShareBps / 10_000
reserveFeeUSDC = earnedProtocolFeeUSDC - referralFeeUSDC
```

Earned-fee protocol fees can be charged when fees are collected, compounded, realized during removeCollateral, moved during changeRange, or collected during exit. The referral share is funded from the protocol fee amount; user proceeds are not charged an additional referral fee.

---

## 4. Copy Referral Attribution

`CLManager.copyPosition` uses the source position's effective owner as the candidate referrer:

- Directly owned source: the source position owner is the referrer.
- EZWrapper-owned source: the mapped user returned by `EZWrapper.userForKey(sourceKey)` is the referrer.

The effective source owner receives a one-time source reward funded from the copied open's capital-entry protocol fee. This reward uses `copyReferralShareBps`, which defaults to `5_000` (50% of the copied open's protocol fee). If the copier has no stored wallet referrer, the effective source owner is also stored as the copier's wallet referrer. Existing wallet referrers are preserved for later non-copy actions.

---

## 5. Crediting and Claiming

Only the configured manager may resolve/store referrers for manager flows or credit referral fees.

`ReferralManager.creditReferralFee` increments `referralBalances[referrer]` when `referralFeeUSDC` is nonzero and emits `ReferralFeeAccrued`.

Referrers claim USDC directly from `ReferralManager`:

- `claimReferralFees(uint256 amount)` transfers USDC to the caller.
- Referral balances cannot be claimed directly into a position.

---

## 6. Admin

- `setManager(address manager_)`: owner-only active CLManager setter.
- `setDefaultReferrer(address defaultReferrer_)`: owner-only default referrer setter.
- `setReferralShareBps(uint16 referralShareBps_)`: owner-only earned-fee referral share setter, capped at `10_000` bps.
- `setCopyReferralShareBps(uint16 copyReferralShareBps_)`: owner-only copy referral share setter, capped at `10_000` bps.
- `setGuardian(address guardian_)`: owner-only guardian setter.
- `pause()` / `unpause()`: guardian-only.

---

## 7. Events

- `GuardianUpdated`: guardian changed.
- `ManagerUpdated`: active manager changed.
- `DefaultReferrerUpdated`: default referrer changed.
- `ReferralShareBpsUpdated`: earned-fee referral share changed.
- `CopyReferralShareBpsUpdated`: copy referral share changed.
- `ReferrerSet`: wallet referrer initialized.
- `ReferrerUserCountUpdated`: assigned wallet count changed for a referrer.
- `ReferralFeeAccrued`: nonzero referral balance credit recorded.
- `ReferralFeesClaimed`: referral balance claimed.
