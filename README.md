# CuratorVault

Mutual funds for Uniswap v4 liquidity — an active-management hook built for UHI11.

## What it does

Depositors put token0/token1 into an ERC20 vault and receive shares. A verified curator manages a single concentrated liquidity position through a strategy module. The hook enforces the mandate at the pool level:

- Only the vault may add/remove liquidity.
- Range width and rebalance frequency are bounded on-chain.
- Curator actions require a stake-backed, verifier-approved registry entry.
- Dynamic LP fees rise when pool price deviates from an EMA reference.
- NAV uses the hook EMA price; performance fees require both a new high-water mark and an outperformance of the HODL benchmark.

## Architecture

- `src/CuratorVaultHook.sol` — Uniswap v4 hook: permissions, gating, guardrails, dynamic fees, EMA.
- `src/CuratorVault.sol` — ERC20 share vault; deposit/withdraw; HODL benchmark; unlock callback for liquidity management.
- `src/CuratorRegistry.sol` — locked stake plus verifier approval; hook reads `isApproved` before liquidity changes.
- `src/SimpleRangeStrategy.sol` — curator-controlled rebalancing with drift/cooldown checks.
- `src/mocks/MockBrevisVerifier.sol` — stand-in for Brevis ZK callback.
- `src/mocks/CREATE2Deployer.sol` — CREATE2 factory for mining hook permission bits.
- `src/mocks/SwapHelper.sol` — test-only swap helper.

Hook permissions required: `BEFORE_ADD_LIQUIDITY | AFTER_ADD_LIQUIDITY | BEFORE_REMOVE_LIQUIDITY | AFTER_REMOVE_LIQUIDITY | BEFORE_SWAP | AFTER_SWAP` = `0xfc0`.

## Build & Test

```sh
forge build
forge test -vv
```

21 CuratorVault tests (plus 2 scaffold tests) cover: permission mining, wiring, registry staking/revocation, verification gating, deposit/withdraw, position init, out-of-range withdrawal, dynamic fee event, rebalance cooldown, HODL benchmark, fee authorization, fuzz cases, and high-water mark behavior.

## Deploy

```sh
export PRIVATE_KEY=0x...
forge script script/DeployCuratorVault.s.sol --rpc-url <RPC> --broadcast
```

The script mines a CREATE2 salt so the hook address ends in the required permission bits, deploys PoolManager + test tokens + hook + vault + strategy + verifier + registry, initializes the pool with `LPFeeLibrary.DYNAMIC_FEE_FLAG`, registers the supported pool, and wires all contracts.

For local simulation (no broadcast):

```sh
PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
  forge script script/DeployCuratorVault.s.sol -vvv
```

## Dashboard

A lightweight web dashboard is in `dashboard/`. Serve it with any static server:

```sh
cd dashboard
python3 -m http.server 8080
```

Open `http://localhost:8080`, connect MetaMask, paste contract addresses from the deploy output, and use the UI to stake for the strategy, verify scores, deposit, withdraw, and manage positions.

## Limitations

- `MockBrevisVerifier` is not a real ZK verifier; replace with the Brevis callback for production.
- Registry stake is locked and is a demo bonding primitive, not a full slashing design.
- Holdings are assumed to be 18-decimal tokens in NAV math.
- The vault manages one position with a fixed salt.

## Threat Model

- Hook wiring is owner-set once; after setup, only the pool manager can call liquidity hooks and only the vault can pass the sender gate.
- The registry verifier can approve or revoke curators but cannot withdraw locked stake; there is no slashing in the demo.
- The mock verifier is intentionally trusted and is only for the demo; production must verify a real Brevis proof before approval.
- NAV and dynamic fees use the hook EMA price rather than spot, reducing single-block price manipulation, but a slow EMA can lag during volatile moves.
- Performance fees are capped by the hook at 1000 bps (10%) in the demo wiring and are authorized only when both the high-water mark and HODL benchmark are beaten.
- NAV math assumes both tokens have 18 decimals.

## Demo Script

```sh
export PATH="$HOME/.foundry/bin:$PATH"
anvil
```

In a second terminal:

```sh
cd ~/curator-vault
export PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
forge script script/DeployCuratorVault.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
forge test -vv
cd dashboard && python3 -m http.server 8080
```

Paste the printed addresses into the dashboard, connect MetaMask to Anvil, stake for the strategy, submit a verification score, deposit, initialize the position, swap externally to move the EMA, and withdraw to see benchmarked fees.

## Credits

Built with Uniswap v4, Foundry, OpenZeppelin, and a Brevis-style verification flow. The local proof path uses a disclosed mock verifier.
