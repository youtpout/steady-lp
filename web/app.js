import {
  AbiCoder,
  BrowserProvider,
  Contract,
  Interface,
  MaxUint256,
  concat,
  getAddress,
  isAddress,
  toBeHex,
  zeroPadValue,
} from "ethers";
import { bootstrapWallet, walletConnectConfigured } from "./wallet.jsx";

const ZERO = "0x0000000000000000000000000000000000000000";
const PERMIT2 = "0x000000000022D473030F116dDEE9F6B43aC78BA3";
const DYNAMIC_FEE_FLAG = 0x800000;
const MAX_UINT160 = (1n << 160n) - 1n;
const MAX_UINT48 = (1n << 48n) - 1n;
const coder = AbiCoder.defaultAbiCoder();

const DEPLOYMENTS = {
  1: { name: "Ethereum", position: "0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e", router: "0x66a9893cc07d91d95644aedd05d03f95e1dba8af" },
  10: { name: "Optimism", position: "0x3C3Ea4B57a46241e54610e5f022E5c45859A1017", router: "0x851116d9223fabed8e56c0e6b8ad0c31d98b3507" },
  130: { name: "Unichain", position: "0x4529A01c7A0410167c5740C487A8DE60232617bf", router: "0xef740bf23acae26f6492b10de645d6b98dc8eaf3" },
  8453: { name: "Base", position: "0x7C5f5A4bBd8fD63184577525326123B519429bDc", router: "0x6ff5693b99212da76ad316178a184ab56d299b43" },
  11155111: { name: "Sepolia", position: "0x429ba70129df741B2Ca2a85BC3A2a3328e5c09b4", router: "0x3A9D48AB9751398BbFa63ad67599Bb04e4BdF98b" },
  84532: { name: "Base Sepolia", position: "0x4B2C77d209D3405F41a037Ec6c77F7F5b8e2ca80", router: "0x492e6456d9528771018deb9e87ef7750ef184104" },
  421614: { name: "Arbitrum Sepolia", position: "0xAc631556d3d4019C95769033B5E719dD77124BAc", router: "0xefd1d4bd4cf1e86da286bb4cb1b8bced9c10ba47" },
};

const POOL = "tuple(address currency0,address currency1,uint24 fee,int24 tickSpacing,address hooks)";
const ERC20_ABI = ["function approve(address spender,uint256 amount) returns (bool)", "function allowance(address owner,address spender) view returns (uint256)"];
const PERMIT2_ABI = ["function approve(address token,address spender,uint160 amount,uint48 expiration)", "function allowance(address owner,address token,address spender) view returns (uint160 amount,uint48 expiration,uint48 nonce)"];
const POSITION_ABI = [
  `function initializePool(${POOL} key,uint160 sqrtPriceX96) payable returns (int24)`,
  "function modifyLiquidities(bytes unlockData,uint256 deadline) payable",
  "function multicall(bytes[] data) payable returns (bytes[] results)",
  `function getPoolAndPositionInfo(uint256 tokenId) view returns (${POOL} poolKey,uint256 info)`,
  "function getPositionLiquidity(uint256 tokenId) view returns (uint128 liquidity)",
  "function ownerOf(uint256 tokenId) view returns (address)",
];
const ROUTER_ABI = ["function execute(bytes commands,bytes[] inputs,uint256 deadline) payable"];
const HOOK_ABI = [
  `function previewClaimableFees(${POOL} key,address operator,int24 tickLower,int24 tickUpper,bytes32 salt) view returns (uint256,uint256)`,
  `function previewPendingCompensation(${POOL} key,address operator,int24 tickLower,int24 tickUpper,bytes32 salt) view returns (uint256,uint256)`,
  `function claimReleasedFees(${POOL} key,int24 tickLower,int24 tickUpper,bytes32 salt,address recipient) returns (uint256,uint256)`,
  `function claimPendingCompensation(${POOL} key,int24 tickLower,int24 tickUpper,bytes32 salt,address recipient) returns (uint256,uint256)`,
  `function claimCompensation(${POOL} key,int24 tickLower,int24 tickUpper,bytes32 salt,uint256 lossValueToken0,address recipient) returns (uint256,uint256)`,
];

const positionInterface = new Interface(POSITION_ABI);
let provider;
let signer;
let account;

const $ = (id) => document.getElementById(id);
const value = (id) => $(id).value.trim();
const raw = (id) => BigInt(value(id) || "0");

setupPoolKeyFields();
setupTabs();
bootstrapWallet(handleWalletChange);
$("walletConnectWarning").hidden = walletConnectConfigured;

