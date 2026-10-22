"use client";

import { use, useEffect, useState } from "react";
import { keccak256, toBytes, zeroHash } from "viem";
import { ADDR, CONFIGURED, STATUS } from "@/lib/config";
import { arbiterAbi, engineAbi, nftAbi, stableAbi, vaultAbi } from "@/lib/abis";
import { useChain, useMe, useTx } from "@/lib/hooks";
import { countdown, dateTime, fmt, parseStable, short } from "@/lib/format";
import { BackLink, Badge, Btn, Card, NotConfigured, Stat, TxStatus } from "@/components/ui";

export default function LoanPage({ params }: { params: Promise<{ id: string }> }) {
  const { id: idStr } = use(params);
  const id = BigInt(idStr);
  const { address, isConnected } = useMe();
  const { send, state, busy } = useTx();
  const [now, setNow] = useState(() => Math.floor(Date.now() / 1000));
  const [evidence, setEvidence] = useState("Invoice paid on time, see bank ref");
  const [recoverAmt, setRecoverAmt] = useState("");
  const [newDue, setNewDue] = useState("10");

  useEffect(() => {
    const t = setInterval(() => setNow(Math.floor(Date.now() / 1000)), 1000);
    return () => clearInterval(t);
  }, []);

  const q = useChain(["loan", idStr], async (c) => {
    const [rec, loan, cs, debt, tl, grace, bond, arbOwner, owner] = await Promise.all([
      c.readContract({ address: ADDR.nft, abi: nftAbi, functionName: "receivable", args: [id] }),
      c.readContract({ address: ADDR.vault, abi: vaultAbi, functionName: "loans", args: [id] }),
      c.readContract({ address: ADDR.engine, abi: engineAbi, functionName: "cases", args: [id] }),
      c.readContract({ address: ADDR.vault, abi: vaultAbi, functionName: "debtOf", args: [id] }),
      c.readContract({ address: ADDR.engine, abi: engineAbi, functionName: "timeline", args: [id] }),
      c.readContract({ address: ADDR.engine, abi: engineAbi, functionName: "gracePeriod" }),
      c.readContract({ address: ADDR.engine, abi: engineAbi, functionName: "disputeBond" }),
      c.readContract({ address: ADDR.arbiter, abi: arbiterAbi, functionName: "owner" }),
      c.readContract({ address: ADDR.engine, abi: engineAbi, functionName: "owner" }),
    ]);
    const status = Number(cs[0]);
    let price = 0n;
    if (status === 4) price = await c.readContract({ address: ADDR.engine, abi: engineAbi, functionName: "currentPrice", args: [id] });
    const [allowEngine, allowVault] = await Promise.all([
      address ? c.readContract({ address: ADDR.stable, abi: stableAbi, functionName: "allowance", args: [address, ADDR.engine] }) : Promise.resolve(0n),
      address ? c.readContract({ address: ADDR.stable, abi: stableAbi, functionName: "allowance", args: [address, ADDR.vault] }) : Promise.resolve(0n),
    ]);
    return { rec, loan, cs, debt, tl, grace, bond, arbOwner, owner, status, price, allowEngine, allowVault };
  }, CONFIGURED);

  if (!CONFIGURED) return <NotConfigured />;
  const d = q.data;
  if (!d) return <div className="text-muted">Loading loan #{idStr}…</div>;

  const status = STATUS[d.status];
  const due = Number(d.rec.dueDate);
  const me = address?.toLowerCase();
  const isBorrower = me === d.loan[0].toLowerCase();
  const isArbiter = me === d.arbOwner.toLowerCase();
  const isOwner = me === d.owner.toLowerCase();
  const disputeDeadline = Number(d.cs[2]);
  const seizedAt = Number(d.cs[4]);

  // The dispute bond is pulled by the engine; auction and recovery payments are pulled by the vault.
  async function withApproval(label: string, amount: bigint, then: () => Promise<unknown>, spender: "engine" | "vault" = "vault") {
    const allowance = spender === "engine" ? d!.allowEngine : d!.allowVault;
    if (allowance < amount) {
      if (!(await send(`Approve (${label})`, { address: ADDR.stable, abi: stableAbi, functionName: "approve", args: [ADDR[spender], amount] }))) return;
    }
    await then();
  }
  const call = (label: string, fn: string, args: unknown[]) => () =>
    send(label, { address: ADDR.engine, abi: engineAbi, functionName: fn, args });

  let hint = "";
  if (d.status === 1) hint = now < due + Number(d.grace) ? `Can be flagged overdue in ${countdown(due + Number(d.grace) - now)}` : "Grace period over: anyone can flag it overdue.";
  if (d.status === 2) hint = now < disputeDeadline ? `Dispute window closes in ${countdown(disputeDeadline - now)} (seizure opens after)` : "Dispute window closed: anyone can seize the collateral.";
  if (d.status === 4) hint = "Dutch auction live: the price decays toward the floor. Buyer pays the current price and receives the receivable NFT.";

  return (
    <div className="space-y-6">
      <BackLink />
      <div className="flex flex-wrap items-center gap-3">
        <h1 className="text-3xl font-semibold">Receivable #{idStr}</h1>
        <Badge status={status} />
      </div>
      {hint && <p className="text-sm text-gold">{hint}</p>}

      <div className="grid grid-cols-2 gap-3 md:grid-cols-4">
        <Stat label="Face value" value={fmt(d.rec.faceValue)} />
        <Stat label="Principal" value={fmt(d.loan[4])} />
        <Stat label="Owed now" value={fmt(d.debt)} hint="principal + fee" />
        <Stat label="Due" value={dateTime(d.rec.dueDate)} hint={countdown(due - now) === "now" ? "past due" : `in ${countdown(due - now)}`} />
      </div>

      {d.status === 4 && (
        <Card title="Liquidation auction">
          <div className="text-2xl font-semibold text-gold">{fmt(d.price)} pcUSD</div>
          <p className="mt-1 text-xs text-muted">Current price. Impairment booked against LPs: {fmt(d.loan[6])}.</p>
          <div className="mt-3">
            <Btn
              disabled={!isConnected || busy}
              onClick={() => {
                const max = (d.price * 101n) / 100n;
                return withApproval("auction", max, call("Liquidate", "liquidate", [id, max]));
              }}
            >
              Buy collateral at current price
            </Btn>
          </div>
        </Card>
      )}

      <Card title="Actions">
        <div className="flex flex-wrap items-center gap-2">
          {d.status === 1 && <Btn disabled={busy || now < due + Number(d.grace)} onClick={call("Flag overdue", "flagOverdue", [id])}>Flag overdue</Btn>}
          {d.status === 2 && <Btn variant="danger" disabled={busy || now < disputeDeadline} onClick={call("Seize", "seize", [id])}>Seize collateral</Btn>}
          {d.status === 3 && <Btn variant="ghost" disabled={busy} onClick={call("Expire dispute", "expireDispute", [id])}>Expire dispute (if resolver silent)</Btn>}
          {d.status === 5 && (
            <>
              <input className="max-w-40" placeholder="Amount" value={recoverAmt} onChange={(e) => setRecoverAmt(e.target.value)} />
              <Btn
                disabled={busy || !parseStable(recoverAmt)}
                onClick={() => withApproval("recover", parseStable(recoverAmt)!, call("Recover", "recover", [id, parseStable(recoverAmt)!]))}
              >
                Pay late recovery (shortfall {fmt(d.cs[8])})
              </Btn>
              <Btn variant="ghost" disabled={busy} onClick={call("Write off", "writeOff", [id])}>Write off</Btn>
            </>
          )}
        </div>
        {d.status === 2 && isBorrower && now < disputeDeadline && (
          <div className="mt-4 flex flex-wrap items-center gap-2">
            <input className="max-w-sm" value={evidence} onChange={(e) => setEvidence(e.target.value)} />
            <Btn
              variant="ghost"
              disabled={busy}
              onClick={() => withApproval("dispute bond", d.bond, call("Dispute", "dispute", [id, keccak256(toBytes(evidence))]), "engine")}
            >
              Dispute{d.bond > 0n ? ` (bond ${fmt(d.bond)})` : ""}
            </Btn>
          </div>
        )}
        {[1, 2, 3, 4, 5, 6, 7, 8].every((s) => s !== d.status) && <p className="text-sm text-muted">No action available in this state.</p>}
        {isOwner && d.status === 5 && <p className="mt-2 text-xs text-muted">You are the owner: write-off is available before the recovery period.</p>}
      </Card>

      {d.status === 3 && isArbiter && (
        <Card title="Arbiter ruling">
          <p className="mb-3 text-xs text-muted">You control the reference resolver. Upholding returns the loan to Performing with a new due date; rejecting forfeits the borrower&apos;s bond to LPs.</p>
          <div className="flex flex-wrap items-center gap-2">
            <input className="max-w-40" value={newDue} onChange={(e) => setNewDue(e.target.value)} placeholder="new due (min)" />
            <Btn
              disabled={busy}
              onClick={() =>
                send("Uphold dispute", {
                  address: ADDR.arbiter, abi: arbiterAbi, functionName: "resolve",
                  args: [id, true, BigInt(now + Math.max(1, Number(newDue)) * 60)],
                })
              }
            >
              Uphold
            </Btn>
            <Btn variant="danger" disabled={busy} onClick={() => send("Reject dispute", { address: ADDR.arbiter, abi: arbiterAbi, functionName: "resolve", args: [id, false, 0n] })}>
              Reject
            </Btn>
          </div>
        </Card>
      )}

      <Card title="Default timeline">
        {d.tl.length === 0 ? (
          <p className="text-sm text-muted">No events yet.</p>
        ) : (
          <ol className="space-y-3 border-l border-line pl-4">
            {d.tl.map((t, i) => (
              <li key={i} className="relative">
                <span className="absolute -left-[21px] top-1.5 h-2.5 w-2.5 rounded-full bg-gradient-to-r from-teal to-violet" />
                <div className="flex items-center gap-2">
                  <Badge status={STATUS[Number(t.status)]} />
                  <span className="text-xs text-muted">{dateTime(t.timestamp)}</span>
                  {t.ref !== zeroHash && <span className="font-mono text-xs text-muted">ref {short(t.ref)}</span>}
                </div>
              </li>
            ))}
          </ol>
        )}
        {seizedAt > 0 && <p className="mt-3 text-xs text-muted">Seized {dateTime(seizedAt)}</p>}
      </Card>
      <TxStatus state={state} />
    </div>
  );
}
