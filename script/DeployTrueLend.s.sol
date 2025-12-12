// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

import {TrueLendHook} from "../src/TrueLendHook.sol";
import {TrueLendRouter} from "../src/TrueLendRouter.sol";

/// @notice Deploys TrueLendHook with proper address mining for hook flags
contract DeployTrueLend is Script {
    // Standard CREATE2 deployer
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    
    // Pool Manager addresses per chain
    address constant POOL_MANAGER_SEPOLIA = 0x8C4BcBE6b9eF47855f97E675296FA3F6fafa5F1A;
    
    function run() external {
        // Get private key and pool manager
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address poolManager = getPoolManager();
        
        // Hook needs BEFORE_SWAP and AFTER_SWAP permissions
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        );
        
        console.log("Mining hook address with flags:", flags);
        console.log("This may take a few minutes...");
        
        // Mine a salt that will produce a hook address with the correct flags
        bytes memory constructorArgs = abi.encode(poolManager);
        (address hookAddress, bytes32 salt) = HookMiner.find(
            CREATE2_DEPLOYER,
            flags,
            type(TrueLendHook).creationCode,
            constructorArgs
        );
        
        console.log("Found valid hook address:", hookAddress);
        console.log("Salt:", uint256(salt));
        
        // Deploy contracts
        vm.startBroadcast(privateKey);
        
        // Deploy hook using the mined salt
        TrueLendHook hook = new TrueLendHook{salt: salt}(IPoolManager(poolManager));
        require(address(hook) == hookAddress, "Hook address mismatch");
        
        // Deploy router
        TrueLendRouter router = new TrueLendRouter(address(hook));
        
        // Approve router in hook
        hook.setLendingRouter(address(router), true);
        
        vm.stopBroadcast();
        
        // Log deployed addresses
        console.log("");
        console.log("======================");
        console.log("TrueLend Deployed!");
        console.log("======================");
        console.log("Hook address:", address(hook));
        console.log("Router address:", address(router));
        console.log("Pool Manager:", poolManager);
        console.log("======================");
        console.log("");
        console.log("Next steps:");
        console.log("1. Create pool with this hook");
        console.log("2. Add liquidity to the pool");
        console.log("3. Use router.borrow() to create positions");
    }
    
    function getPoolManager() internal view returns (address) {
        uint256 chainId = block.chainid;
        
        if (chainId == 11155111) { // Sepolia
            return POOL_MANAGER_SEPOLIA;
        } else if (chainId == 1) { // Mainnet
            revert("Mainnet not configured yet");
        } else if (chainId == 31337) { // Anvil/Local
            revert("For local testing, deploy PoolManager first or use test suite");
        }
        
        revert("Unsupported chain");
    }
}
