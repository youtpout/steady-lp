import { BrowserProvider, Contract, getAddress, isAddress, zeroPadValue, toBeHex } from "https://cdn.jsdelivr.net/npm/ethers@6.13.5/+esm";

const DYNAMIC_FEE_FLAG = 0x800000;

const POSITION_MANAGERS = {
  1: "0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e",
  10: "0x3C3Ea4B57a46241e54610e5f022E5c45859A1017",
  130: "0x4529A01c7A0410167c5740C487A8DE60232617bf",
  137: "0x1Ec2eBf4F37E7363FDfe3551602425af0B3ceef9",
  8453: "0x7C5f5A4bBd8fD63184577525326123B519429bDc",
  42161: "0xd88F38F930b7952f2DB2432Cb002E7abbF3dD869",
  11155111: "0x429ba70129df741B2Ca2a85BC3A2a3328e5c09b4",
  84532: "0x4B2C77d209D3405F41a037Ec6c77F7F5b8e2ca80",
  421614: "0xAc631556d3d4019C95769033B5E719dD77124BAc",
};

const NETWORK_NAMES = {
  1: "Ethereum", 10: "Optimism", 130: "Unichain", 137: "Polygon", 8453: "Base",
  42161: "Arbitrum", 11155111: "Sepolia", 84532: "Base Sepolia", 421614: "Arbitrum Sepolia",
};

const POOL_TUPLE = "tuple(address currency0,address currency1,uint24 fee,int24 tickSpacing,address hooks)";
const POSITION_MANAGER_ABI = [
  `function initializePool(${POOL_TUPLE} key,uint160 sqrtPriceX96) payable returns (int24)`,
];
const HOOK_ABI = [
  `function previewClaimableFees(${POOL_TUPLE} key,address operator,int24 tickLower,int24 tickUpper,bytes32 salt) view returns (uint256 amount0,uint256 amount1)`,
  `function previewPendingCompensation(${POOL_TUPLE} key,address operator,int24 tickLower,int24 tickUpper,bytes32 salt) view returns (uint256 amount0,uint256 amount1)`,
  `function claimReleasedFees(${POOL_TUPLE} key,int24 tickLower,int24 tickUpper,bytes32 salt,address recipient) returns (uint256 amount0,uint256 amount1)`,
  `function claimPendingCompensation(${POOL_TUPLE} key,int24 tickLower,int24 tickUpper,bytes32 salt,address recipient) returns (uint256 amount0,uint256 amount1)`,
  `function claimCompensation(${POOL_TUPLE} key,int24 tickLower,int24 tickUpper,bytes32 salt,uint256 lossValueToken0,address recipient) returns (uint256 amount0,uint256 amount1)`,
];

let provider;
let signer;
let account;

const $ = (id) => document.getElementById(id);
const value = (id) => $(id).value.trim();

document.querySelectorAll(".tab").forEach((tab) => {
  tab.addEventListener("click", () => {
    document.querySelectorAll(".tab, .panel").forEach((item) => item.classList.remove("active"));
    tab.classList.add("active");
    $(`${tab.dataset.tab}Panel`).classList.add("active");
  });
});

$("connectButton").addEventListener("click", connect);
$("deployForm").addEventListener("submit", deployPool);
$("previewButton").addEventListener("click", previewClaims);
document.querySelectorAll(".claim-action").forEach((button) => button.addEventListener("click", () => claim(button.dataset.claim)));
["tokenA", "tokenB", "feeMode", "staticFee", "tickSpacing", "startingPrice", "poolHook"].forEach((id) => $(id).addEventListener("input", updateSummary));
$("defaultHook").addEventListener("input", () => {
  $("poolHook").value = value("defaultHook");
  $("claimHook").value = value("defaultHook");
  updateSummary();
});

async function connect() {
  if (!window.ethereum) return notify("No EIP-1193 wallet detected.", true);
  try {
    provider = new BrowserProvider(window.ethereum);
    signer = await provider.getSigner();
    account = await signer.getAddress();
    const network = await provider.getNetwork();
    const chainId = Number(network.chainId);
    $("networkLabel").textContent = `${NETWORK_NAMES[chainId] || "Chain"} · ${short(account)}`;
    $("chainIdLabel").textContent = `Chain ${chainId}`;
    $("connectButton").textContent = short(account);
    document.querySelector(".wallet-zone").classList.add("connected");
    if (POSITION_MANAGERS[chainId]) $("positionManager").value = POSITION_MANAGERS[chainId];
    notify("Wallet connected.");
  } catch (error) {
    notify(readError(error), true);
  }
}

function poolKeyFromDeploy() {
  const [currency0, currency1] = sortCurrencies(value("tokenA"), value("tokenB"));
  return {
    currency0,
    currency1,
    fee: value("feeMode") === "dynamic" ? DYNAMIC_FEE_FLAG : Number(value("staticFee")),
    tickSpacing: Number(value("tickSpacing")),
    hooks: checkedAddress(value("poolHook"), "Hook"),
  };
}

