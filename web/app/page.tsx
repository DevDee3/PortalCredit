"use client";

import { useState } from "react";
import { formatUnits } from "viem";
import { ADDR, CONFIGURED } from "@/lib/config";
import { stableAbi, vaultAbi } from "@/lib/abis";
import { useChain, useMe, useTx } from "@/lib/hooks";
import { fmt, parseStable } from "@/lib/format";
import { Btn, Card, ConnectHint, NotConfigured, Stat, TxStatus } from "@/components/ui";

export default function VaultPage() {
  const { address, isConnected } = useMe();
  const { send, state, busy } = useTx();
  const [dep, setDep] = useState("");
  const [wd, setWd] = useState("");

  const vault = useChain(["vault"], async (c) => {
    const r = (f: string) => c.readContract({ address: ADDR.vault, abi: vaultAbi, functionName: f as never }) as Promise<bigint>;
    const [totalAssets, outstanding, impairment, idle, util, price] = await Promise.all([
      r("totalAssets"), r("outstandingPrincipal"), r("totalImpairment"), r("idleCash"), r("utilizationBps"), r("sharePrice"),
    ]);
    return { totalAssets, outstanding, impairment, idle, util, price };
  }, CONFIGURED);

  const me = useChain(["me", address], async (c) => {
    const [shares, maxW, bal, allowance] = await Promise.all([
      c.readContract({ address: ADDR.vault, abi: vaultAbi, functionName: "balanceOf", args: [address!] }),
      c.readContract({ address: ADDR.vault, abi: vaultAbi, functionName: "maxWithdraw", args: [address!] }),
      c.readContract({ address: ADDR.stable, abi: stableAbi, functionName: "balanceOf", args: [address!] }),
      c.readContract({ address: ADDR.stable, abi: stableAbi, functionName: "allowance", args: [address!, ADDR.vault] }),
    ]);
    const value = await c.readContract({ address: ADDR.vault, abi: vaultAbi, functionName: "convertToAssets", args: [shares] });
    return { shares, maxW, bal, allowance, value };
  }, CONFIGURED && !!address);

  if (!CONFIGURED) return <NotConfigured />;
  const v = vault.data;
  const depAmt = parseStable(dep);
  const wdAmt = parseStable(wd);

  async function deposit() {
    if (!depAmt || !address) return;
    if ((me.data?.allowance ?? 0n) < depAmt) {
      const ok = await send("Approve", { address: ADDR.stable, abi: stableAbi, functionName: "approve", args: [ADDR.vault, depAmt] });
      if (!ok) return;
    }
    if (await send("Deposit", { address: ADDR.vault, abi: vaultAbi, functionName: "deposit", args: [depAmt, address] })) setDep("");
  }
  async function withdraw() {
    if (!wdAmt || !address) return;
    if (await send("Withdraw", { address: ADDR.vault, abi: vaultAbi, functionName: "withdraw", args: [wdAmt, address, address] })) setWd("");
  }

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-3xl font-semibold">Fund receivables. Defaults handled on-chain.</h1>
        <p className="mt-2 max-w-2xl text-muted">
          Liquidity providers earn origination fees on invoice financing. If a borrower defaults, a transparent state machine
          runs dispute, seizure, Dutch-auction liquidation and loss allocation, and the share price reflects it immediately.
        </p>
      </div>

      <div className="grid grid-cols-2 gap-3 md:grid-cols-4">
        <Stat label="Total assets" value={v && `${fmt(v.totalAssets)} pcUSD`} />
        <Stat label="Share price" value={v && (Number(v.price) / 1e6).toFixed(4)} hint="assets per share" />
        <Stat label="Utilization" value={v && `${(Number(v.util) / 100).toFixed(1)}%`} hint={v && `${fmt(v.outstanding)} lent out`} />
        <Stat label="Impairment" value={v && `${fmt(v.impairment)} pcUSD`} hint="losses recognised at seizure" />
      </div>

      <div className="grid gap-3 sm:grid-cols-3">
        {[
          ["1", "Borrowers finance invoices", "Mint a receivable NFT and borrow 80% of its face value."],
          ["2", "LPs earn the fee", "Deposit pcUSD, get vault shares, earn a 2% origination fee on repayment."],
          ["3", "Defaults resolve on-chain", "Dispute, seizure, auction and loss allocation, all permissionless."],
        ].map(([n, t, d]) => (
          <div key={n} className="rounded-xl border border-line bg-panel p-4">
            <div className="mb-1 flex h-6 w-6 items-center justify-center rounded-full bg-gradient-to-r from-teal to-violet text-xs font-bold text-bg">{n}</div>
            <div className="text-sm font-semibold">{t}</div>
            <p className="mt-1 text-xs text-muted">{d}</p>
          </div>
        ))}
      </div>

      {!isConnected && <ConnectHint />}

      <div className="grid gap-4 md:grid-cols-2">
        <Card title="Deposit">
          <p className="mb-2 text-xs text-muted">Wallet: {isConnected ? `${fmt(me.data?.bal)} pcUSD` : "connect to see your balance"}</p>
          <div className="flex gap-2">
            <input inputMode="decimal" placeholder="Amount in pcUSD" value={dep} onChange={(e) => setDep(e.target.value)} />
            <Btn variant="ghost" disabled={!me.data} onClick={() => me.data && setDep(formatUnits(me.data.bal, 6))}>Max</Btn>
          </div>
          <div className="mt-3"><Btn onClick={deposit} disabled={!isConnected || busy || !depAmt}>Deposit</Btn></div>
        </Card>
        <Card title="Withdraw">
          <p className="mb-2 text-xs text-muted">
            Your position: {fmt(me.data?.value)} pcUSD · withdrawable now: {fmt(me.data?.maxW)}
          </p>
          <div className="flex gap-2">
            <input inputMode="decimal" placeholder="Amount in pcUSD" value={wd} onChange={(e) => setWd(e.target.value)} />
            <Btn variant="ghost" disabled={!me.data} onClick={() => me.data && setWd(formatUnits(me.data.maxW, 6))}>Max</Btn>
          </div>
          <div className="mt-3"><Btn variant="ghost" onClick={withdraw} disabled={!isConnected || busy || !wdAmt}>Withdraw</Btn></div>
        </Card>
      </div>
      <TxStatus state={state} />
    </div>
  );
}
