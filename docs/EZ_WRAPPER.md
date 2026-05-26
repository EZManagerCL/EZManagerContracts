# EZWrapper: Ez Flows

This document describes the optional `EZWrapper` contract. `CLManager` remains the main user entrypoint and system manager; `EZWrapper` is an additional user-facing wrapper that owns ez-flow positions in `CLCore` and maps those positions back to the user that opened them.

---

## 1. Purpose and Architecture

`EZWrapper` provides ez wrapper flows:

- `ezOpen`
- `ezAdd`
- `ezRemove`
- `ezExit`
- `ezReturnNft`

The `CLCore` position owner is `EZWrapper`, while `EZWrapper` tracks the user associated with each wrapper-owned key.

Referral state and referral balances are maintained by `ReferralManager`, not by `EZWrapper`. Copy trading is exposed on `CLManager.copyPosition`.

---

## 2. Ez User Flows

### 2.1. `ezOpen`

- Caller supplies USDC and an optional referrer.
- EZWrapper transfers the gross USDC amount from the caller.
- EZWrapper approves CLManager for the gross USDC amount.
- EZWrapper calls `CLManager.openPositionEz` with the real user address and supplied referrer.
- CLManager resolves and stores the user's wallet referrer through `ReferralManager` when needed, charges the capital-entry protocol fee to ProtocolReserve, and opens a wrapper-owned position.
- CLManager wallet discounts are evaluated against the registered position owner. For ez positions that owner is EZWrapper, so the mapped user's discount does not apply.
- The position is opened with `botAllowed = true`. This is an ez-mode tradeoff: wrapper users opt into bot control for these positions and cannot toggle the per-position flag directly because `EZWrapper` is the `CLCore` owner. Governance can still remove a compromised bot from the global allowlist.
- The returned key is stored for the caller and can be read with `getKeysForUser`.

### 2.2. `ezAdd`

- Only the user mapped to the key may add through EZWrapper.
- Caller supplies gross USDC.
- EZWrapper approves CLManager for the gross USDC amount.
- EZWrapper calls `CLManager.addCollateral`.
- CLManager resolves the mapped user's wallet referrer from `ReferralManager`, storing the default referrer first if none is set, charges the capital-entry protocol fee to ProtocolReserve, and adds the net amount as collateral.
- CLManager wallet discounts are evaluated against EZWrapper as the registered owner, not the mapped user.

### 2.3. `ezRemove`

- Only the user mapped to the key may remove through EZWrapper.
- EZWrapper calls `CLManager.removeCollateral`.
- Returned USDC received by EZWrapper is transferred to the mapped user.

### 2.4. `ezExit`

- Only the mapped user may exit the wrapper-owned key.
- EZWrapper calls `CLManager.exitPosition`.
- Returned USDC received by EZWrapper is transferred to the mapped user.
- The exited key is removed from EZWrapper's user-key tracking.

### 2.5. `ezReturnNft`

- Only the mapped user may request an emergency NFT return for a wrapper-owned key.
- In the user-initiated path, EZWrapper calls `CLManager.returnNft`, receives the LP NFT from `CLCore`, forwards the NFT to the mapped user, forwards any tracked dust refunded by `CLCore`, and removes the key from user-key tracking.
- In the protocol-owner emergency path, the protocol owner can call `CLManager.returnNft` while CLManager is paused. CLManager sends the returned NFT and dust to EZWrapper through `creditReturnedNft`; EZWrapper immediately forwards both to the mapped user and removes the key from user-key tracking.

---

## 3. Bot Action Proceeds

Wrapper-owned positions have `EZWrapper` as the `CLCore` owner. When a bot directly calls CLManager collect or exit for one of those positions, CLManager transfers the user's net proceeds to EZWrapper and calls `creditBotActionProceeds`.

- Only the configured `CLCore.manager()` may call `creditBotActionProceeds`.
- EZWrapper immediately forwards credited USDC to the mapped user.
- When CLManager reports a closed position, EZWrapper removes the key from user-key tracking.

---

## 4. Views and Admin

**Views:**
- `getKeysForUser(address user)`: returns wrapper-owned position keys tracked for a user.
- `userForKey(bytes32 key)`: returns the mapped user for a wrapper-owned key.
- `onERC721Received(...)`: accepts LP NFTs returned from `CLCore` during `ezReturnNft`.

**Admin:**
- `setGuardian(address guardian_)`: owner-only.
- `pause()` / `unpause()`: guardian-only.

---

## 5. Events

- `GuardianUpdated`: guardian changed.
- `BotActionProceedsForwarded`: proceeds from direct bot collect/exit forwarded to a mapped user.
- `EzPositionOpened`: ez position opened and stored for a user.
- `EzCollateralAdded`: ez collateral addition processed.
- `EzCollateralRemoved`: ez collateral removal processed.
- `EzPositionExited`: ez exit processed.
- `EzNftReturned`: LP NFT and dust returned to the mapped user.