function poolKeyFromClaim() {
  const [currency0, currency1] = sortCurrencies(value("claimToken0"), value("claimToken1"));
  return {
    currency0,
    currency1,
    fee: Number(value("claimFee")),
    tickSpacing: Number(value("claimSpacing")),
    hooks: checkedAddress(value("claimHook"), "Hook"),
  };
}

async function deployPool(event) {
  event.preventDefault();
  await ensureConnected();
  const button = event.submitter;
  try {
    setBusy(button, true, "Confirm in wallet…");
    const key = poolKeyFromDeploy();
    const price = Number(value("startingPrice"));
    if (!Number.isFinite(price) || price <= 0) throw new Error("The initial price must be positive.");
    const sqrtPriceX96 = BigInt(Math.floor(Math.sqrt(price) * 2 ** 32)) << 64n;
    const manager = new Contract(checkedAddress(value("positionManager"), "PositionManager"), POSITION_MANAGER_ABI, signer);
    const tx = await manager.initializePool(key, sqrtPriceX96);
    notify(`Pool transaction sent · ${short(tx.hash)}`);
    await tx.wait();
    notify(`Pool initialized · ${short(tx.hash)}`);
  } catch (error) {
    notify(readError(error), true);
  } finally {
    setBusy(button, false, "Initialize pool →");
  }
}

async function previewClaims() {
  await ensureConnected();
  try {
    setBusy($("previewButton"), true, "Reading…");
    const key = poolKeyFromClaim();
    const hook = new Contract(key.hooks, HOOK_ABI, provider);
    const salt = tokenIdSalt();
    const args = [key, account, Number(value("tickLower")), Number(value("tickUpper")), salt];
    const [fees, pending] = await Promise.all([
      hook.previewClaimableFees(...args),
      hook.previewPendingCompensation(...args),
    ]);
    $("feePreview").textContent = `${fees[0]} / ${fees[1]}`;
    $("pendingPreview").textContent = `${pending[0]} / ${pending[1]}`;
    notify("Amounts refreshed.");
  } catch (error) {
    notify(readError(error), true);
  } finally {
    setBusy($("previewButton"), false, "Refresh amounts");
  }
}

async function claim(kind) {
  await ensureConnected();
  const button = document.querySelector(`[data-claim="${kind}"]`);
  try {
    setBusy(button, true, "Confirm in wallet…");
    const key = poolKeyFromClaim();
    const hook = new Contract(key.hooks, HOOK_ABI, signer);
    const common = [key, Number(value("tickLower")), Number(value("tickUpper")), tokenIdSalt()];
    let tx;
    if (kind === "fees") tx = await hook.claimReleasedFees(...common, account);
    if (kind === "pending") tx = await hook.claimPendingCompensation(...common, account);
    if (kind === "manual") tx = await hook.claimCompensation(...common, BigInt(value("lossValue")), account);
    notify(`Claim sent · ${short(tx.hash)}`);
    await tx.wait();
    notify(`Claim confirmed · ${short(tx.hash)}`);
    await previewClaims();
  } catch (error) {
    notify(readError(error), true);
  } finally {
    setBusy(button, false, kind === "fees" ? "Claim rewards" : kind === "pending" ? "Claim compensation" : "Manual claim");
  }
}

function updateSummary() {
  try {
    const key = poolKeyFromDeploy();
    $("poolSummary").textContent = `${short(key.currency0)} / ${short(key.currency1)} · fee ${key.fee} · spacing ${key.tickSpacing} · ${short(key.hooks)}`;
  } catch {
    $("poolSummary").textContent = "Complete the parameters";
  }
}

function sortCurrencies(a, b) {
  const first = checkedAddress(a, "Token A");
  const second = checkedAddress(b, "Token B");
  if (first.toLowerCase() === second.toLowerCase()) throw new Error("The two currencies must be different.");
  return BigInt(first) < BigInt(second) ? [first, second] : [second, first];
}

function checkedAddress(address, label) {
  if (!isAddress(address)) throw new Error(`${label}: invalid address.`);
  return getAddress(address);
}

function tokenIdSalt() {
  const tokenId = BigInt(value("positionTokenId"));
  return zeroPadValue(toBeHex(tokenId), 32);
}

async function ensureConnected() {
  if (!signer || !account) await connect();
  if (!signer || !account) throw new Error("Connect a wallet.");
}

function setBusy(button, busy, label) {
  if (!button) return;
  button.disabled = busy;
  button.textContent = label;
}

function short(text) {
  return `${text.slice(0, 6)}…${text.slice(-4)}`;
}

let toastTimer;
function notify(message, isError = false) {
  clearTimeout(toastTimer);
  $("toast").textContent = message;
  $("toast").className = `toast show${isError ? " error" : ""}`;
  toastTimer = setTimeout(() => { $("toast").className = "toast"; }, 5000);
}

function readError(error) {
  return error?.shortMessage || error?.reason || error?.message || "Transaction failed.";
}

if (window.ethereum) {
  window.ethereum.on?.("accountsChanged", () => location.reload());
  window.ethereum.on?.("chainChanged", () => location.reload());
}
