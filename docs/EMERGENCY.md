# Emergency Response Plan

This document outlines the protocol's response procedures in the event of a critical exploit or security incident.

### 1. Immediate Actions
- **Pause All Contracts:**
  - The protocol designated guardian (multisig) will immediately pause all relevant contracts using the built-in `pause()` function. This halts all non-emergency operations and prevents further damage or exploitation.

### 2. User Withdrawals During Emergency
- **Unstoppable NFT Withdrawals:**
  - Even while the protocol is paused, users can withdraw their position NFTs (and any tracked dust) using the `returnNft(bytes32[] calldata keys)` function in `CLManager.sol`.
  - This function is always available, even when the protocol is paused, ensuring users can reclaim their assets at any time.
  - This function uses try/catch for any calls that interact with Valuation or non-essential accounting flows (pending fee/value snapshots), so valuation failures cannot brick NFT recovery.
  - `CLCore.returnPosition` transfers the NFT back to the owner using `safeTransferFrom`; if the owner is a contract, it must implement `IERC721Receiver` to receive the NFT.

### 3. Multisig/Timelock Emergency Powers
- **Admin-Assisted Withdrawals:**
  - If a new `CLCore.sol` contract needs to be deployed to fix an exploit, the protocol's timelocked multisig can execute `returnNft(bytes32[] calldata keys)` on users' behalf if and only if the protocol is paused.
  - This ensures no user positions are ever stuck in the protocol, even in the event of a catastrophic failure or required contract migration.

### 4. Post-Incident Recovery
- **Fix and Redeploy:**
  - After the exploit is contained and all user positions are safely withdrawn, the protocol team will patch the vulnerability, redeploy contracts, and coordinate a migration plan.

### 5. Communication
- **Transparency:**
  - The team will provide timely updates via official channels, including incident details, user instructions, and recovery timelines.

---

**Summary:**
- All state changing contracts can be paused instantly.
- Users can always withdraw their position NFTs, even when paused.
- The timelocked multisig can assist with withdrawals if needed.
- No user assets will be left stranded in the protocol.
