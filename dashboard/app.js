import { BrowserProvider, Contract, formatUnits, parseUnits } from "https://cdn.jsdelivr.net/npm/ethers@6.13.4/+esm";

const VAULT_ABI = await (await fetch("./abis/CuratorVault.json")).json();
const HOOK_ABI = await (await fetch("./abis/CuratorVaultHook.json")).json();
const STRATEGY_ABI = await (await fetch("./abis/SimpleRangeStrategy.json")).json();
const REGISTRY_ABI = await (await fetch("./abis/CuratorRegistry.json")).json();
const SWAP_HELPER_ABI = await (await fetch("./abis/SwapHelper.json")).json();
const ERC20_ABI = [
  "function approve(address spender, uint256 amount) returns (bool)",
  "function balanceOf(address account) view returns (uint256)",
];

const $ = (id) => document.getElementById(id);
const CONFIG_KEYS = ["vaultAddr", "hookAddr", "strategyAddr", "registryAddr", "token0Addr", "token1Addr", "swapHelperAddr"];
const SEPOLIA_DEFAULTS = {
  vaultAddr: "0x1b45334925913bA2f48DFf2dDCe5E6a05f47d138",
  hookAddr: "0x9ea63C10324F2E448175f7102Dc59cF2F69Ecfc0",
  strategyAddr: "0xA765D2F5Bb53daf46bD215b412623057BaEA9DC5",
  registryAddr: "0x77278f63c0F253F7255eEeB2305D5ea85f5EaF94",
  token0Addr: "0x0BfDc19147ae322E9f94711f903a07869E1cCefa",
  token1Addr: "0xF5f9989Ad5eCeA50c7706e1C3fce0e74051870eF",
  swapHelperAddr: "0x129aa3EF64AE6f881fDA1708e7A5BDE133df16C2",
};
const MIN_SQRT_PRICE_X96 = 4295128739n;
const MAX_SQRT_PRICE_X96 = 1461446703485210103287273052203988822378723970342n;
const POOL_FEE_FLAG = 8388608;
const TICK_SPACING = 60;
const WAD = 10n ** 18n;
const SEPOLIA_CHAIN_ID = 11155111n;
const SEPOLIA_HEX_CHAIN_ID = "0xaa36a7";
const EXPLORER = "https://sepolia.etherscan.io";
const ROLE_KEY = "cvRole";
const TRACKED_KEY = "cvTrackedCurators";
const SELECTED_KEY = "cvSelectedCurator";
const EVENT_SPECS = [
  { key: "registry", names: ["Staked", "CuratorApproved", "CuratorRevoked", "VaultRegistered", "ReputationUpdated"] },
  { key: "vault", names: ["Deposited", "Withdrawn", "PerformanceFeesClaimed"] },
  { key: "hook", names: ["RebalanceExecuted", "DynamicFeeSet", "FeeAuthorized"] },
  { key: "strategy", names: ["StrategyRebalanced"] },
];

let provider, signer, userAddress, activePage = "explore", currentRole = null, operatorAddress = null, isCuratorOperator = false, loggingOut = false;
let trackedCurators = [], selectedCurator = null, curatorRows = [], latestTx = null, lastEventFingerprint = "";

function status(msg, type = "") {
  const el = $("status");
  el.textContent = msg;
  el.className = `status show ${type}`;
  clearTimeout(status._t);
  status._t = setTimeout(() => (el.className = "status"), 6000);
}

function short(value) {
  const s = String(value || "");
  return s.length > 10 ? `${s.slice(0, 6)}...${s.slice(-4)}` : s;
}

function isAddress(value) { return /^0x[a-fA-F0-9]{40}$/.test(String(value || "").trim()); }

function loadTrackedCurators() {
  try {
    const saved = JSON.parse(localStorage.getItem(TRACKED_KEY) || "[]");
    trackedCurators = Array.isArray(saved) ? saved.filter(isAddress) : [];
  } catch { trackedCurators = []; }
  if (!trackedCurators.length) trackedCurators = [SEPOLIA_DEFAULTS.strategyAddr];
  selectedCurator = localStorage.getItem(SELECTED_KEY);
  if (!isAddress(selectedCurator)) selectedCurator = trackedCurators[0];
}

function saveTrackedCurators() {
  localStorage.setItem(TRACKED_KEY, JSON.stringify(trackedCurators));
  if (selectedCurator) localStorage.setItem(SELECTED_KEY, selectedCurator);
}

