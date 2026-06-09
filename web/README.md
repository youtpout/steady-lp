# SteadyLP Console

Static interface for:

- initializing a new Uniswap v4 pool with the official `PositionManager`;
- previewing and claiming SteadyLP smoothed rewards;
- claiming reserved compensation or the MVP manual compensation flow.

Run locally:

```bash
cd web
python3 -m http.server 8080
```

Then open `http://localhost:8080`.

## Important limitations

- Pool creation initializes an empty pool. Adding liquidity remains a separate `PositionManager` operation.
- `SteadyLPHook.defaultPoolConfig` is currently defined when deploying the hook and shared by all its pools. A different SteadyLP configuration requires another hook deployment or a contract upgrade supporting per-pool configuration.
- The console loads ethers from a CDN and requires an EIP-1193 wallet.
