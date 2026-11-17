import { BrowserProvider, Contract, formatUnits, parseUnits } from "https://cdn.jsdelivr.net/npm/ethers@6.13.4/+esm";

const VAULT_ABI = await (await fetch("./abis/CuratorVault.json")).json();
const HOOK_ABI = await (await fetch("./abis/CuratorVaultHook.json")).json();
const STRATEGY_ABI = await (await fetch("./abis/SimpleRangeStrategy.json")).json();
const VERIFIER_ABI = await (await fetch("./abis/MockBrevisVerifier.json")).json();
const REGISTRY_ABI = await (await fetch("./abis/CuratorRegistry.json")).json();
const ERC20_ABI = [
  "function approve(address spender, uint256 amount) returns (bool)",
  "function allowance(address owner, address spender) view returns (uint256)",
  "function balanceOf(address account) view returns (uint256)",
  "function decimals() view returns (uint8)",
];

const $ = (id) => document.getElementById(id);
const CONFIG_KEYS = ["vaultAddr", "hookAddr", "strategyAddr", "verifierAddr", "registryAddr", "token0Addr", "token1Addr"];
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
    verifier: new Contract(cfg("verifierAddr"), VERIFIER_ABI, signer || provider),
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
    const [shares, supply, nav, hwm, hodl, fees, position, score, approved, baseFee, maxFee, ema, events] = await Promise.all([
      c.vault.balanceOf(userAddress || "0x0000000000000000000000000000000000000001"),
      c.vault.totalSupply(),
      c.vault.navPerShare(),
      c.vault.highWaterMark(),
      c.vault.hodlPerShare(),
      c.vault.totalPerformanceFees(),
      c.vault.hasPosition(),
      c.hook.verifiedScore(cfg("strategyAddr")),
      c.registry.isApproved(cfg("strategyAddr")),
      c.hook.baseFee(),
      c.hook.maxFee(),
      c.hook.emaSqrtPriceX96(),
      c.hook.totalLiquidityEvents(),
    ]);
    $("statShares").textContent = fmt(shares);
    $("statSupply").textContent = fmt(supply);
    $("statNav").textContent = fmt(nav);
    $("statHwm").textContent = fmt(hwm);
    $("statHodl").textContent = fmt(hodl);
    $("statFees").textContent = fmt(fees);
    $("statPosition").textContent = position ? "Yes" : "No";
    $("statScore").textContent = score.toString();
    $("statApproved").textContent = approved ? "Yes" : "No";
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
$("verifyBtn").onclick = async () => {
  if (!requireConfig()) return;
  await write(async () => contracts().verifier.submitScore(cfg("strategyAddr"), Number($("score").value)), "Verification");
};

loadConfig();
if (window.ethereum) {
  provider = new BrowserProvider(window.ethereum);
  provider.getNetwork().then((net) => { $("network").textContent = `Chain ${net.chainId}`; }).catch(() => {});
  window.ethereum.on?.("accountsChanged", () => connect());
}
setInterval(() => { if (provider && requireConfig()) refresh(); }, 8000);