function loadConfig() {
  CONFIG_KEYS.forEach((k) => {
    $(k).value = SEPOLIA_DEFAULTS[k];
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

async function checkNetwork() {
  if (!provider) return false;
  try {
    const net = await provider.getNetwork();
    const wrong = BigInt(net.chainId) !== SEPOLIA_CHAIN_ID;
    $("networkBanner").hidden = !wrong;
    $("networkBannerText").textContent = wrong
      ? `Wrong network (chain ${net.chainId}). Switch to Sepolia to use this demo.`
      : "";
    $("network").textContent = wrong ? `Chain ${net.chainId}` : "Sepolia";
    return !wrong;
  } catch { return false; }
}

async function switchNetwork() {
  if (!window.ethereum) { status("No wallet found", "error"); return; }
  try {
    await window.ethereum.request({ method: "wallet_switchEthereumChain", params: [{ chainId: SEPOLIA_HEX_CHAIN_ID }] });
    await checkNetwork();
    if (currentRole) await refresh();
  } catch (e) { status(`Network switch failed: ${e.shortMessage || e.message}`, "error"); }
}

function contracts() {
  return {
    vault: new Contract(cfg("vaultAddr"), VAULT_ABI, signer || provider),
    hook: new Contract(cfg("hookAddr"), HOOK_ABI, signer || provider),
    strategy: new Contract(cfg("strategyAddr"), STRATEGY_ABI, signer || provider),
    registry: new Contract(cfg("registryAddr"), REGISTRY_ABI, signer || provider),
    token0: new Contract(cfg("token0Addr"), ERC20_ABI, signer || provider),
    token1: new Contract(cfg("token1Addr"), ERC20_ABI, signer || provider),
    helper: new Contract(cfg("swapHelperAddr"), SWAP_HELPER_ABI, signer || provider),
  };
}

function fmt(v) { try { return formatUnits(v, 18); } catch { return String(v); } }
function pretty(v) {
  try {
    const n = Number(formatUnits(v, 18));
    return n.toLocaleString(undefined, { maximumFractionDigits: 2 });
  } catch { return String(v); }
}
function deadline(inputId) {
  const minutes = Math.max(1, Number($(inputId)?.value || 60));
  return Math.floor(Date.now() / 1000) + minutes * 60;
}

function tierInfo(score, approved) {
  const s = Number(score);
  if (!approved) return { name: "Revoked", cls: "bad", next: "Not eligible", progress: 0, hint: "Score fell below the minimum. Owner reapproval is required." };
  if (s >= 70) return { name: "Elite", cls: "elite", next: "Top tier reached", progress: 100, hint: "Maximum derived tier reached. Keep beating HODL to maintain it." };
  if (s >= 50) {
    const points = 70 - s;
    return { name: "Active", cls: "", next: "Elite at 70", progress: Math.max(0, Math.min(100, ((s - 50) / 20) * 100)), hint: `${points} score point${points === 1 ? "" : "s"} to Elite.` };
  }
  const points = Math.max(0, 50 - s);
  return { name: "Seed", cls: "seed", next: "Active at 50", progress: Math.max(0, Math.min(100, ((s - 40) / 10) * 100)), hint: `${points} score point${points === 1 ? "" : "s"} to Active.` };
}

function setTier(id, info) {
  const el = $(id);
  el.className = `tier ${info.cls}`.trim();
  el.textContent = info.name;
}

function setStep(id, state) {
  const el = $(id);
  el.classList.toggle("done", state === "done");
  el.classList.toggle("active", state === "active");
}

function canOpenPage(name) {
  if (!currentRole) return false;
  if (name === "activity") return true;
  if (currentRole === "depositor") return name === "explore" || name === "detail" || name === "position";
  return name === "console";
}

function setActivePage(name) {
  if (!canOpenPage(name)) return;
  activePage = name;
  document.querySelectorAll(".nav-item").forEach((b) => b.classList.toggle("active", b.dataset.page === name));
  document.querySelectorAll(".page").forEach((p) => p.classList.toggle("active", p.id === `page-${name}`));
  if (name === "activity") loadActivity();
}

function showRoleModal() {
  $("roleWallet").textContent = userAddress || "—";
  $("roleModal").hidden = false;
  setTimeout(() => $("roleDepositorBtn").focus(), 0);
}

async function enterRole(role) {
  currentRole = role;
  localStorage.setItem(ROLE_KEY, role);
  document.body.dataset.role = role;
  document.body.classList.remove("pre-app");
  $("roleModal").hidden = true;
  setActivePage(role === "curator" ? "console" : "explore");
  if (await checkNetwork()) refresh();
  else status("Switch to Sepolia to load live data", "error");
}

function switchRole() {
  if (!userAddress) { status("Connect wallet first", "error"); return; }
  showRoleModal();
}

async function logout() {
  if (loggingOut) return;
  loggingOut = true;
  try {
    if (provider) await provider.send("wallet_revokePermissions", [{ eth_accounts: {} }]);
  } catch {}
  provider = null;
  signer = null;
  userAddress = null;
  currentRole = null;
  activePage = "explore";
  operatorAddress = null;
  isCuratorOperator = false;
  document.body.classList.add("pre-app");
  delete document.body.dataset.role;
  localStorage.removeItem(ROLE_KEY);
  $("roleModal").hidden = true;
  $("networkBanner").hidden = true;
  $("tokenBanner").hidden = true;
  $("connectBtn").textContent = "Connect Wallet";
  $("landingWallet").textContent = "No wallet connected";
  $("network").textContent = "Not connected";
  $("logoutBtn").hidden = true;
  document.querySelectorAll(".page").forEach((p) => p.classList.remove("active"));
  $("page-landing").classList.add("active");
  status("Disconnected", "success");
  loggingOut = false;
}

function updateSteps(data) {
  const deposited = data.supply > 0n;
  const positioned = data.position;
  const simulated = localStorage.getItem("cvSimulated") === "1" || data.observations > 0n;
  const reported = data.observations > 0n;
  const claimed = data.totalFees > 0n && data.claimable === 0n;

  setStep("stepDeposit", deposited ? "done" : "active");
  setStep("stepPosition", positioned ? "done" : deposited ? "active" : "");
  setStep("stepMove", simulated ? "done" : positioned ? "active" : "");
  setStep("stepWithdraw", reported ? "done" : simulated ? "active" : "");
  setStep("stepClaim", claimed ? "done" : data.claimable > 0n ? "active" : "");
}

async function loadCuratorDirectory(c) {
  const zero = "0x0000000000000000000000000000000000000000";
  const rows = await Promise.all(trackedCurators.filter(isAddress).map(async (address) => {
    try {
      const [score, approved, cap, stake, observations, vaultAddr] = await Promise.all([
        c.registry.reputation(address),
        c.registry.isApproved(address),
        c.registry.aumCap(address),
        c.registry.stakeOf(address),
        c.registry.observations(address),
        c.registry.vaultOf(address),
      ]);
      if (!vaultAddr || vaultAddr === zero) return null;
      const vault = new Contract(vaultAddr, VAULT_ABI, provider);
      const [perfFeeBps, totalNav, operator, navPerShare, hodlPerShare] = await Promise.all([
        vault.performanceFeeBps(),
        vault.totalNav(),
        vault.curator(),
        vault.navPerShare(),
        vault.hodlPerShare(),
      ]);
      const alpha = navPerShare > hodlPerShare && hodlPerShare > 0n
        ? ((navPerShare - hodlPerShare) * 10000n) / hodlPerShare
        : hodlPerShare > navPerShare && navPerShare > 0n
          ? -((hodlPerShare - navPerShare) * 10000n) / navPerShare
          : 0n;
      return {
        address,
        operator,
        vaultAddr,
        score,
        approved,
        cap,
        stake,
        observations,
        perfFeeBps,
        totalNav,
        alpha,
        capLeft: cap > totalNav ? cap - totalNav : 0n,
        utilization: cap > 0n ? Number((totalNav * 10000n) / cap) / 100 : 0,
        tier: tierInfo(score, approved),
      };
    } catch { return null; }
  }));
  curatorRows = rows.filter(Boolean);
  if (!curatorRows.some((r) => r.address.toLowerCase() === String(selectedCurator).toLowerCase())) {
    selectedCurator = curatorRows[0]?.address || null;
  }
  if (selectedCurator) localStorage.setItem(SELECTED_KEY, selectedCurator);
  renderCuratorDirectory();
  renderSelectedDetail();
  await loadHistory(c.registry);
}

function renderCuratorDirectory() {
  const body = $("curatorTableBody");
  body.replaceChildren();
  const q = $("curatorSearch").value.trim().toLowerCase();
  const sort = $("curatorSort").value;
  const live = curatorRows.filter((r) => r.approved).length;
  $("curatorCount").textContent = `${curatorRows.length} tracked · ${live} live`;
  const rows = curatorRows.filter((r) => !q || r.address.toLowerCase().includes(q) || short(r.address).toLowerCase().includes(q) || r.tier.name.toLowerCase().includes(q));
  rows.sort((a, b) => {
    if (sort === "cap") return b.capLeft > a.capLeft ? 1 : b.capLeft < a.capLeft ? -1 : 0;
    if (sort === "fee") return a.perfFeeBps > b.perfFeeBps ? 1 : a.perfFeeBps < b.perfFeeBps ? -1 : 0;
    if (sort === "reports") return b.observations > a.observations ? 1 : b.observations < a.observations ? -1 : 0;
    return b.score > a.score ? 1 : b.score < a.score ? -1 : 0;
  });
  if (!rows.length) {
    const row = document.createElement("tr");
    const cell = document.createElement("td");
    cell.colSpan = 7;
    cell.className = "activity-empty";
    cell.textContent = "No tracked curators match this search.";
    row.appendChild(cell);
    body.appendChild(row);
    return;
  }
  rows.forEach((r, i) => {
    const row = document.createElement("tr");
    row.className = "clickable";
    if (r.address.toLowerCase() === String(selectedCurator).toLowerCase()) row.classList.add("selected");
    row.innerHTML = `
      <td><div class="curator-cell"><div class="avatar">C${i + 1}</div><div><strong>Curator ${short(r.address)}</strong><small>${short(r.address)}</small></div></div></td>
      <td><span class="tier ${r.tier.cls}">${r.tier.name}</span></td>
      <td>Score ${r.score} · ${r.observations} reports</td>
      <td>${Number(r.perfFeeBps) / 100}% perf</td>
      <td>Locked · no unlock</td>
      <td>${pretty(r.capLeft)}</td>
      <td><button class="btn small">View</button></td>`;
    row.onclick = () => selectCurator(r.address);
    body.appendChild(row);
  });
}

function renderSelectedDetail() {
  const row = curatorRows.find((r) => r.address.toLowerCase() === String(selectedCurator).toLowerCase());
  if (!row) return;
  $("detailName").textContent = `Curator ${short(row.address)}`;
  $("detailCuratorAddr").textContent = short(row.address);
  setTier("detailTier", row.tier);
  $("detailScore").textContent = row.score.toString();
  $("detailReports").textContent = row.observations.toString();
  $("detailApproved").textContent = row.approved ? "Yes" : "No";
  $("detailReputation").textContent = row.score.toString();
  $("detailAlpha").textContent = `${row.alpha.toString()} bps`;
  $("detailStake").textContent = pretty(row.stake);
  $("detailCap").textContent = pretty(row.cap);
  $("detailCapLeft").textContent = pretty(row.capLeft);
  $("detailUtilization").textContent = `${row.utilization.toFixed(1)}%`;
  $("detailPerfFee").textContent = `${Number(row.perfFeeBps) / 100}%`;
  $("detailCuratorFull").textContent = row.operator;
  $("detailStrategyFull").textContent = row.address;
  $("detailVaultFull").textContent = row.vaultAddr;
  $("identityOperator").textContent = row.operator;
  $("identityStrategy").textContent = row.address;
}

function selectCurator(address) {
  selectedCurator = address;
  saveTrackedCurators();
  renderCuratorDirectory();
  renderSelectedDetail();
  if (currentRole === "depositor") setActivePage("detail");
  else status("Curator selected for history", "success");
  if (provider && requireConfig()) loadHistory(contracts().registry);
}

async function loadHistory(registry) {
  const box = $("curatorHistory");
  box.replaceChildren();
  const empty = document.createElement("div");
  empty.className = "activity-empty";
  empty.textContent = "Loading reputation history…";
  box.appendChild(empty);
  if (!provider || !selectedCurator) {
    empty.textContent = "No reputation reports yet.";
    $("historyLabel").textContent = "—";
    return;
  }
  try {
    const latest = await provider.getBlockNumber();
    const logs = await registry.queryFilter(registry.filters.ReputationUpdated(selectedCurator), Math.max(0, latest - 50000), latest);
    const series = logs.map((log) => ({
      score: Number(log.args.score),
      alpha: Number(log.args.alphaBps),
      cap: Number(formatUnits(log.args.aumCap, 18)),
      block: log.blockNumber,
    }));
    renderSparkline(series);
  } catch (e) { empty.textContent = `History failed: ${e.shortMessage || e.message}`; }
}

function renderSparkline(series) {
  const box = $("curatorHistory");
  box.replaceChildren();
  if (!series.length) {
    const empty = document.createElement("div");
    empty.className = "activity-empty";
    empty.textContent = "No reputation reports yet. History appears after the first withdrawal.";
    box.appendChild(empty);
    $("historyLabel").textContent = "No reports";
    return;
  }
  $("historyLabel").textContent = `${series.length} report${series.length === 1 ? "" : "s"}`;
  const ns = "http://www.w3.org/2000/svg";
  const w = 640, h = 110, pad = 10;
  const svg = document.createElementNS(ns, "svg");
  svg.setAttribute("viewBox", `0 0 ${w} ${h}`);
  svg.setAttribute("role", "img");
  svg.setAttribute("aria-label", "Score, alpha, and AUM cap history");
  const draw = (values, color) => {
    const min = Math.min(...values), max = Math.max(...values), span = max - min || 1;
    const points = values.map((v, i) => {
      const x = pad + (i / Math.max(1, values.length - 1)) * (w - 2 * pad);
      const y = h - pad - ((v - min) / span) * (h - 2 * pad);
      return [x, y];
    });
    const line = document.createElementNS(ns, "polyline");
    line.setAttribute("points", points.map((p) => p.join(",")).join(" "));
    line.setAttribute("fill", "none");
    line.setAttribute("stroke", color);
    line.setAttribute("stroke-width", "2");
    svg.appendChild(line);
    points.forEach(([x, y]) => {
      const dot = document.createElementNS(ns, "circle");
      dot.setAttribute("cx", x);
      dot.setAttribute("cy", y);
      dot.setAttribute("r", "3");
      dot.setAttribute("fill", color);
      svg.appendChild(dot);
    });
  };
  draw(series.map((s) => s.score), "#1d4ed8");
  draw(series.map((s) => s.alpha), "#059669");
  draw(series.map((s) => s.cap), "#94a3b8");
  const summary = document.createElement("div");
  summary.className = "sparkline-summary";
  const last = series[series.length - 1];
  summary.innerHTML = `<span>Latest report</span><strong>Score ${last.score}</strong><small>alpha ${last.alpha} bps · cap ${last.cap.toLocaleString(undefined, { maximumFractionDigits: 0 })} · block ${last.block}</small><small>Blue score · green alpha · grey cap</small>`;
  box.append(svg, summary);
}

async function refresh() {
  if (!requireConfig()) return;
  document.body.dataset.loading = "true";
  if (!(await checkNetwork())) { delete document.body.dataset.loading; return; }
  try {
    const c = contracts();
    const operatorAddr = await c.vault.curator();
    const strategyAddr = await c.vault.strategy();
    operatorAddress = operatorAddr;
    isCuratorOperator = !!userAddress && userAddress.toLowerCase() === operatorAddr.toLowerCase();
    const accessNote = $("curatorAccessNote");
    accessNote.className = `access-note ${isCuratorOperator ? "ok" : "warn"}`;
    accessNote.textContent = isCuratorOperator
      ? `Operator wallet recognized (${short(operatorAddr)}). Management and fee claims are enabled.`
      : `Read-only curator preview. Manage and claim require the operator wallet (${short(operatorAddr)}).`;
    document.querySelectorAll(".curator-only").forEach((b) => { b.disabled = !isCuratorOperator; });
    const [shares, supply, nav, hwm, hodl, fees, claimable, position, score, approved, cap, stake, observations, baseFee, maxFee, ema, totalNav, registered, perfFeeBps, maxPerfFeeBps, maxRangeWidth, rebalanceCooldown, centerDrift, hookInterval, bal0, bal1] = await Promise.all([
      c.vault.balanceOf(userAddress || "0x0000000000000000000000000000000000000001"),
      c.vault.totalSupply(),
      c.vault.navPerShare(),
      c.vault.highWaterMark(),
      c.vault.hodlPerShare(),
      c.vault.totalPerformanceFees(),
      c.vault.claimableFees(operatorAddr),
      c.vault.hasPosition(),
      c.registry.reputation(strategyAddr),
      c.registry.isApproved(strategyAddr),
      c.registry.aumCap(strategyAddr),
      c.registry.stakeOf(strategyAddr),
      c.registry.observations(strategyAddr),
      c.hook.baseFee(),
      c.hook.maxFee(),
      c.hook.emaSqrtPriceX96(),
      c.vault.totalNav(),
      c.registry.vaultRegistered(cfg("vaultAddr")),
      c.vault.performanceFeeBps(),
      c.hook.maxPerformanceFeeBps(),
      c.strategy.maxRangeWidth(),
      c.strategy.rebalanceCooldown(),
      c.strategy.maxCenterDriftTicks(),
      c.hook.minRebalanceInterval(),
      userAddress ? c.token0.balanceOf(userAddress) : 0n,
      userAddress ? c.token1.balanceOf(userAddress) : 0n,
    ]);
    const dynamicFee = await c.hook.computeFee(ema, ema);

    const capLeft = cap > totalNav ? cap - totalNav : 0n;
    const alpha = nav > hodl ? ((nav - hodl) * 10000n) / hodl : hodl > nav ? -((hodl - nav) * 10000n) / hodl : 0n;
    const utilizationBps = cap > 0n ? (totalNav * 10000n) / cap : 0n;
    const utilizationPct = Number(utilizationBps) / 100;
    const tier = tierInfo(score, approved);
    const positionValue = (shares * nav) / WAD;
    const holdingValue = (shares * hodl) / WAD;
    const valueDelta = positionValue - holdingValue;
    const perfFeePct = Number(perfFeeBps) / 100;

    $("kpiNav").textContent = pretty(nav);
    $("kpiSupply").textContent = `Supply ${pretty(supply)}`;
    $("kpiAlpha").textContent = `${alpha.toString()} bps`;
    $("kpiAlpha").style.color = alpha > 0n ? "var(--green)" : alpha < 0n ? "var(--red)" : "var(--text)";
    $("kpiHodl").textContent = `HODL ${pretty(hodl)}`;
    $("kpiScore").textContent = score.toString();
    $("kpiStake").textContent = `Stake ${pretty(stake)}`;
    $("kpiCap").textContent = pretty(cap);
    $("kpiUtil").textContent = `Utilization ${utilizationPct.toFixed(1)}%`;

    $("healthPill").className = "health-pill";
    if (!approved) {
      $("healthPill").textContent = "Curator revoked";
      $("healthPill").classList.add("bad");
    } else if (Number(score) < 50) {
      $("healthPill").textContent = "Seed tier";
      $("healthPill").classList.add("warn");
    } else {
      $("healthPill").textContent = "Curator active";
      $("healthPill").classList.add("good");
    }

    setTier("detailTier", tier);
    $("detailCuratorAddr").textContent = short(operatorAddr);
    $("detailScore").textContent = score.toString();
    $("detailReports").textContent = observations.toString();
    $("detailApproved").textContent = approved ? "Yes" : "No";
    $("detailReputation").textContent = score.toString();
    $("detailAlpha").textContent = `${alpha.toString()} bps`;
    $("detailStake").textContent = pretty(stake);
    $("detailCap").textContent = pretty(cap);
    $("detailCapLeft").textContent = pretty(capLeft);
    $("detailUtilization").textContent = `${utilizationPct.toFixed(1)}%`;
    $("detailRange").textContent = `${maxRangeWidth} ticks`;
    $("detailCooldown").textContent = `${rebalanceCooldown}s`;
    $("detailDrift").textContent = `${centerDrift} ticks`;
    $("detailHookInterval").textContent = `${hookInterval}s`;
    $("detailPerfFee").textContent = `${perfFeePct}% (max ${Number(maxPerfFeeBps) / 100}%)`;
    $("detailLpFees").textContent = `${baseFee}–${maxFee} bps`;
    $("detailCuratorFull").textContent = operatorAddr;
    $("detailStrategyFull").textContent = strategyAddr;
    $("detailVaultFull").textContent = cfg("vaultAddr");
    $("detailHookFull").textContent = cfg("hookAddr");
    $("identityOperator").textContent = operatorAddr;
    $("identityStrategy").textContent = strategyAddr;
    $("consoleOperator").textContent = operatorAddr;
    $("consoleStrategy").textContent = strategyAddr;
    $("detailTotalFees").textContent = pretty(fees);
    $("detailEscrow").textContent = pretty(claimable);

    $("bal0").textContent = pretty(bal0);
    $("bal1").textContent = pretty(bal1);
    $("balShares").textContent = pretty(shares);
    const noTokens = !!userAddress && bal0 === 0n && bal1 === 0n && shares === 0n;
    $("tokenBanner").hidden = !noTokens;
    $("tokenBannerText").textContent = noTokens
      ? "This wallet has no test T0/T1 or vault shares. Use the Sepolia test tokens from the deployment to try the flows."
      : "";

    $("posShares").textContent = pretty(shares);
    $("posSupply").textContent = `Vault supply ${pretty(supply)}`;
    $("posValue").textContent = pretty(positionValue);
    const deltaSign = valueDelta >= 0n ? "+" : "-";
    $("posDelta").textContent = `${deltaSign}${pretty(valueDelta >= 0n ? valueDelta : -valueDelta)}`;
    $("posDelta").style.color = valueDelta >= 0n ? "var(--green)" : "var(--red)";
    $("posAlpha").textContent = `Alpha ${alpha.toString()} bps`;
    $("posNav").textContent = pretty(nav);
    $("posHodl").textContent = pretty(hodl);
    $("posHwm").textContent = pretty(hwm);
    $("posFee").textContent = `${dynamicFee} bps`;
    $("posMaxFee").textContent = `${maxFee} bps`;
    $("posEma").textContent = ema.toString();

    setTier("consoleTier", tier);
    $("tierCurrent").textContent = tier.name;
    $("tierNext").textContent = tier.next;
    $("tierProgressFill").style.width = `${tier.progress}%`;
    $("tierHint").textContent = tier.hint;
    $("consoleScore").textContent = score.toString();
    $("consoleReports").textContent = observations.toString();
    $("consoleApproved").textContent = approved ? "Yes" : "No";
    $("consoleRegistered").textContent = registered ? "Yes" : "No";
    $("consoleStake").textContent = pretty(stake);
    $("consoleCap").textContent = pretty(cap);
    $("consolePosition").textContent = position ? "Yes" : "No";
    $("consoleClaimable").textContent = pretty(claimable);
    $("consoleTotalFees").textContent = pretty(fees);
    $("consoleFeeRate").textContent = `${perfFeePct}%`;

    await loadCuratorDirectory(c);
    updateSteps({ supply, position, observations, claimable, totalFees: fees });
  } catch (e) { status(`Refresh failed: ${e.shortMessage || e.message}`, "error"); }
  finally { delete document.body.dataset.loading; }
}

function activityMessage(item) {
  const a = item.args;
  switch (item.name) {
    case "Staked": return { icon: "+", title: "Stake added", detail: `${short(a[0])} · ${pretty(a[1])} T0`, tone: "good" };
    case "CuratorApproved": return { icon: "✓", title: "Curator approved", detail: short(a[0]), tone: "good" };
    case "CuratorRevoked": return { icon: "!", title: "Curator revoked", detail: short(a[0]), tone: "bad" };
    case "VaultRegistered": return { icon: "◇", title: "Vault registered", detail: `${short(a[0])} → ${short(a[1])}`, tone: "" };
    case "ReputationUpdated": return { icon: "↗", title: "Reputation updated", detail: `alpha ${a[1].toString()} bps · score ${a[2].toString()} · cap ${pretty(a[3])}`, tone: a[1] >= 0n ? "good" : "warn" };
    case "Deposited": return { icon: "↓", title: "Deposit", detail: `${short(a[0])} · ${pretty(a[3])} shares`, tone: "" };
    case "Withdrawn": return { icon: "↑", title: "Withdrawal", detail: `${pretty(a[1])} shares · fee ${pretty(a[4])}`, tone: "" };
    case "PerformanceFeesClaimed": return { icon: "$", title: "Fees claimed", detail: `${pretty(a[1])} T0`, tone: "good" };
    case "RebalanceExecuted": return { icon: "↔", title: "Position rebalanced", detail: `${a[2].toString()} → ${a[3].toString()}`, tone: "" };
    case "DynamicFeeSet": return { icon: "%", title: "Dynamic fee set", detail: `${a[1].toString()} bps`, tone: "" };
    case "FeeAuthorized": return { icon: "✓", title: "Fee authorized", detail: `${a[3].toString()} bps`, tone: "" };
    case "StrategyRebalanced": return { icon: "↔", title: "Strategy rebalance", detail: `${a[0].toString()} → ${a[1].toString()}`, tone: "" };
    default: return { icon: "•", title: item.name, detail: "", tone: "" };
  }
}

function renderActivity(items) {
  const feed = $("activityFeed");
  feed.replaceChildren();
  if (!items.length) {
    const empty = document.createElement("div");
    empty.className = "activity-empty";
    empty.textContent = "No indexed events in recent blocks.";
    feed.appendChild(empty);
    return;
  }
  items.forEach((item) => {
    const m = activityMessage(item);
    const row = document.createElement("div");
    row.className = `activity-item ${m.tone}`.trim();
    const icon = document.createElement("div");
    icon.className = "activity-icon";
    icon.textContent = m.icon;
    const body = document.createElement("div");
    const title = document.createElement("strong");
    title.textContent = m.title;
    const detail = document.createElement("small");
    detail.textContent = m.detail;
    body.append(title, detail);
    const block = document.createElement("time");
    block.textContent = `#${item.blockNumber}`;
    row.append(icon, body, block);
    feed.appendChild(row);
  });
}

async function loadActivity() {
  if (!requireConfig() || !provider) return;
  try {
    const c = contracts();
    const latest = await provider.getBlockNumber();
    const from = Math.max(0, latest - 20000);
    const batches = await Promise.all(EVENT_SPECS.flatMap((spec) => spec.names.map(async (name) => {
      try {
        const logs = await c[spec.key].queryFilter(c[spec.key].filters[name](), from, latest);
        return logs.map((log) => ({ name: log.event, args: log.args, blockNumber: log.blockNumber, logIndex: log.logIndex }));
      } catch { return []; }
    })));
    const items = batches.flat().sort((a, b) => b.blockNumber - a.blockNumber || b.logIndex - a.logIndex).slice(0, 14);
    const fingerprint = items[0] ? `${items[0].name}-${items[0].blockNumber}-${items[0].logIndex}` : "";
    if (lastEventFingerprint && fingerprint && fingerprint !== lastEventFingerprint) {
      status(`New on-chain activity: ${activityMessage(items[0]).title}`, "success");
    }
    lastEventFingerprint = fingerprint;
    renderActivity(items);
  } catch (e) { status(`Activity failed: ${e.shortMessage || e.message}`, "error"); }
}

async function connect() {
  if (!window.ethereum) { status("No wallet found", "error"); return; }
  provider = new BrowserProvider(window.ethereum);
  await provider.send("eth_requestAccounts", []);
  signer = await provider.getSigner();
  userAddress = await signer.getAddress();
  const okNetwork = await checkNetwork();
  $("connectBtn").textContent = `${userAddress.slice(0, 6)}...${userAddress.slice(-4)}`;
  $("logoutBtn").hidden = false;
  $("landingWallet").textContent = `Connected ${short(userAddress)}`;
  const savedRole = localStorage.getItem(ROLE_KEY);
  if (currentRole || (savedRole === "depositor" || savedRole === "curator")) {
    currentRole = currentRole || savedRole;
    document.body.dataset.role = currentRole;
    document.body.classList.remove("pre-app");
    $("roleModal").hidden = true;
    setActivePage(currentRole === "curator" ? "console" : "explore");
    if (okNetwork) {
      await refresh();
      if (activePage === "activity") loadActivity();
    } else {
      status("Switch to Sepolia to load live data", "error");
    }
  } else {
    showRoleModal();
  }
}

function renderTx(tx, label, state, receipt) {
  latestTx = { tx, label, state, receipt };
  const box = $("txDetails");
  box.replaceChildren();
  const fields = [
    ["Action", label],
    ["Hash", null],
    ["Block / gas", receipt ? `#${receipt.blockNumber} · ${receipt.gasUsed.toString()} gas` : "Pending"],
    ["Status", state],
  ];
  fields.forEach(([name, value]) => {
    const item = document.createElement("div");
    item.className = "tx-item";
    const span = document.createElement("span");
    span.textContent = name;
    item.appendChild(span);
    if (name === "Hash") {
      const link = document.createElement("a");
      link.href = `${EXPLORER}/tx/${tx.hash}`;
      link.target = "_blank";
      link.rel = "noopener noreferrer";
      link.textContent = short(tx.hash);
      item.appendChild(link);
    } else {
      const strong = document.createElement("strong");
      strong.textContent = value;
      item.appendChild(strong);
    }
    box.appendChild(item);
  });
  $("txStatus").textContent = state;
  $("txStatus").className = `tag ${state === "Confirmed" ? "good" : state === "Failed" ? "bad" : ""}`.trim();
}

async function write(fn, label) {
  try {
    if (!signer) { status("Connect wallet first", "error"); return false; }
    status(`${label} submitted...`);
    const tx = await fn();
    renderTx(tx, label, "Pending");
    status(`${label} submitted ${short(tx.hash)}`);
    const receipt = await tx.wait();
    renderTx(tx, label, "Confirmed", receipt);
    status(`${label} confirmed in block ${receipt.blockNumber}`, "success");
    await refresh();
    if (activePage === "activity") loadActivity();
    return true;
  } catch (e) {
    if (latestTx?.state === "Pending") renderTx(latestTx.tx, latestTx.label, "Failed");
    status(`${label} failed: ${e.shortMessage || e.message}`, "error");
    return false;
  }
}

document.querySelectorAll(".nav-item").forEach((b) => { b.onclick = () => setActivePage(b.dataset.page); });
$("backExploreBtn").onclick = () => setActivePage("explore");
$("curatorSearch").oninput = renderCuratorDirectory;
$("curatorSort").onchange = renderCuratorDirectory;
$("trackCuratorBtn").onclick = async () => {
  const input = $("trackCuratorInput").value.trim();
  if (!isAddress(input)) { status("Enter a valid 0x strategy address", "error"); return; }
  if (trackedCurators.some((a) => a.toLowerCase() === input.toLowerCase())) { status("That curator is already tracked", "error"); return; }
  trackedCurators.push(input);
  selectedCurator = input;
  saveTrackedCurators();
  $("trackCuratorInput").value = "";
  if (currentRole) await refresh();
  else status("Curator added to tracking", "success");
};
$("switchNetworkBtn").onclick = switchNetwork;

$("connectBtn").onclick = connect;
$("landingConnectBtn").onclick = connect;
$("roleDepositorBtn").onclick = () => enterRole("depositor");
$("roleCuratorBtn").onclick = () => enterRole("curator");
$("roleCancelBtn").onclick = () => { $("roleModal").hidden = true; };
document.addEventListener("keydown", (e) => {
  const modal = $("roleModal");
  if (modal.hidden) return;
  if (e.key === "Escape") { modal.hidden = true; return; }
  if (e.key !== "Tab") return;
  const focusables = [...modal.querySelectorAll("button")];
  const first = focusables[0], last = focusables[focusables.length - 1];
  if (e.shiftKey && document.activeElement === first) { e.preventDefault(); last.focus(); }
  else if (!e.shiftKey && document.activeElement === last) { e.preventDefault(); first.focus(); }
});
$("switchRoleBtn").onclick = switchRole;
$("logoutBtn").onclick = logout;
$("saveConfigBtn").onclick = () => { saveConfig(); refresh(); };
$("resetConfigBtn").onclick = () => {
  CONFIG_KEYS.forEach((k) => {
    $(k).value = SEPOLIA_DEFAULTS[k];
    localStorage.setItem(k, SEPOLIA_DEFAULTS[k]);
  });
  status("Sepolia defaults loaded", "success");
  refresh();
  if (activePage === "activity") loadActivity();
};
$("refreshActivityBtn").onclick = loadActivity;

$("approve0Btn").onclick = async () => {
  if (!requireConfig()) return;
  await write(async () => {
    const c = contracts();
    return c.token0.approve(cfg("vaultAddr"), parseUnits($("deposit0").value || "0", 18));
  }, "Approve T0");
};
$("approve1Btn").onclick = async () => {
  if (!requireConfig()) return;
  await write(async () => {
    const c = contracts();
    return c.token1.approve(cfg("vaultAddr"), parseUnits($("deposit1").value || "0", 18));
  }, "Approve T1");
};
$("depositBtn").onclick = async () => {
  if (!requireConfig()) return;
  await write(async () => {
    const c = contracts();
    return c.vault.deposit(
      parseUnits($("deposit0").value, 18),
      parseUnits($("deposit1").value, 18),
      parseUnits($("depositMinShares").value || "0", 18),
      deadline("depositDeadline")
    );
  }, "Deposit");
};
$("withdrawBtn").onclick = async () => {
  if (!requireConfig()) return;
  await write(async () => {
    const c = contracts();
    return c.vault.withdraw(
      parseUnits($("withdrawShares").value, 18),
      parseUnits($("withdrawMin0").value || "0", 18),
      parseUnits($("withdrawMin1").value || "0", 18),
      deadline("withdrawDeadline")
    );
  }, "Withdraw");
};

$("initializeBtn").onclick = async () => {
  if (!requireConfig()) return;
  await write(async () => {
    const c = contracts();
    return c.strategy.initialize(Number($("lowerTick").value), Number($("upperTick").value), BigInt($("liq").value));
  }, "Open position");
};
$("rebalanceBtn").onclick = async () => {
  if (!requireConfig()) return;
  await write(async () => {
    const c = contracts();
    return c.strategy.rebalance(Number($("lowerTick").value), Number($("upperTick").value), BigInt($("liq").value));
  }, "Rebalance");
};

$("simulateBtn").onclick = async () => {
  if (!requireConfig()) return;
  const amount = parseUnits($("swapAmount").value || "0", 18);
  if (amount <= 0n) { status("Enter a swap amount", "error"); return; }
  const ok = await write(async () => {
    const c = contracts();
    const down = $("swapDirection").value === "down";
    const token = down ? c.token0 : c.token1;
    const fund = await token.transfer(cfg("swapHelperAddr"), amount);
    await fund.wait();
    return c.helper.swap(
      {
        currency0: cfg("token0Addr"),
        currency1: cfg("token1Addr"),
        fee: POOL_FEE_FLAG,
        tickSpacing: TICK_SPACING,
        hooks: cfg("hookAddr"),
      },
      {
        zeroForOne: down,
        amountSpecified: amount,
        sqrtPriceLimitX96: down ? MIN_SQRT_PRICE_X96 : MAX_SQRT_PRICE_X96,
      }
    );
  }, "Simulate price move");
  if (ok) localStorage.setItem("cvSimulated", "1");
};

$("claimFeesBtn").onclick = async () => {
  if (!requireConfig()) return;
  await write(async () => contracts().vault.claimPerformanceFees(), "Claim performance fees");
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

loadConfig();
loadTrackedCurators();
if (window.ethereum) {
  provider = new BrowserProvider(window.ethereum);
  checkNetwork();
  window.ethereum.on?.("accountsChanged", (accounts) => {
    if (!accounts.length) logout();
    else connect();
  });
}
setInterval(() => {
  if (provider && currentRole && requireConfig()) {
    refresh();
    if (activePage === "activity") loadActivity();
  }
}, 12000);