$("deployForm").addEventListener("submit", deployPool);
$("swapForm").addEventListener("submit", executeSwap);
$("liquidityForm").addEventListener("submit", manageLiquidity);
$("loadPositionButton").addEventListener("click", loadPosition);
$("previewButton").addEventListener("click", previewClaims);
$("addInitialLiquidity").addEventListener("change", (event) => $("initialLiquidityFields").classList.toggle("visible", event.target.checked));
document.querySelectorAll(".approval-action").forEach((button) => button.addEventListener("click", () => approveFor(button.dataset.target, button)));
document.querySelectorAll(".claim-action").forEach((button) => button.addEventListener("click", () => claim(button.dataset.claim)));
["tokenA", "tokenB", "feeMode", "staticFee", "tickSpacing", "startingPrice", "poolHook"].forEach((id) => $(id).addEventListener("input", updateSummary));
$("defaultHook").addEventListener("input", syncDefaultHook);

function setupTabs() {
  document.querySelectorAll(".tab").forEach((tab) => tab.addEventListener("click", () => {
    document.querySelectorAll(".tab, .panel").forEach((item) => item.classList.remove("active"));
    tab.classList.add("active");
    $(`${tab.dataset.tab}Panel`).classList.add("active");
  }));
}

function setupPoolKeyFields() {
  document.querySelectorAll(".pool-key-fields").forEach((container) => {
    const prefix = container.closest("#swapPanel") ? "swap" : "manage";
    container.innerHTML = `
      <label><span>Token 0</span><input id="${prefix}Token0" placeholder="0x…" required /></label>
      <label><span>Token 1</span><input id="${prefix}Token1" placeholder="0x…" required /></label>
      <label><span>Pool fee</span><input id="${prefix}Fee" type="number" value="${DYNAMIC_FEE_FLAG}" required /></label>
      <label><span>Tick spacing</span><input id="${prefix}Spacing" type="number" value="60" required /></label>
      <label><span>Hook</span><input id="${prefix}Hook" placeholder="0x…" required /></label>`;
  });
}

async function handleWalletChange({ address, chainId, isConnected, walletClient }) {
  if (!isConnected || !address || !walletClient) {
    provider = undefined;
    signer = undefined;
    account = undefined;
    $("networkLabel").textContent = "Wallet not connected";
    document.querySelector(".wallet-zone").classList.remove("connected");
    return;
  }
  try {
    provider = new BrowserProvider(walletClient.transport);
    signer = await provider.getSigner();
    account = address;
    applyDeployment(chainId);
    $("networkLabel").textContent = `${DEPLOYMENTS[chainId]?.name || `Chain ${chainId}`} · ${short(account)}`;
    $("chainIdLabel").textContent = `Chain ${chainId}`;
    document.querySelector(".wallet-zone").classList.add("connected");
  } catch (error) {
    notify(readError(error), true);
  }
}

function applyDeployment(chainId) {
  const deployment = DEPLOYMENTS[chainId];
  if (deployment) {
    $("positionManager").value = deployment.position;
    $("universalRouter").value = deployment.router;
  }
  $("permit2").value = PERMIT2;
}

async function deployPool(event) {
  event.preventDefault();
  const button = event.submitter;
  try {
    await ensureConnected();
    setBusy(button, true, "Preparing transaction…");
    const { key, reversed } = deployPoolKey();
    validatePoolKey(key);
    const positionManager = checkedAddress(value("positionManager"), "PositionManager");
    const price = Number(value("startingPrice"));
    if (!Number.isFinite(price) || price <= 0) throw new Error("The initial price must be positive.");
    const orderedPrice = reversed ? 1 / price : price;
    const sqrtPriceX96 = BigInt(Math.floor(Math.sqrt(orderedPrice) * 2 ** 32)) << 64n;
    const manager = new Contract(positionManager, POSITION_ABI, signer);

    let tx;
    if ($("addInitialLiquidity").checked) {
      validateTicks(Number(value("initialTickLower")), Number(value("initialTickUpper")), key.tickSpacing);
      await approveTokens([key.currency0, key.currency1], positionManager);
      const hookData = coder.encode(["address"], [account]);
      const unlockData = encodeMint(key, Number(value("initialTickLower")), Number(value("initialTickUpper")), raw("initialLiquidity"), raw("initialAmount0Max"), raw("initialAmount1Max"), hookData);
      const calls = [
        positionInterface.encodeFunctionData("initializePool", [key, sqrtPriceX96]),
        positionInterface.encodeFunctionData("modifyLiquidities", [unlockData, deadline("initialDeadline")]),
      ];
      tx = await manager.multicall(calls, { value: key.currency0 === ZERO ? raw("initialAmount0Max") : 0n });
    } else {
      tx = await manager.initializePool(key, sqrtPriceX96);
    }
    await waitFor(tx, "Pool initialized");
  } catch (error) {
    notify(readError(error), true);
  } finally {
    setBusy(button, false, "Initialize pool →");
  }
}

