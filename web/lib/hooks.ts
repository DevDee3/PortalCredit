"use client";

import { useCallback, useState } from "react";
import { useConnection, usePublicClient, useWriteContract } from "wagmi";
import { useQueryClient } from "@tanstack/react-query";
import type { Abi, Address } from "viem";

function friendlyError(e: unknown): string {
  const m = ((e as { shortMessage?: string }).shortMessage ?? (e as Error).message ?? "").toString();
  if (/user rejected|denied|rejected the request/i.test(m)) return "You cancelled the request in your wallet.";
  if (/insufficient funds/i.test(m)) return "Not enough POT in your wallet to pay network fees.";
  if (/allowance/i.test(m)) return "Token approval is missing. Please try again and approve first.";
  if (/PriceTooHigh/.test(m)) return "The auction price moved. Please try again.";
  if (/NotYet|DisputeWindowOpen/.test(m)) return "Too early: this step is not available yet.";
  if (/BadStatus/.test(m)) return "This action is not available in the loan's current state.";
  if (/InsufficientLiquidity/.test(m)) return "The vault does not have enough free liquidity right now.";
  return m.split("\n")[0].slice(0, 140) || "Transaction failed.";
}

export type TxState = { status: "idle" | "pending" | "done" | "error"; hash?: `0x${string}`; error?: string; label?: string };

/** Sends a contract write, waits for the receipt, then refreshes all queries. */
export function useTx() {
  const { mutateAsync } = useWriteContract();
  const client = usePublicClient();
  const qc = useQueryClient();
  const [state, setState] = useState<TxState>({ status: "idle" });

  const send = useCallback(
    async (label: string, req: { address: Address; abi: Abi | readonly unknown[]; functionName: string; args?: readonly unknown[] }) => {
      setState({ status: "pending", label });
      try {
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        const hash = await mutateAsync(req as any);
        setState({ status: "pending", hash, label });
        await client?.waitForTransactionReceipt({ hash });
        setState({ status: "done", hash, label });
        await qc.invalidateQueries();
        return hash;
      } catch (e) {
        const msg = friendlyError(e);
        setState({ status: "error", error: msg, label });
        return undefined;
      }
    },
    [mutateAsync, client, qc],
  );

  return { send, state, busy: state.status === "pending" };
}

export function useMe() {
  const { address, isConnected } = useConnection();
  return { address, isConnected };
}

import { useQuery } from "@tanstack/react-query";

/** Generic on-chain read via individual eth_call (no multicall assumption). */
export function useChain<T>(key: unknown[], fn: (c: NonNullable<ReturnType<typeof usePublicClient>>) => Promise<T>, enabled = true) {
  const client = usePublicClient();
  return useQuery({
    queryKey: ["chain", ...key],
    queryFn: () => fn(client!),
    enabled: enabled && !!client,
  });
}
