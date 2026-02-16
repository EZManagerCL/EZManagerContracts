// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*
    Lens that sits in front of CLCore and exposes a compact, stable
    output struct for DeBank (and other indexers).

    Design goals:
    - Stable ABI even if CLCore.PositionDetails evolves.
    - Single paginated read to enumerate all user positions.
    - Self-contained position snapshot (IDs, pool/tokens, ticks, balances, accounting).
*/

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";

interface ICLCore {
    // IMPORTANT: Must match CLCore exactly (field order/types).
    struct PositionDetails {
        bytes32 key;
        address owner;
        uint256 tokenId;
        address pool;
        address token0;
        address token1;
        uint24 fee;
        int24 tickSpacing;
        int24 tickLower;
        int24 tickUpper;
        int24 currentTick;
        uint128 liquidity;
        uint128 tokensOwed0;
        uint128 tokensOwed1;
        uint256 pendingFees0;
        uint256 pendingFees1;
        uint256 pendingFeesUSDC;
        uint256 amount0Now;
        uint256 amount1Now;
        uint256 valueUSDCNow;
        uint256 dustUSDC;
        uint256 totalDepositedUSDC;
        uint256 openedAt;
        address dex;
        bool botAllowed;
    }

    function listUserPositionKeys(address user) external view returns (bytes32[] memory);
    function getPositionDetails(bytes32 key) external view returns (PositionDetails memory);
}

contract Lens is Ownable {
    /// @dev The CLCore contract this lens reads from.
    ICLCore public immutable core;

    /*
        Stable output struct for DeBank integrations.

        Ordering:
        1) Identity
        2) Location
        3) Range / state
        4) Token balances
        5) Fees
        6) Accounting (USDC)
        7) Flags
    */
    struct LensPosition {
        // 1) Identity
        bytes32 key;
        uint256 tokenId;

        // 2) Location
        address pool;
        address token0;
        address token1;

        // 3) Range / state
        int24 tickLower;
        int24 tickUpper;
        int24 currentTick;

        // 4) Token balances
        uint256 amount0;
        uint256 amount1;

        // 5) Fees
        uint256 pending0;
        uint256 pending1;
        uint256 pendingFeesUSDC;

        // 6) Accounting (USDC)
        uint256 valueUSDC;
        uint256 totalDepositedUSDC;
        uint256 dustUSDC;

        // 7) Flags
        bool botAllowed;
    }

    /// @notice Constructor sets owner and core permanently.
    /// @param owner_ Owner of the lens.
    /// @param core_ CLCore address.
    constructor(address owner_, address core_) Ownable(owner_) {
        require(owner_ != address(0), "Lens: zero owner");
        require(core_ != address(0), "Lens: zero core");
        core = ICLCore(core_);
    }

    /// @notice Paginated position details for a user.
    /// @param user Wallet to query.
    /// @param cursor Zero-based index into the user's position keys list.
    /// @param limit Max number of positions to return.
    /// @return positions Up to `limit` LensPosition items.
    /// @return nextCursor Cursor for the next page (equals total length when finished).
    function getUserPositionDetailsPaginated(
        address user,
        uint256 cursor,
        uint256 limit
    ) external view returns (LensPosition[] memory positions, uint256 nextCursor) {
        bytes32[] memory keys = core.listUserPositionKeys(user);
        uint256 n = keys.length;

        if (limit == 0 || cursor >= n) {
            return (new LensPosition[](0), cursor);
        }

        uint256 end = cursor + limit;
        if (end > n) end = n;

        uint256 outLen = end - cursor;
        positions = new LensPosition[](outLen);

        for (uint256 i = 0; i < outLen; ) {
            bytes32 key = keys[cursor + i];
            ICLCore.PositionDetails memory p = core.getPositionDetails(key);

            positions[i] = LensPosition({
                // 1) Identity
                key: key,
                tokenId: p.tokenId,

                // 2) Location
                pool: p.pool,
                token0: p.token0,
                token1: p.token1,

                // 3) Range / state
                tickLower: p.tickLower,
                tickUpper: p.tickUpper,
                currentTick: p.currentTick,

                // 4) Token balances
                amount0: p.amount0Now,
                amount1: p.amount1Now,

                // 5) Fees
                pending0: p.pendingFees0,
                pending1: p.pendingFees1,
                pendingFeesUSDC: p.pendingFeesUSDC,

                // 6) Accounting
                valueUSDC: p.valueUSDCNow,
                totalDepositedUSDC: p.totalDepositedUSDC,
                dustUSDC: p.dustUSDC,

                // 7) Flags
                botAllowed: p.botAllowed
            });

            unchecked {
                ++i;
            }
        }

        nextCursor = end;
    }
}