async function executeSwap(event) {
  event.preventDefault();
  const button = event.submitter;
  try {
    await ensureConnected();
    setBusy(button, true, "Preparing swap…");
    const key = sectionPoolKey("swap");
    validatePoolKey(key);
    const zeroForOne = value("swapDirection") === "true";
    const inputCurrency = zeroForOne ? key.currency0 : key.currency1;
    const outputCurrency = zeroForOne ? key.currency1 : key.currency0;
    const amountIn = raw("swapAmountIn");
    const amountOutMin = raw("swapAmountOutMin");
    const routerAddress = checkedAddress(value("universalRouter"), "Universal Router");
    await approveTokens([inputCurrency], routerAddress);

    const swapParams = coder.encode(
      [`tuple(${POOL} poolKey,bool zeroForOne,uint128 amountIn,uint128 amountOutMinimum,bytes hookData)`],
      [[key, zeroForOne, amountIn, amountOutMin, "0x"]],
    );
    const actions = actionsHex(0x06, 0x0c, 0x0f);
    const params = [
      swapParams,
      coder.encode(["address", "uint256"], [inputCurrency, amountIn]),
      coder.encode(["address", "uint256"], [outputCurrency, amountOutMin]),
    ];
    const input = coder.encode(["bytes", "bytes[]"], [actions, params]);
    const router = new Contract(routerAddress, ROUTER_ABI, signer);
    const tx = await router.execute("0x10", [input], deadline("swapDeadline"), { value: inputCurrency === ZERO ? amountIn : 0n });
    await waitFor(tx, "Swap confirmed");
  } catch (error) {
    notify(readError(error), true);
  } finally {
    setBusy(button, false, "Execute swap →");
  }
}

async function manageLiquidity(event) {
  event.preventDefault();
  const button = event.submitter;
  try {
    await ensureConnected();
    setBusy(button, true, "Preparing operation…");
    const key = sectionPoolKey("manage");
    validatePoolKey(key);
    const operation = value("liquidityOperation");
    const positionManager = checkedAddress(value("positionManager"), "PositionManager");
    if (operation === "increase") await approveTokens([key.currency0, key.currency1], positionManager);
    const tokenId = raw("manageTokenId");
    const liquidity = raw("manageLiquidity");
    const amount0 = raw("manageAmount0");
    const amount1 = raw("manageAmount1");
    const hookData = coder.encode(["address"], [account]);
    const unlockData = encodeLiquidityOperation(operation, key, tokenId, liquidity, amount0, amount1, hookData);
    const manager = new Contract(positionManager, POSITION_ABI, signer);
    const tx = await manager.modifyLiquidities(unlockData, deadline("manageDeadline"), {
      value: operation === "increase" && key.currency0 === ZERO ? amount0 : 0n,
    });
    await waitFor(tx, "Liquidity operation confirmed");
  } catch (error) {
    notify(readError(error), true);
  } finally {
    setBusy(button, false, "Submit operation →");
  }
}

async function loadPosition() {
  try {
    await ensureConnected();
    setBusy($("loadPositionButton"), true, "Loading…");
    const manager = new Contract(checkedAddress(value("positionManager"), "PositionManager"), POSITION_ABI, provider);
    const tokenId = raw("manageTokenId");
    const [poolInfo, liquidity, owner] = await Promise.all([
      manager.getPoolAndPositionInfo(tokenId),
      manager.getPositionLiquidity(tokenId),
      manager.ownerOf(tokenId),
    ]);
    const [currency0, currency1, fee, tickSpacing, hooks] = poolInfo.poolKey;
    const info = BigInt(poolInfo.info);
    const tickLower = signed24((info >> 8n) & 0xffffffn);
    const tickUpper = signed24((info >> 32n) & 0xffffffn);
    fillPoolKey("manage", { currency0, currency1, fee, tickSpacing, hooks });
    $("manageLiquidity").value = liquidity.toString();
    $("claimToken0").value = currency0;
    $("claimToken1").value = currency1;
    $("claimFee").value = fee.toString();
    $("claimSpacing").value = tickSpacing.toString();
    $("claimHook").value = hooks;
    $("positionTokenId").value = tokenId.toString();
    $("tickLower").value = tickLower;
    $("tickUpper").value = tickUpper;
    notify(`Position loaded · owner ${short(owner)}`);
  } catch (error) {
    notify(readError(error), true);
  } finally {
    setBusy($("loadPositionButton"), false, "Load position ID");
  }
}

