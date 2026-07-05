// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {LendingVault} from "./LendingVault.sol";

/// @notice Deploys LendingVaults on behalf of the hook, keeping the vault
/// creation code out of the hook's own bytecode.
contract VaultFactory {
    // default interest-rate model: base 0%, +4% to the 80% kink, +100% above,
    // hard utilization cap 90%, reserve factor 10%, rate ceiling 400% APR
    uint16 public constant BASE_RATE_BPS = 0;
    uint16 public constant SLOPE1_BPS = 400;
    uint16 public constant KINK_BPS = 8000;
    uint16 public constant SLOPE2_BPS = 10_000;
    uint16 public constant UTIL_CAP_BPS = 9000;
    uint16 public constant RESERVE_FACTOR_BPS = 1000;
    uint32 public constant RATE_CEILING_BPS = 40_000;

    function deploy(ERC20 asset, address hook) external returns (LendingVault) {
        return new LendingVault(
            asset,
            hook,
            BASE_RATE_BPS,
            SLOPE1_BPS,
            KINK_BPS,
            SLOPE2_BPS,
            UTIL_CAP_BPS,
            RESERVE_FACTOR_BPS,
            RATE_CEILING_BPS
        );
    }
}
