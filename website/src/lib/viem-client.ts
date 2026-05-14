// Read-only viem client for the live-stats / leaderboard pages.
//
// IMPORTANT: this code runs entirely in the visitor's browser. The default
// RPC is Coinbase's public Base endpoint, which is free but rate-limited.
// Visitors who want to scan large ranges of `Mined` events should override


import { createPublicClient, fallback, http, type Address } from "viem";
import { base } from "viem/chains";

const DEFAULT_RPC = "https://mainnet.base.org";
const FALLBACK_RPCS = [
  "https://base-rpc.publicnode.com",
  "https://base.llamarpc.com",
];

const userRpc =
  typeof window !== "undefined"
    ? window.localStorage.getItem("anvil256:rpc") ?? DEFAULT_RPC
    : DEFAULT_RPC;

export const client = createPublicClient({
  chain: base,
  transport: fallback(
    [userRpc, ...FALLBACK_RPCS]
      .filter((rpc, i, all) => all.indexOf(rpc) === i)
      .map((rpc) => http(rpc)),
    { retryCount: 1 }
  ),
});

export const ACTIVE_RPC = userRpc;

/** Anvil256 contract address on Base mainnet. */
export const ANVIL256_ADDRESS: Address =
  (import.meta.env.PUBLIC_ANVIL256_ADDRESS as Address) ??
  ("0x8C3199578834914AC08Eb628475D4Cfd26e011c2" as Address);

/** Minimum ABI used by the live-stats page. */
export const anvil256Abi = [
  {
    type: "function",
    name: "currentEpoch",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "uint256" }],
  },
  {
    type: "function",
    name: "currentDifficulty",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "uint256" }],
  },
  {
    type: "function",
    name: "currentReward",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "uint256" }],
  },
  {
    type: "function",
    name: "totalSupply",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "uint256" }],
  },
  {
    type: "function",
    name: "currentFeeWei",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "uint256" }],
  },
  {
    type: "function",
    name: "feeRecipient",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "address" }],
  },
  {
    type: "function",
    name: "integralErrorWad",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "int256" }],
  },
  {
    type: "function",
    name: "epochEntropy",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "bytes32" }],
  },
  {
    type: "function",
    name: "lastMineBlock",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "uint256" }],
  },
  {
    type: "event",
    name: "Mined",
    inputs: [
      { name: "miner",  type: "address", indexed: true },
      { name: "epoch",  type: "uint256", indexed: true },
      { name: "nonce",  type: "uint256", indexed: false },
      { name: "hash",   type: "bytes32", indexed: false },
      { name: "reward", type: "uint256", indexed: false },
      { name: "feeWei", type: "uint256", indexed: false },
    ],
    anonymous: false,
  },
  {
    type: "event",
    name: "DifficultyAdjusted",
    inputs: [
      { name: "period",              type: "uint256", indexed: true  },
      { name: "oldDifficulty",       type: "uint256", indexed: false },
      { name: "newDifficulty",       type: "uint256", indexed: false },
      { name: "actualWindowSeconds", type: "uint256", indexed: false },
      { name: "targetWindowSeconds", type: "uint256", indexed: false },
      { name: "integralWad",         type: "int256",  indexed: false },
      { name: "controlSignalWad",    type: "int256",  indexed: false },
    ],
    anonymous: false,
  },
  {
    type: "event",
    name: "FeeStuck",
    inputs: [
      { name: "amountWei", type: "uint256", indexed: false },
      { name: "recipient", type: "address", indexed: true  },
    ],
    anonymous: false,
  },
  {
    type: "event",
    name: "RefundQueued",
    inputs: [
      { name: "payer",  type: "address", indexed: true  },
      { name: "amount", type: "uint256", indexed: false },
    ],
    anonymous: false,
  },
  {
    type: "event",
    name: "RefundClaimed",
    inputs: [
      { name: "payer",  type: "address", indexed: true  },
      { name: "amount", type: "uint256", indexed: false },
    ],
    anonymous: false,
  },
  {
    type: "function",
    name: "periodIndex",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "uint256" }],
  },
  {
    type: "function",
    name: "periodStartTime",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "uint256" }],
  },
  {
    type: "function",
    name: "lpReserveEthWei",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "uint256" }],
  },
  {
    type: "function",
    name: "lpReserveTokenWei",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "uint256" }],
  },
  {
    type: "function",
    name: "liquidityPool",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "address" }],
  },
  {
    type: "function",
    name: "liquidityLive",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "bool" }],
  },
  {
    type: "function",
    name: "liquidityTriggerSupply",
    stateMutability: "pure",
    inputs: [],
    outputs: [{ type: "uint256" }],
  },
  {
    type: "function",
    name: "genesisBlockHash",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "bytes32" }],
  },
  {
    type: "function",
    name: "pendingRefundsWei",
    stateMutability: "view",
    inputs: [{ name: "payer", type: "address" }],
    outputs: [{ type: "uint256" }],
  },
] as const;