async function approveFor(target, button) {
  try {
    await ensureConnected();
    setBusy(button, true, "Approving…");
    const key = sectionPoolKey(target === "router" ? "swap" : "manage");
    const spender = checkedAddress(value(target === "router" ? "universalRouter" : "positionManager"), target === "router" ? "Universal Router" : "PositionManager");
    const tokens = target === "router"
      ? [value("swapDirection") === "true" ? key.currency0 : key.currency1]
      : [key.currency0, key.currency1];
    await approveTokens(tokens, spender);
    notify("Approvals ready.");
  } catch (error) {
    notify(readError(error), true);
  } finally {
    setBusy(button, false, target === "router" ? "Approve input token" : "Approve pool tokens");
  }
}

async function approveTokens(tokens, spender) {
  const permit2Address = checkedAddress(value("permit2"), "Permit2");
  for (const token of tokens.filter((token, index, all) => token !== ZERO && all.indexOf(token) === index)) {
    const erc20 = new Contract(token, ERC20_ABI, signer);
    if ((await erc20.allowance(account, permit2Address)) < MaxUint256 / 2n) await waitFor(await erc20.approve(permit2Address, MaxUint256), "Permit2 token approval confirmed");
    const permit2 = new Contract(permit2Address, PERMIT2_ABI, signer);
    const allowance = await permit2.allowance(account, token, spender);
    if (allowance.amount < MAX_UINT160 / 2n) await waitFor(await permit2.approve(token, spender, MAX_UINT160, MAX_UINT48), "Permit2 spender approval confirmed");
  }
}

