# CuratorVault

Mutual funds for Uniswap v4 liquidity — reputation-weighted curation for UHI11.

## What it does

Depositors put token0/token1 into an ERC20 vault and receive shares. A curator manages one concentrated liquidity position through a strategy module. The hook enforces the mandate at the pool level:

- Only the vault may add or remove liquidity.
- Range width and rebalance frequency are bounded on-chain.
- Curator actions require a staked, approved registry entry.
- Deposits are capped by the curator's AUM cap.
- Dynamic LP fees rise when pool price deviates from an EMA reference.
- NAV uses the hook EMA price.
- Performance fees are charged only when share price beats both its high-water mark and a HODL benchmark.
- Curators claim their performance fees on-chain.

## Reputation-weighted curation

Curators do not buy a badge. They stake a locked bond, receive a starting AUM cap, and then earn more capital by beating HODL.

- `CuratorRegistry` stores stake, approval, reputation score, report count, and registered vault.
- The hook is the only reporter. The vault calls `hook.reportPerformance(strategy, alphaBps)` on every withdrawal.
- Alpha is measured from the vault's own accounting: `alphaBps = (sharePrice - hodlPerShare) / hodlPerShare`.
- Reports are clamped to +/-1000 bps and folded into an EMA: `score = (score * 9 + alphaBps) / 10`.
- Initial score is `50`; minimum score is `40`.
- AUM cap is `stake * (200 + score) / 100`, so a new curator with score `50` can manage up to `2.5x` their stake.
- Underperformance lowers score and cap. Falling below the minimum revokes the curator.
- Positive alpha creates claimable performance fees for the vault's curator address.

This is protocol-measured performance, not a ZK proof and not a cross-protocol track record. The seed cohort is owner-approved and disclosed; after onboarding, reputation updates automatically from real vault withdrawals.

## Architecture

- `src/CuratorVaultHook.sol` — Uniswap v4 hook: permissions, gating, guardrails, dynamic fees, EMA, reputation reporting.
- `src/CuratorVault.sol` — ERC20 share vault; deposit/withdraw; HODL benchmark; AUM cap check; performance fees and fee claims.
- `src/CuratorRegistry.sol` — locked stake, reputation score, AUM cap, revocation, vault registration.
- `src/SimpleRangeStrategy.sol` — curator-controlled rebalancing with drift/cooldown checks.
- `src/mocks/CREATE2Deployer.sol` — CREATE2 factory for mining hook permission bits.
- `src/mocks/SwapHelper.sol` — test-only swap helper.

Hook permissions required: `BEFORE_ADD_LIQUIDITY | AFTER_ADD_LIQUIDITY | BEFORE_REMOVE_LIQUIDITY | AFTER_REMOVE_LIQUIDITY | BEFORE_SWAP | AFTER_SWAP` = `0xfc0`.

## Build & Test

```sh
forge build
forge test -vv
```

30 tests cover permission mining, wiring, registry staking/approval/revocation, reputation reporting, AUM caps, hook gating, fee claims, deposit/withdraw, position init, out-of-range withdrawal, dynamic fees, rebalance cooldown, HODL benchmark, high-water mark, and fuzz cases.

## Deploy

```sh
export PRIVATE_KEY=0x...
forge script script/DeployCuratorVault.s.sol --rpc-url <RPC> --broadcast
```

The script mines a CREATE2 salt so the hook address ends in the required permission bits, deploys PoolManager + test tokens + hook + vault + strategy + registry, initializes the pool with `LPFeeLibrary.DYNAMIC_FEE_FLAG`, registers the supported pool, stakes for the strategy, bootstraps approval, registers the vault, and wires all contracts. `MIN_REBALANCE_INTERVAL` and `STRATEGY_COOLDOWN` default to `1 hours` and can be shortened for testnet demos.

For local simulation (no broadcast):

```sh
PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
  forge script script/DeployCuratorVault.s.sol -vvv
```

## Sepolia deployment

Current testnet deployment uses these addresses:

