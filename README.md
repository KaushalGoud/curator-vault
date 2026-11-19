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
- `src/BrevisCuratorVerifier.sol` — ZK callback that approves a staked curator after a Brevis proof.
- `src/brevis/BrevisAppZkOnly.sol` — MIT-licensed Brevis callback base copied from the official SDK.
- `brevis/prover/circuits/circuit.go` — Brevis circuit proving that the strategy emitted rebalance events from the hook in a block range.
- `brevis/app/src/index.ts` — proof request submitter and on-chain `BrevisRequest.sendRequest` helper.
- `src/mocks/MockBrevisVerifier.sol` — disclosed local-demo stand-in for the Brevis callback.
- `src/mocks/CREATE2Deployer.sol` — CREATE2 factory for mining hook permission bits.
- `src/mocks/SwapHelper.sol` — test-only swap helper.

Hook permissions required: `BEFORE_ADD_LIQUIDITY | AFTER_ADD_LIQUIDITY | BEFORE_REMOVE_LIQUIDITY | AFTER_REMOVE_LIQUIDITY | BEFORE_SWAP | AFTER_SWAP` = `0xfc0`.

## Build & Test

```sh
forge build
forge test -vv
```

30 tests total cover: permission mining, wiring, registry staking/revocation, verification gating, Brevis callback authorization/vk/range/replay checks, deposit/withdraw, position init, out-of-range withdrawal, dynamic fee event, rebalance cooldown, HODL benchmark, fee authorization, fuzz cases, and high-water mark behavior.

## Deploy

```sh
export PRIVATE_KEY=0x...
forge script script/DeployCuratorVault.s.sol --rpc-url <RPC> --broadcast
```

The script mines a CREATE2 salt so the hook address ends in the required permission bits, deploys PoolManager + test tokens + hook + vault + strategy + verifier + registry, initializes the pool with `LPFeeLibrary.DYNAMIC_FEE_FLAG`, registers the supported pool, and wires all contracts. `MIN_REBALANCE_INTERVAL` and `STRATEGY_COOLDOWN` default to `1 hours` and can be shortened for testnet demos.

For local simulation (no broadcast):

```sh
PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
  forge script script/DeployCuratorVault.s.sol -vvv
```

## Brevis proof path

The honest Brevis claim is intentionally smaller than “proved outperformance”: the circuit proves that a named strategy address appeared as topic 2 in at least `MIN_REBALANCES` `RebalanceExecuted(bytes32,address,int24,int24)` events from the pinned hook within a bounded block range. The vault separately measures outperformance against HODL through its benchmark and high-water mark.

The default `DeployCuratorVault.s.sol` path keeps the disclosed mock verifier for local demos. To use the real callback, deploy and point the registry at it:

```sh
export PRIVATE_KEY=0x...
export REGISTRY=<registry address>
export HOOK=<hook address>
export BREVIS_VK_HASH=<vk hash from prover setup>
forge script script/DeployBrevisVerifier.s.sol --rpc-url <RPC> --broadcast
```

The script defaults to the legacy Sepolia `BrevisRequest` at `0x841ce48F9446C8E281D3F1444cB859b4A6D0738C`; override with `BREVIS_REQUEST` for another supported network. The legacy path uses `brevis-sdk-typescript` 1.2.5 with `GATEWAY=appsdkv2.brevis.network:9094`; the current production-style Brevis deployment uses Go SDK 0.3.17+, `appsdkv3.brevis.network:443`, and `BrevisRequest` at `0x91540fe35a245ba83459f6410c86f1aec309b290` on Arbitrum with Ethereum-mainnet source data. During final testing the legacy gateway returned HTTP 502 at `PrepareQuery`, so the app proof was generated locally but the final Brevis proof/approval remained pending.

Run the prover service:

```sh
cd brevis/prover
go mod tidy
go build ./...
RPC_URL=<chain RPC> CHAIN_ID=11155111 go run ./cmd --port 33247
```

Then submit a proof request with the transaction hashes containing rebalance logs:

```sh
cd brevis/app
npm install
RPC_URL=<chain RPC> PRIVATE_KEY=0x... \
  VERIFIER=<BrevisCuratorVerifier address> \
  HOOK=<hook address> \
  STRATEGY=<strategy address> \
  TX_HASHES=0x...,0x... \
  npm run prove
```

Copy the prover `vkHash` into `BrevisCuratorVerifier.setVkHash` before requesting a proof. `brevis/prover/cmd/vkhash` prints it after circuit setup; setup downloads the ~3.2 GB KZG SRS on first run, so use the prover service output or a pre-populated `SRS_DIR` if available. `brevisCallback` accepts only the configured BrevisRequest, checks the vk hash, checks the pinned hook, enforces the rebalance-count and block-range thresholds, rejects replayed claims, and calls `CuratorRegistry.approve(strategy, claim)`.

## Dashboard

A lightweight web dashboard is in `dashboard/`. Serve it with any static server:

```sh
cd dashboard
python3 -m http.server 8080
```

Open `http://localhost:8080`, connect MetaMask, paste contract addresses from the deploy output, and use the UI to stake for the strategy, verify scores, deposit, withdraw, and manage positions.

## Limitations

- Local Anvil demos use `MockBrevisVerifier`; the Brevis circuit/verifier/submitter are provided for testnet/production and must be funded and configured with a real vk hash before use.
- The Brevis circuit proves rebalance activity from the hook, not that the curator beat the HODL benchmark; outperformance is measured by the vault benchmark and fee authorization path.
- Registry stake is locked and is a demo bonding primitive, not a full slashing design.
- Holdings are assumed to be 18-decimal tokens in NAV math.
- The vault manages one position with a fixed salt.

## Threat Model

- Hook wiring is owner-set once; after setup, only the pool manager can call liquidity hooks and only the vault can pass the sender gate.
- The registry verifier can approve or revoke curators but cannot withdraw locked stake; there is no slashing in the demo.
- The mock verifier is intentionally trusted and is only for the local demo; testnet/production must use `BrevisCuratorVerifier` and a real Brevis proof.
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

Paste the printed addresses into the dashboard, connect MetaMask to Anvil, stake for the strategy, submit a verification score through the disclosed mock verifier, deposit, initialize the position, swap externally to move the EMA, and withdraw to see benchmarked fees. For a testnet Brevis proof, use `DeployBrevisVerifier.s.sol` and the `brevis/` tooling instead.

## Credits

Built with Uniswap v4, Foundry, OpenZeppelin, and Brevis zkCoprocessor. `BrevisAppZkOnly.sol` is copied from brevis-contracts 1.0.5 under the MIT license. The local Anvil path uses a disclosed mock verifier; the real circuit, callback, and submitter are included.
