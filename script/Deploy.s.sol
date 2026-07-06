// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";

import {TrueLendHook} from "../src/TrueLendHook.sol";
import {VaultFactory} from "../src/VaultFactory.sol";

/// Deploys the VaultFactory and the TrueLendHook at a mined address whose low
/// 14 bits encode the hook's permissions.
///
///   POOL_MANAGER=0x... forge script script/Deploy.s.sol --rpc-url $RPC --broadcast
contract Deploy is Script {
    address constant CREATE2_FACTORY_ADDRESS = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() external {
        IPoolManager poolManager = IPoolManager(vm.envAddress("POOL_MANAGER"));

        address owner = vm.envAddress("WALLET_ADDRESS");
        // canonical wrapped native (OP-stack chains incl. Unichain: 0x4200...0006)
        address weth = vm.envOr("WETH", address(0x4200000000000000000000000000000000000006));

        vm.startBroadcast();
        VaultFactory factory = new VaultFactory();

        uint160 flags = uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);
        bytes memory constructorArgs = abi.encode(poolManager, factory, owner, weth);
        (address hookAddress, bytes32 salt) =
            HookMiner.find(CREATE2_FACTORY_ADDRESS, flags, type(TrueLendHook).creationCode, constructorArgs);

        TrueLendHook hook = new TrueLendHook{salt: salt}(poolManager, factory, owner, weth);
        require(address(hook) == hookAddress, "hook address mismatch");
        vm.stopBroadcast();

        console.log("VaultFactory:", address(factory));
        console.log("TrueLendHook:", address(hook));
        console.log("owner:", hook.owner());
        console.log("(initialize any pool with this hook to enable lending on it)");
    }
}