| Contract | Address |
| --- | --- |
| PoolManager | `0x39E0f2c3ea784A1bA9C026cceAEC1b39400BA91c` |
| Token0 | `0x0BfDc19147ae322E9f94711f903a07869E1cCefa` |
| Token1 | `0xF5f9989Ad5eCeA50c7706e1C3fce0e74051870eF` |
| Hook | `0x9ea63C10324F2E448175f7102Dc59cF2F69Ecfc0` |
| Vault | `0x1b45334925913bA2f48DFf2dDCe5E6a05f47d138` |
| Strategy | `0xA765D2F5Bb53daf46bD215b412623057BaEA9DC5` |
| Registry | `0x77278f63c0F253F7255eEeB2305D5ea85f5EaF94` |
| SwapHelper | `0x129aa3EF64AE6f881fDA1708e7A5BDE133df16C2` |

The dashboard ships with these addresses as defaults and has a **Use Sepolia Defaults** button to override stale browser state.

## Dashboard

A lightweight web dashboard is in `dashboard/`. Serve it with any static server:

```sh
cd dashboard
python3 -m http.server 8080
```

Open `http://localhost:8080`. The app starts on a landing page; connect MetaMask on Sepolia, then choose a workspace:

- **Depositor** — Explore curators, Curator detail, and My position. NAV, alpha, tier, record, fee rate, vesting, deposit cap left, shares, and withdrawal.
- **Curator** — Curator console. Tier progress, registration state, stake/reputation, mandate limits, fee escrow, market simulator, and collapsed onboarding controls.
- **Activity** — shared by both roles; recent indexed on-chain events and your latest transaction. Address settings are hidden unless the page is opened with `?admin=1`.

Role selects the workspace only; on-chain permissions still decide who can manage or claim. **Switch role** changes the workspace without reconnecting, and **Disconnect** returns to the landing page. Reputation, stake, and AUM cap belong to the registered strategy address; performance-fee claims belong to the curator operator wallet. A non-operator curator view is read-only.

Tier, record, and vesting are UI interpretations of on-chain state, not additional contract fields.
 Tier is derived from reputation (`Seed` 40-49, `Active` 50-69, `Elite` 70+), record is score plus report count, and vesting is shown as `Locked · no unlock` because the demo stake has no withdrawal path. The activity feed only shows events the contracts actually emit; it does not invent reverted actions, epoch rollovers, or clawbacks.

The market simulator uses the deployed `SwapHelper` to move the pool price with test tokens. After a simulated swap, withdraw shares to trigger a performance report and watch the reputation score and AUM cap update.

## Demo script

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

Open `http://localhost:8080?admin=1`, paste the printed addresses into **Activity → Deployment settings**, then connect MetaMask, choose **Depositor**, deposit from **Curator detail**, and use **My position**.
 Switch to **Curator** to open/rebalance the position and use **Market simulator** to move price. Switch back to **Depositor** and withdraw to trigger a reputation report, then show the score/AUM cap change on **Explore curators** and claim any performance fees from **Curator console**. On local Anvil, also deploy `src/mocks/SwapHelper.sol` with the PoolManager address and paste it into Deployment settings.

## Limitations

- The seed curator cohort is owner-approved; ongoing reputation is automatic from vault withdrawals.
- Reputation measures performance inside this vault only, not across other protocols.
- AUM caps are denominated in token0 value using the hook EMA price.
- Registry stake is locked and is a demo bonding primitive, not a full slashing design.
- Holdings are assumed to be 18-decimal tokens in NAV math.
- The vault manages one position with a fixed salt.

## Threat model

- Hook wiring is owner-set once; after setup, only the pool manager can call liquidity hooks and only the vault can pass the sender gate.
- Only the hook can report performance, and the hook only accepts reports from the vault.
- Deposits are blocked when proposed AUM exceeds the curator's cap.
- The registry owner can revoke a curator but cannot withdraw locked stake.
- NAV and dynamic fees use the hook EMA price rather than spot, reducing single-block price manipulation, but a slow EMA can lag during volatile moves.
- Performance fees are capped by the hook and authorized only when both the high-water mark and HODL benchmark are beaten.
- NAV math assumes both tokens have 18 decimals.

## Credits

Built with Uniswap v4, Foundry, and OpenZeppelin.
