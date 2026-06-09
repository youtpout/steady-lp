# SteadyLP Console

Vite-powered dApp for:

- connecting browser extension wallets or mobile wallets through RainbowKit and WalletConnect;
- initializing a new Uniswap v4 pool, optionally with initial liquidity;
- approving ERC20s through Permit2;
- swapping through the official Universal Router;
- increasing, decreasing, collecting, or burning v4 positions;
- previewing and claiming SteadyLP smoothed rewards;
- claiming reserved compensation or the MVP manual compensation flow.

Run locally:

```bash
cd web
npm install
npm run dev
```

WalletConnect mobile support requires a free project ID:

```bash
cp .env.example .env
# Set VITE_WALLETCONNECT_PROJECT_ID in .env
```

Create the project ID at [WalletConnect Cloud](https://cloud.walletconnect.com). Browser extension wallets still work without it.

Build for production:

```bash
npm run build
```

## Important limitations

- Amounts are entered in raw token units. The dApp does not guess token decimals.
- Position discovery is not indexed by the hook. Enter the PositionManager NFT token ID and pool key.
- `SteadyLPHook.defaultPoolConfig` is currently defined when deploying the hook and shared by all its pools. A different SteadyLP configuration requires another hook deployment or a contract upgrade supporting per-pool configuration.
- Official contract addresses are filled only for known networks and remain editable. Verify them before signing.
- The manual loss compensation flow exists for the MVP contract but should not be exposed in a production deployment.
