# SteadyLP

SteadyLP is a Uniswap v4 hook that protects long-term LPs from impermanent loss and concentrated liquidity attacks.
It smooths real swap fees over time and directs part of the value into a shared protection reserve.
When LPs face toxic flow, sudden price moves, or short-term JIT liquidity attacks, the hook can reduce abuse and partially compensate eligible long-term LPs.
No fixed APY. No fake yield. No speculative hedging. Just real fees, transparent rules, and safer liquidity.

## How It Works Today

1. Position and pool tracking

SteadyLP stores per-pool state in `PoolState` and `ReserveState`, and per-position state in `PositionInfo`.
For each tracked position it records the operator, liquidity, `tickLower`, `tickUpper`, `addedAt`, `addedAtBlock`, `lastRiskBlock`, reward accounting, and protection eligibility.
The hook position key is derived from `poolId`, operator, ticks, and salt.
In the current v4 template flow, the real position salt used by the `PositionManager` is `bytes32(tokenId)`.

2. Adding liquidity

The hook uses `afterAddLiquidity` to register or update a position.
It increases the pool's tracked liquidity, stores the add timestamp and block, and checks whether the position is a narrow range around the active tick.
A position is flagged as risky when the current tick sits inside the range and the range width is below the configured `narrowRangeTicks` threshold.
Risky positions are marked with `riskyRange = true` and become ineligible for protection.

3. Early liquidity removal

The hook uses `beforeRemoveLiquidity`.
In the current MVP, early removal does not revert.
Instead, if liquidity is removed before `minHoldingPeriod`, the position loses protection eligibility.
This is the current anti-short-term farming rule: fast exit is allowed, but protection is lost.

4. Fee smoothing

SteadyLP does not invent yield on its own.
The smoothing bucket is now funded directly from swaps when the hook captures a configurable portion of the swap flow.
That captured amount is split automatically, with one share sent to the shared reserve and the other sent to smoothing.
Manual top-ups through `depositFeeInflow(...)` are still available for testing, donations, or bootstrapping.
Smoothed inflows are released linearly over `smoothingPeriod` and distributed through dual `rewardPerLiquidity` accumulators for token0 and token1.
LPs can only claim the portion that has already been released with `claimReleasedFees(...)`, and can preview it with `previewClaimableFees(...)`.

5. Shared protection reserve

The shared reserve is now funded directly from the swap fee captured by the hook, based on the configured split ratio, and it keeps separate token0 and token1 balances.
It can still be topped up manually through `depositReserve(...)`.
Eligible LPs can preview and claim partial compensation with `previewCompensation(...)` and `claimCompensation(...)`.
Compensation is capped by policy through `maxCoverageBps` and also capped by the actual reserve balance.
The reserve never goes negative, and the hook never guarantees full loss coverage.

6. Toxic flow and volatility protection

The hook uses `beforeSwap` and `afterSwap` to watch for abnormal conditions.
It activates a temporary risk mode when a swap exceeds `largeSwapThreshold` or when observed tick movement exceeds `priceMoveTickThreshold`.
While risk mode is active, the hook can return a higher dynamic LP fee override when the pool itself is configured as a dynamic-fee pool.
The mode expires automatically after `riskModeBlocks`.

7. What it does not do

This MVP does not offer fixed APY, guaranteed yield, external hedging, leverage, or synthetic rewards.
It does not loop over all LPs.
It does not allow uncapped reserve payouts.
All payouts depend on real deposited value and explicit policy limits.

8. Current MVP limits

This version is intentionally simple and hackathon-ready.
The hook currently captures a configurable extra swap fee in whichever pool token is the swap's unspecified output and splits it between that token's reserve bucket and smoothing bucket, instead of reading and reallocating the pool's native LP fee accounting directly.
The manual `previewCompensation(...)` and `claimCompensation(...)` path still accepts a user-supplied loss input for testing, but the remove-liquidity protection path now also reserves compensation from the hook's internal oracle and requires a separate direct claim.
The anti-JIT model is currently based on narrow-range detection, minimum-hold eligibility rules, and temporary risk mode rather than a more advanced scoring system.
Compensation is still valued internally in token0-equivalent terms before being split across token0 and token1 reserves.

## Uniswap v4 Template Notes

**Original template setup and workflow**

### Get Started

This template provides a starting point for writing Uniswap v4 Hooks, including a simple example and preconfigured test environment. Start by creating a new repository using the "Use this template" button at the top right of this page. Alternatively you can also click this link:

[![Use this Template](https://img.shields.io/badge/Use%20this%20Template-101010?style=for-the-badge&logo=github)](https://github.com/uniswapfoundation/v4-template/generate)

1. The example hook [Counter.sol](src/Counter.sol) demonstrates the `beforeSwap()` and `afterSwap()` hooks
2. The test template [Counter.t.sol](test/Counter.t.sol) preconfigures the v4 pool manager, test tokens, and test liquidity.

<details>
<summary>Updating to v4-template:latest</summary>

This template is actively maintained -- you can update the v4 dependencies, scripts, and helpers:

```bash
git remote add template https://github.com/uniswapfoundation/v4-template
git fetch template
git merge template/main <BRANCH> --allow-unrelated-histories
```

</details>

### Requirements

This template is designed to work with Foundry (stable). If you are using Foundry Nightly, you may encounter compatibility issues. You can update your Foundry installation to the latest stable version by running:

```
foundryup
```

To set up the project, run the following commands in your terminal to install dependencies and run the tests:

```
forge install
forge test
```

### Local Development

Other than writing unit tests (recommended!), you can only deploy & test hooks on [anvil](https://book.getfoundry.sh/anvil/) locally. Scripts are available in the `script/` directory, which can be used to deploy hooks, create pools, provide liquidity and swap tokens. The scripts support both local `anvil` environment as well as running them directly on a production network.

### Executing locally with using **Anvil**:

1. Start Anvil (or fork a specific chain using anvil):

```bash
anvil
```

or

```bash
anvil --fork-url <YOUR_RPC_URL>
```

2. Execute scripts:

```bash
forge script script/00_DeployHook.s.sol \
    --rpc-url http://localhost:8545 \
    --private-key <PRIVATE_KEY> \
    --broadcast
```

### Using **RPC URLs** (actual transactions):

:::info
It is best to not store your private key even in .env or enter it directly in the command line. Instead use the `--account` flag to select your private key from your keystore.
:::

### Follow these steps if you have not stored your private key in the keystore:

<details>

1. Add your private key to the keystore:

```bash
cast wallet import <SET_A_NAME_FOR_KEY> --interactive
```

2. You will prompted to enter your private key and set a password, fill and press enter:

```
Enter private key: <YOUR_PRIVATE_KEY>
Enter keystore password: <SET_NEW_PASSWORD>
```

You should see this:

```
`<YOUR_WALLET_PRIVATE_KEY_NAME>` keystore was saved successfully. Address: <YOUR_WALLET_ADDRESS>
```

::: warning
Use `history -c` to clear your command history.
:::

</details>

1. Execute scripts:

```bash
forge script script/00_DeployHook.s.sol \
    --rpc-url <YOUR_RPC_URL> \
    --account <YOUR_WALLET_PRIVATE_KEY_NAME> \
    --sender <YOUR_WALLET_ADDRESS> \
    --broadcast
```

You will prompted to enter your wallet password, fill and press enter:

```
Enter keystore password: <YOUR_PASSWORD>
```

### Key Modifications to note:

1. Update the `token0` and `token1` addresses in the `BaseScript.sol` file to match the tokens you want to use in the network of your choice for sepolia and mainnet deployments.
2. Update the `token0Amount` and `token1Amount` in the `CreatePoolAndAddLiquidity.s.sol` file to match the amount of tokens you want to provide liquidity with.
3. Update the `token0Amount` and `token1Amount` in the `AddLiquidity.s.sol` file to match the amount of tokens you want to provide liquidity with.
4. Update the `amountIn` and `amountOutMin` in the `Swap.s.sol` file to match the amount of tokens you want to swap.

### Verifying the hook contract

```bash
forge verify-contract \
  --rpc-url <URL> \
  --chain <CHAIN_NAME_OR_ID> \
  # Generally etherscan
  --verifier <Verification_Provider> \
  # Use --etherscan-api-key <ETHERSCAN_API_KEY> if you are using etherscan
  --verifier-api-key <Verification_Provider_API_KEY> \
  --constructor-args <ABI_ENCODED_ARGS> \
  --num-of-optimizations <OPTIMIZER_RUNS> \
  <Contract_Address> \
  <path/to/Contract.sol:ContractName>
  --watch
```

### Troubleshooting

<details>

#### Permission Denied

When installing dependencies with `forge install`, Github may throw a `Permission Denied` error

Typically caused by missing Github SSH keys, and can be resolved by following the steps [here](https://docs.github.com/en/github/authenticating-to-github/connecting-to-github-with-ssh)

Or [adding the keys to your ssh-agent](https://docs.github.com/en/authentication/connecting-to-github-with-ssh/generating-a-new-ssh-key-and-adding-it-to-the-ssh-agent#adding-your-ssh-key-to-the-ssh-agent), if you have already uploaded SSH keys

#### Anvil fork test failures

Some versions of Foundry may limit contract code size to ~25kb, which could prevent local tests to fail. You can resolve this by setting the `code-size-limit` flag

```
anvil --code-size-limit 40000
```

#### Hook deployment failures

Hook deployment failures are caused by incorrect flags or incorrect salt mining

1. Verify the flags are in agreement:
   - `getHookCalls()` returns the correct flags
   - `flags` provided to `HookMiner.find(...)`
2. Verify salt mining is correct:
   - In **forge test**: the _deployer_ for: `new Hook{salt: salt}(...)` and `HookMiner.find(deployer, ...)` are the same. This will be `address(this)`. If using `vm.prank`, the deployer will be the pranking address
   - In **forge script**: the deployer must be the CREATE2 Proxy: `0x4e59b44847b379578588920cA78FbF26c0B4956C`
     - If anvil does not have the CREATE2 deployer, your foundry may be out of date. You can update it with `foundryup`

</details>

### Additional Resources

- [Uniswap v4 docs](https://docs.uniswap.org/contracts/v4/overview)
- [v4-periphery](https://github.com/uniswap/v4-periphery)
- [v4-core](https://github.com/uniswap/v4-core)
- [v4-by-example](https://v4-by-example.org)
