"use client";

import Link from "next/link";
import { useState } from "react";
import { keccak256, toBytes } from "viem";
import { ADDR, CONFIGURED, STATUS } from "@/lib/config";
import { engineAbi, nftAbi, stableAbi, vaultAbi } from "@/lib/abis";
import { useChain, useMe, useTx } from "@/lib/hooks";
import { dateTime, fmt, parseStable } from "@/lib/format";
import { Badge, Btn, Card, ConnectHint, NotConfigured, TxStatus } from "@/components/ui";

export default function BorrowPage() {
  const { address, isConnected } = useMe();
  const { send, state, busy } = useTx();
  const [face, setFace] = useState("1000");
  const [mins, setMins] = useState("5");
  const [obligor, setObligor] = useState("Acme Logistics Ltd");

  const list = useChain(["mine", address], async (c) => {
    const n = Number(await c.readContract({ address: ADDR.nft, abi: nftAbi, functionName: "nextId" }));
    const out: { id: bigint; face: bigint; due: bigint; status: number; active: boolean; debt: bigint; locked: boolean }[] = [];
    for (let i = 1; i <= n; i++) {
      const id = BigInt(i);
      const [rec, loan] = await Promise.all([
        c.readContract({ address: ADDR.nft, abi: nftAbi, functionName: "receivable", args: [id] }),
        c.readContract({ address: ADDR.vault, abi: vaultAbi, functionName: "loans", args: [id] }),
      ]);
      const mine = rec.originator.toLowerCase() === address!.toLowerCase() || loan[0].toLowerCase() === address!.toLowerCase();
      if (!mine) continue;
      const [status, debt, locked] = await Promise.all([
        c.readContract({ address: ADDR.engine, abi: engineAbi, functionName: "statusOf", args: [id] }),
        c.readContract({ address: ADDR.vault, abi: vaultAbi, functionName: "debtOf", args: [id] }),
        c.readContract({ address: ADDR.nft, abi: nftAbi, functionName: "locked", args: [id] }),
      ]);
      out.push({ id, face: rec.faceValue, due: rec.dueDate, status: Number(status), active: loan[1], debt, locked });
    }
    return out.reverse();
  }, CONFIGURED && !!address);

  const allowance = useChain(["stable-allow", address], (c) =>
    c.readContract({ address: ADDR.stable, abi: stableAbi, functionName: "allowance", args: [address!, ADDR.vault] }), CONFIGURED && !!address);

  if (!CONFIGURED) return <NotConfigured />;
  const faceAmt = parseStable(face);

  async function mint() {
    if (!faceAmt) return;
    const due = BigInt(Math.floor(Date.now() / 1000) + Math.max(1, Number(mins)) * 60);
    await send("Mint receivable", {
      address: ADDR.nft, abi: nftAbi, functionName: "mint",
      args: [faceAmt, due, keccak256(toBytes(obligor)), `ipfs://portalcredit/invoice/${Date.now()}`],
    });
  }
  async function advance(id: bigint) {
    if (!(await send("Approve NFT", { address: ADDR.nft, abi: nftAbi, functionName: "approve", args: [ADDR.vault, id] }))) return;
    await send("Advance", { address: ADDR.vault, abi: vaultAbi, functionName: "advance", args: [id] });
  }
  async function repay(id: bigint, debt: bigint) {
    if ((allowance.data ?? 0n) < debt) {
      if (!(await send("Approve pcUSD", { address: ADDR.stable, abi: stableAbi, functionName: "approve", args: [ADDR.vault, debt] }))) return;
    }
    await send("Repay", { address: ADDR.vault, abi: vaultAbi, functionName: "repay", args: [id, debt] });
  }

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-3xl font-semibold">Borrow against an invoice</h1>
        <p className="mt-2 text-sm text-muted">Mint a receivable, advance 80% of its value, repay before the due date to get it back. Demo due dates are set in minutes.</p>
      </div>

      <Card title="1. Mint a receivable NFT">
        <div className="grid gap-3 md:grid-cols-3">
          <label className="text-xs text-muted">Face value (pcUSD)<input className="mt-1" value={face} onChange={(e) => setFace(e.target.value)} /></label>
          <label className="text-xs text-muted">Due in (minutes, demo)<input className="mt-1" value={mins} onChange={(e) => setMins(e.target.value)} /></label>
          <label className="text-xs text-muted">Obligor (hashed on-chain)<input className="mt-1" value={obligor} onChange={(e) => setObligor(e.target.value)} /></label>
        </div>
        <div className="mt-3"><Btn onClick={mint} disabled={!isConnected || busy || !faceAmt}>Mint receivable</Btn></div>
      </Card>

      <Card title="2. Your receivables">
        {!isConnected && <ConnectHint />}
        {isConnected && list.isLoading && <div className="h-12 animate-pulse rounded bg-panel2" />}
        {isConnected && list.data?.length === 0 && <p className="text-sm text-muted">Nothing yet. Mint one above.</p>}
        <div className="divide-y divide-line">
          {list.data?.map((r) => {
            const status = STATUS[r.status];
            return (
              <div key={String(r.id)} className="flex flex-wrap items-center gap-3 py-3">
                <Link href={`/loan/${r.id}`} className="font-mono text-teal hover:underline">#{String(r.id)}</Link>
                <Badge status={r.active || r.status ? status : "Not financed"} />
                <span className="text-sm">Face {fmt(r.face)}</span>
                <span className="text-xs text-muted">due {dateTime(r.due)}</span>
                {r.active && <span className="text-sm">Owed {fmt(r.debt)}</span>}
                <div className="ml-auto flex gap-2">
                  {!r.active && !r.locked && r.status === 0 && <Btn onClick={() => advance(r.id)} disabled={busy}>Advance 80%</Btn>}
                  {r.active && r.status >= 1 && r.status <= 3 && <Btn variant="ghost" onClick={() => repay(r.id, r.debt)} disabled={busy}>Repay {fmt(r.debt)}</Btn>}
                  <Link href={`/loan/${r.id}`} className="rounded-lg border border-line px-3 py-2 text-sm hover:border-teal">Details</Link>
                </div>
              </div>
            );
          })}
        </div>
      </Card>
      <TxStatus state={state} />
    </div>
  );
}
