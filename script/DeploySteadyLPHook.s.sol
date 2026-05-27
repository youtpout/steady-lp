// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {BaseScript} from "./base/BaseScript.sol";
import {SteadyLPHook} from "../src/SteadyLPHook.sol";

/// @notice Mines the address and deploys the SteadyLPHook contract.
contract DeploySteadyLPHookScript is BaseScript {
    function run() public {
        uint160 flags = uint160(
            Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
                | Hooks.AFTER_SWAP_FLAG
        );

        SteadyLPHook.PoolConfig memory config = SteadyLPHook.PoolConfig({
            smoothingPeriod: 7 days,
            minHoldingPeriod: 1 days,
            riskModeBlocks: 20,
            narrowRangeTicks: 180,
            maxCoverageBps: 5_000,
            baseDynamicFee: 3_000,
            riskDynamicFee: 9_000,
            largeSwapThreshold: 5 ether,
            priceMoveTickThreshold: 120,
            payoutToken0: true
        });

        bytes memory constructorArgs = abi.encode(poolManager, config);
        (address hookAddress, bytes32 salt) =
            HookMiner.find(CREATE2_FACTORY, flags, type(SteadyLPHook).creationCode, constructorArgs);

        vm.startBroadcast();
        SteadyLPHook deployedHook = new SteadyLPHook{salt: salt}(poolManager, config);
        vm.stopBroadcast();

        require(address(deployedHook) == hookAddress, "DeploySteadyLPHookScript: Hook Address Mismatch");
    }
}
