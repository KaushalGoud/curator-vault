import { BrowserProvider, Contract, formatUnits, parseUnits } from "https://cdn.jsdelivr.net/npm/ethers@6.13.4/+esm";

const VAULT_ABI = await (await fetch("./abis/CuratorVault.json")).json();
const HOOK_ABI = await (await fetch("./abis/CuratorVaultHook.json")).json();
const STRATEGY_ABI = await (await fetch("./abis/SimpleRangeStrategy.json")).json();
const REGISTRY_ABI = await (await fetch("./abis/CuratorRegistry.json")).json();
const ERC20_ABI = [
  "function approve(address spender, uint256 amount) returns (bool)",
  "function allowance(address owner, address spender) view returns (uint256)",
  "function balanceOf(address account) view returns (uint256)",
  "function decimals() view returns (uint8)",
];

const $ = (id) => document.getElementById(id);
const CONFIG_KEYS = ["vaultAddr", "hookAddr", "strategyAddr", "registryAddr", "token0Addr", "token1Addr"];
const SEPOLIA_DEFAULTS = {
  vaultAddr: "0x1b45334925913bA2f48DFf2dDCe5E6a05f47d138",
  hookAddr: "0x9ea63C10324F2E448175f7102Dc59cF2F69Ecfc0",
  strategyAddr: "0xA765D2F5Bb53daf46bD215b412623057BaEA9DC5",
  registryAddr: "0x77278f63c0F253F7255eEeB2305D5ea85f5EaF94",
  token0Addr: "0x0BfDc19147ae322E9f94711f903a07869E1cCefa",
  token1Addr: "0xF5f9989Ad5eCeA50c7706e1C3fce0e74051870eF",
};
let provider, signer, userAddress;

function status(msg, type = "") {
  const el = $("status");
  el.textContent = msg;
  el.className = `status show ${type}`;
  clearTimeout(status._t);
  status._t = setTimeout(() => (el.className = "status"), 6000);
}

function loadConfig() {
  CONFIG_KEYS.forEach((k) => {
    const saved = localStorage.getItem(k);
    if (saved) $(k).value = saved;
  });
}

function saveConfig() {
  CONFIG_KEYS.forEach((k) => localStorage.setItem(k, $(k).value.trim()));
  status("Configuration saved", "success");
}

function cfg(k) { return $(k).value.trim(); }

function requireConfig() {
  for (const k of CONFIG_KEYS) if (!cfg(k)) { status(`Missing address: ${k}`, "error"); return false; }
  return true;
}

function contracts() {
  return {
    vault: new Contract(cfg("vaultAddr"), VAULT_ABI, signer || provider),
    hook: new Contract(cfg("hookAddr"), HOOK_ABI, signer || provider),
    strategy: new Contract(cfg("strategyAddr"), STRATEGY_ABI, signer || provider),
    registry: new Contract(cfg("registryAddr"), REGISTRY_ABI, signer || provider),
    token0: new Contract(cfg("token0Addr"), ERC20_ABI, signer || provider),
    token1: new Contract(cfg("token1Addr"), ERC20_ABI, signer || provider),
  };
}

const fmt = (v) => { try { return formatUnits(v, 18); } catch { return String(v); } };
const deadline = () => Math.floor(Date.now() / 1000) + 3600;

async function refresh() {
  if (!requireConfig()) return;
  try {
    const c = contracts();
    const curatorAddr = await c.vault.curator();
    const [shares, supply, nav, hwm, hodl, fees, claimable, position, score, approved, cap, stake, observations, baseFee, maxFee, ema, events, totalNav] = await Promise.all([
      c.vault.balanceOf(userAddress || "0x0000000000000000000000000000000000000001"),
      c.vault.totalSupply(),
      c.vault.navPerShare(),
      c.vault.highWaterMark(),
      c.vault.hodlPerShare(),
      c.vault.totalPerformanceFees(),
      c.vault.claimableFees(curatorAddr),
      c.vault.hasPosition(),
      c.registry.reputation(cfg("strategyAddr")),
      c.registry.isApproved(cfg("strategyAddr")),
      c.registry.aumCap(cfg("strategyAddr")),
      c.registry.stakeOf(cfg("strategyAddr")),
      c.registry.observations(cfg("strategyAddr")),
      c.hook.baseFee(),
      c.hook.maxFee(),
      c.hook.emaSqrtPriceX96(),
      c.hook.totalLiquidityEvents(),
      c.vault.totalNav(),
    ]);

    const aum = await c.registry.canManage(cfg("strategyAddr"), cfg("vaultAddr"), totalNav);
    const alpha = nav > hodl ? ((nav - hodl) * 10000n) / hodl : hodl > nav ? -((hodl - nav) * 10000n) / hodl : 0n;
    const utilization = cap > 0n ? (totalNav * 10000n) / cap : 0n;

    $("statShares").textContent = fmt(shares);
    $("statSupply").textContent = fmt(supply);
    $("statNav").textContent = fmt(nav);
    $("statHwm").textContent = fmt(hwm);
    $("statHodl").textContent = fmt(hodl);
    $("statAlpha").textContent = `${alpha.toString()} bps`;
    $("statFees").textContent = fmt(fees);
    $("statClaimable").textContent = fmt(claimable);
    $("statPosition").textContent = position ? "Yes" : "No";
    $("statScore").textContent = score.toString();
    $("statApproved").textContent = approved ? "Yes" : "No";
    $("statStake").textContent = fmt(stake);
    $("statAumCap").textContent = fmt(cap);
    $("statUtilization").textContent = `${Number(utilization) / 100}%`;
    $("statCanManage").textContent = aum ? "Yes" : "No";
    $("statObservations").textContent = observations.toString();
    $("statBaseFee").textContent = baseFee.toString();
    $("statMaxFee").textContent = maxFee.toString();
    $("statEma").textContent = ema.toString();
    $("statEvents").textContent = events.toString();
  } catch (e) { status(`Refresh failed: ${e.shortMessage || e.message}`, "error"); }
}

