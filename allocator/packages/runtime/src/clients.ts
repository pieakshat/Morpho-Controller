/**
 * viem clients, plus the one check worth making before anything else talks to the network.
 *
 * No chain object is imported. The whole system is chain-agnostic by design: every address
 * comes from the deployment record, and viem only needs the id and the transport.
 */

import { createPublicClient, createWalletClient, http, type Account, type Chain, type PublicClient, type Transport, type WalletClient } from "viem";
import { privateKeyToAccount } from "viem/accounts";

import type { RuntimeConfig } from "./config.js";

/**
 * A minimal chain descriptor built from the config.
 *
 * viem wants a `Chain` for fee estimation and for typing; it does not want an opinion about
 * which chain this is. Constructing one here rather than importing from `viem/chains` is what
 * lets an anvil fork of Arbitrum (chainid 42161, RPC on localhost) work without a special case.
 */
export function chainFrom(config: RuntimeConfig): Chain {
  return {
    id: config.chainId,
    name: `chain-${config.chainId}`,
    nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
    rpcUrls: { default: { http: [config.rpcUrl] } },
  };
}

export interface Clients {
  publicClient: PublicClient<Transport, Chain>;
  /** Present only when ALLOCATOR_PRIVATE_KEY was set. Reads and simulations do not need it. */
  walletClient: WalletClient<Transport, Chain, Account> | undefined;
  /** The allocator EOA. Needed by the quote layer as `txOrigin` even when not submitting. */
  account: Account | undefined;
}

export function createClients(config: RuntimeConfig): Clients {
  const chain = chainFrom(config);
  const transport = http(config.rpcUrl, { timeout: config.rpcTimeoutMs });

  const publicClient = createPublicClient({ chain, transport });

  const account = config.allocatorKey ? privateKeyToAccount(config.allocatorKey) : undefined;
  const walletClient = account ? createWalletClient({ account, chain, transport }) : undefined;

  return { publicClient, walletClient, account };
}

/**
 * Confirms the RPC is actually on the chain the deployment record describes.
 *
 * Worth a round trip at startup. The addresses in `deployments/<chainid>.json` are meaningless
 * on any other chain, and the symptom of getting this wrong is not a clean revert: a read
 * against an address holding no code returns empty data, which decodes as zeros, which looks
 * like a vault holding nothing rather than like a misconfiguration.
 */
export async function assertChainMatches(clients: Clients, config: RuntimeConfig): Promise<void> {
  const live = await clients.publicClient.getChainId();
  if (live !== config.chainId) {
    throw new Error(`RPC_URL reports chain ${live}, but CHAIN_ID and the deployment record say ${config.chainId}`);
  }
}

/** The address that will send transactions, or a clear failure naming the missing variable. */
export function requireAllocator(clients: Clients): Account {
  if (!clients.account) {
    throw new Error("ALLOCATOR_PRIVATE_KEY is not set; this path signs a transaction and cannot run without it");
  }
  return clients.account;
}