async function previewClaims() {
  try {
    await ensureConnected();
    setBusy($("previewButton"), true, "Reading…");
    const key = claimPoolKey();
    const hook = new Contract(key.hooks, HOOK_ABI, provider);
    const args = [key, account, Number(value("tickLower")), Number(value("tickUpper")), tokenIdSalt()];
    const [fees, pending] = await Promise.all([hook.previewClaimableFees(...args), hook.previewPendingCompensation(...args)]);
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
  const button = document.querySelector(`[data-claim="${kind}"]`);
  try {
    await ensureConnected();
    setBusy(button, true, "Confirm in wallet…");
    const key = claimPoolKey();
    const hook = new Contract(key.hooks, HOOK_ABI, signer);
    const common = [key, Number(value("tickLower")), Number(value("tickUpper")), tokenIdSalt()];
    const tx = kind === "fees"
      ? await hook.claimReleasedFees(...common, account)
      : kind === "pending"
        ? await hook.claimPendingCompensation(...common, account)
        : await hook.claimCompensation(...common, raw("lossValue"), account);
    await waitFor(tx, "Claim confirmed");
    await previewClaims();
  } catch (error) {
    notify(readError(error), true);
  } finally {
    setBusy(button, false, kind === "fees" ? "Claim rewards" : kind === "pending" ? "Claim compensation" : "Manual claim");
  }
}

function encodeMint(key, tickLower, tickUpper, liquidity, amount0Max, amount1Max, hookData) {
  const actions = actionsHex(0x02, 0x0d, 0x14, 0x14);
  const params = [
    coder.encode([POOL, "int24", "int24", "uint256", "uint128", "uint128", "address", "bytes"], [key, tickLower, tickUpper, liquidity, amount0Max, amount1Max, account, hookData]),
    coder.encode(["address", "address"], [key.currency0, key.currency1]),
    coder.encode(["address", "address"], [key.currency0, account]),
    coder.encode(["address", "address"], [key.currency1, account]),
  ];
  return coder.encode(["bytes", "bytes[]"], [actions, params]);
}

function encodeLiquidityOperation(operation, key, tokenId, liquidity, amount0, amount1, hookData) {
  if (operation === "increase") {
    return coder.encode(["bytes", "bytes[]"], [
      actionsHex(0x00, 0x0d, 0x14, 0x14),
      [
        coder.encode(["uint256", "uint256", "uint128", "uint128", "bytes"], [tokenId, liquidity, amount0, amount1, hookData]),
        coder.encode(["address", "address"], [key.currency0, key.currency1]),
        coder.encode(["address", "address"], [key.currency0, account]),
        coder.encode(["address", "address"], [key.currency1, account]),
      ],
    ]);
  }
  const action = operation === "burn" ? 0x03 : 0x01;
  const actionParams = action === 0x03
    ? coder.encode(["uint256", "uint128", "uint128", "bytes"], [tokenId, amount0, amount1, hookData])
    : coder.encode(["uint256", "uint256", "uint128", "uint128", "bytes"], [tokenId, operation === "collect" ? 0n : liquidity, amount0, amount1, hookData]);
  return coder.encode(["bytes", "bytes[]"], [
    actionsHex(action, 0x11),
    [actionParams, coder.encode(["address", "address", "address"], [key.currency0, key.currency1, account])],
  ]);
}

function deployPoolKey() {
  const a = checkedAddress(value("tokenA"), "Token A");
  const b = checkedAddress(value("tokenB"), "Token B");
  if (a.toLowerCase() === b.toLowerCase()) throw new Error("The two currencies must be different.");
  const reversed = BigInt(a) > BigInt(b);
  return {
    reversed,
    key: {
      currency0: reversed ? b : a,
      currency1: reversed ? a : b,
      fee: value("feeMode") === "dynamic" ? DYNAMIC_FEE_FLAG : Number(value("staticFee")),
      tickSpacing: Number(value("tickSpacing")),
      hooks: checkedAddress(value("poolHook"), "Hook"),
    },
  };
}

function sectionPoolKey(prefix) {
  return sortedPoolKey(value(`${prefix}Token0`), value(`${prefix}Token1`), value(`${prefix}Fee`), value(`${prefix}Spacing`), value(`${prefix}Hook`));
}

function claimPoolKey() {
  return sortedPoolKey(value("claimToken0"), value("claimToken1"), value("claimFee"), value("claimSpacing"), value("claimHook"));
}

function sortedPoolKey(token0, token1, fee, spacing, hook) {
  const a = checkedAddress(token0, "Token 0");
  const b = checkedAddress(token1, "Token 1");
  if (BigInt(a) >= BigInt(b)) throw new Error("Pool currencies must be entered in ascending address order.");
  return { currency0: a, currency1: b, fee: Number(fee), tickSpacing: Number(spacing), hooks: checkedAddress(hook, "Hook") };
}

function validatePoolKey(key) {
  if (key.fee < 0 || (key.fee !== DYNAMIC_FEE_FLAG && key.fee > 1_000_000)) throw new Error("Invalid pool fee.");
  if (!Number.isInteger(key.tickSpacing) || key.tickSpacing < 1 || key.tickSpacing > 32767) throw new Error("Invalid tick spacing.");
}

function validateTicks(lower, upper, spacing) {
  if (lower >= upper || lower % spacing !== 0 || upper % spacing !== 0) throw new Error("Ticks must be ordered multiples of tick spacing.");
}

function syncDefaultHook() {
  ["poolHook", "claimHook", "swapHook", "manageHook"].forEach((id) => { $(id).value = value("defaultHook"); });
  updateSummary();
}

function fillPoolKey(prefix, key) {
  $(`${prefix}Token0`).value = key.currency0;
  $(`${prefix}Token1`).value = key.currency1;
  $(`${prefix}Fee`).value = key.fee.toString();
  $(`${prefix}Spacing`).value = key.tickSpacing.toString();
  $(`${prefix}Hook`).value = key.hooks;
}

function updateSummary() {
  try {
    const { key } = deployPoolKey();
    $("poolSummary").textContent = `${short(key.currency0)} / ${short(key.currency1)} · fee ${key.fee} · spacing ${key.tickSpacing} · ${short(key.hooks)}`;
  } catch {
    $("poolSummary").textContent = "Complete the parameters";
  }
}

function tokenIdSalt() {
  return zeroPadValue(toBeHex(raw("positionTokenId")), 32);
}

function deadline(inputId) {
  return BigInt(Math.floor(Date.now() / 1000) + Number(value(inputId)) * 60);
}

function actionsHex(...actions) {
  return concat(actions.map((action) => toBeHex(action, 1)));
}

function signed24(value24) {
  return Number(value24 >= 0x800000n ? value24 - 0x1000000n : value24);
}

function checkedAddress(address, label) {
  if (!isAddress(address)) throw new Error(`${label}: invalid address.`);
  return getAddress(address);
}

async function ensureConnected() {
  if (!signer || !account) {
    throw new Error("Connect a browser or mobile wallet to continue.");
  }
}

async function waitFor(tx, label) {
  notify(`Transaction sent · ${short(tx.hash)}`);
  await tx.wait();
  notify(`${label} · ${short(tx.hash)}`);
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