async function connect() {
  if (!window.ethereum) { status("No wallet found", "error"); return; }
  provider = new BrowserProvider(window.ethereum);
  await provider.send("eth_requestAccounts", []);
  signer = await provider.getSigner();
  userAddress = await signer.getAddress();
  const net = await provider.getNetwork();
  $("network").textContent = `Chain ${net.chainId}`;
  $("connectBtn").textContent = `${userAddress.slice(0, 6)}...${userAddress.slice(-4)}`;
  await refresh();
}

async function write(fn, label) {
  try {
    if (!signer) { status("Connect wallet first", "error"); return; }
    status(`${label} pending...`);
    const tx = await fn();
    await tx.wait();
    status(`${label} confirmed`, "success");
    await refresh();
  } catch (e) { status(`${label} failed: ${e.shortMessage || e.message}`, "error"); }
}

$("connectBtn").onclick = connect;
$("saveConfigBtn").onclick = () => { saveConfig(); refresh(); };
$("approve0Btn").onclick = async () => {
  if (!requireConfig()) return;
  await write(async () => {
    const c = contracts();
    const amt = parseUnits($("deposit0").value || "0", 18);
    return c.token0.approve(cfg("vaultAddr"), amt);
  }, "Approve Token0");
};
$("approve1Btn").onclick = async () => {
  if (!requireConfig()) return;
  await write(async () => {
    const c = contracts();
    const amt = parseUnits($("deposit1").value || "0", 18);
    return c.token1.approve(cfg("vaultAddr"), amt);
  }, "Approve Token1");
};
$("depositBtn").onclick = async () => {
  if (!requireConfig()) return;
  await write(async () => {
    const c = contracts();
    return c.vault.deposit(parseUnits($("deposit0").value, 18), parseUnits($("deposit1").value, 18), 1, deadline());
  }, "Deposit");
};
$("withdrawBtn").onclick = async () => {
  if (!requireConfig()) return;
  await write(async () => {
    const c = contracts();
    return c.vault.withdraw(parseUnits($("withdrawShares").value, 18), 0, 0, deadline());
  }, "Withdraw");
};
$("initializeBtn").onclick = async () => {
  if (!requireConfig()) return;
  await write(async () => {
    const c = contracts();
    return c.strategy.initialize(Number($("lowerTick").value), Number($("upperTick").value), BigInt($("liq").value));
  }, "Initialize position");
};
$("rebalanceBtn").onclick = async () => {
  if (!requireConfig()) return;
  await write(async () => {
    const c = contracts();
    return c.strategy.rebalance(Number($("lowerTick").value), Number($("upperTick").value), BigInt($("liq").value));
  }, "Rebalance");
};
$("stakeBtn").onclick = async () => {
  if (!requireConfig()) return;
  await write(async () => {
    const c = contracts();
    const amt = parseUnits($("stakeAmount").value || "0", 18);
    const tx = await c.token0.approve(cfg("registryAddr"), amt);
    await tx.wait();
    return c.registry.stakeFor(cfg("strategyAddr"), amt);
  }, "Stake for strategy");
};
$("approveCuratorBtn").onclick = async () => {
  if (!requireConfig()) return;
  await write(async () => contracts().registry.approve(cfg("strategyAddr")), "Bootstrap approve");
};
$("registerVaultBtn").onclick = async () => {
  if (!requireConfig()) return;
  await write(async () => contracts().registry.registerVault(cfg("strategyAddr"), cfg("vaultAddr")), "Register vault");
};
$("claimFeesBtn").onclick = async () => {
  if (!requireConfig()) return;
  await write(async () => contracts().vault.claimPerformanceFees(), "Claim performance fees");
};

$("resetConfigBtn").onclick = () => {
  CONFIG_KEYS.forEach((k) => {
    $(k).value = SEPOLIA_DEFAULTS[k];
    localStorage.setItem(k, SEPOLIA_DEFAULTS[k]);
  });
  status("Sepolia defaults loaded", "success");
};

loadConfig();
if (window.ethereum) {
  provider = new BrowserProvider(window.ethereum);
  provider.getNetwork().then((net) => { $("network").textContent = `Chain ${net.chainId}`; }).catch(() => {});
  window.ethereum.on?.("accountsChanged", () => connect());
}
setInterval(() => { if (provider && requireConfig()) refresh(); }, 8000);
