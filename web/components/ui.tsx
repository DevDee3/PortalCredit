"use client";

import { useEffect, useState } from "react";
import Link from "next/link";
import { useAppKit } from "@reown/appkit/react";
import { txUrl } from "@/lib/config";
import type { TxState } from "@/lib/hooks";

export function Card({ title, children, className = "" }: { title?: string; children: React.ReactNode; className?: string }) {
  return (
    <section className={`rounded-xl border border-line bg-panel p-5 ${className}`}>
      {title && <h2 className="mb-3 text-sm font-semibold uppercase tracking-wide text-muted">{title}</h2>}
      {children}
    </section>
  );
}

export function Stat({ label, value, hint }: { label: string; value?: string; hint?: string }) {
  return (
    <div className="rounded-xl border border-line bg-panel p-4">
      <div className="text-xs uppercase tracking-wide text-muted">{label}</div>
      {value === undefined ? (
        <div className="mt-2 h-7 w-24 animate-pulse rounded bg-panel2" />
      ) : (
        <div className="mt-1 text-xl font-semibold sm:text-2xl">{value}</div>
      )}
      {hint && <div className="mt-1 text-xs text-muted">{hint}</div>}
    </div>
  );
}

export function Btn({
  children,
  onClick,
  disabled,
  variant = "primary",
}: {
  children: React.ReactNode;
  onClick?: () => void;
  disabled?: boolean;
  variant?: "primary" | "ghost" | "danger";
}) {
  const style =
    variant === "primary"
      ? "bg-gradient-to-r from-teal to-violet text-bg font-semibold"
      : variant === "danger"
        ? "bg-danger/90 text-bg font-semibold"
        : "border border-line text-fg hover:border-teal";
  return (
    <button
      onClick={onClick}
      disabled={disabled}
      className={`rounded-lg px-4 py-2 text-sm transition disabled:cursor-not-allowed disabled:opacity-40 ${style}`}
    >
      {children}
    </button>
  );
}

const STATUS_COLOR: Record<string, string> = {
  Performing: "text-teal border-teal/40",
  Repaid: "text-teal border-teal/40",
  Recovered: "text-teal border-teal/40",
  Overdue: "text-gold border-gold/40",
  Disputed: "text-violet border-violet/40",
  Seized: "text-danger border-danger/40",
  Liquidated: "text-danger border-danger/40",
  "Written off": "text-muted border-line",
};
export function Badge({ status }: { status: string }) {
  return <span className={`rounded-full border px-2.5 py-0.5 text-xs font-medium ${STATUS_COLOR[status] ?? "text-muted border-line"}`}>{status}</span>;
}

export function TxStatus({ state }: { state: TxState }) {
  const [dismissed, setDismissed] = useState<string>("");
  const key = `${state.status}:${state.hash ?? ""}:${state.label ?? ""}`;
  useEffect(() => {
    if (state.status !== "done") return;
    const t = setTimeout(() => setDismissed(key), 8000);
    return () => clearTimeout(t);
  }, [state.status, key]);
  if (state.status === "idle" || dismissed === key) return null;
  const url = state.hash ? txUrl(state.hash) : undefined;
  const tone = state.status === "done" ? "border-teal/50" : state.status === "error" ? "border-danger/60" : "border-gold/50";
  return (
    <div role="status" className={`fixed inset-x-4 bottom-4 z-30 mx-auto max-w-md rounded-xl border ${tone} bg-panel2 p-4 text-sm shadow-xl`}>
      <div className="flex items-start gap-3">
        <div className="flex-1">
          {state.status === "pending" && (
            <p className="text-gold">
              <span className="mr-2 inline-block h-2 w-2 animate-pulse rounded-full bg-gold" />
              {state.label}: {state.hash ? "waiting for confirmation…" : "confirm in your wallet…"}
            </p>
          )}
          {state.status === "done" && <p className="text-teal">{state.label} confirmed</p>}
          {state.status === "error" && <p className="text-danger">{state.label} failed. {state.error}</p>}
          {state.hash && (
            <p className="mt-1 font-mono text-xs text-muted">
              {url ? <a href={url} target="_blank" rel="noreferrer" className="underline">{state.hash.slice(0, 14)}…</a> : `${state.hash.slice(0, 14)}…`}
            </p>
          )}
        </div>
        {state.status !== "pending" && (
          <button aria-label="Dismiss" className="text-muted hover:text-fg" onClick={() => setDismissed(key)}>✕</button>
        )}
      </div>
    </div>
  );
}

export function ConnectHint() {
  const { open } = useAppKit();
  return (
    <div className="rounded-xl border border-dashed border-line p-6 text-center">
      <p className="mb-3 text-sm text-muted">Connect a wallet to continue.</p>
      <Btn onClick={() => open({ view: "Connect" })}>Connect wallet</Btn>
    </div>
  );
}

export function NotConfigured() {
  return (
    <Card title="Not configured">
      <p className="text-sm text-muted">
        Contract addresses are missing. Copy <code>.env.example</code> to <code>.env.local</code> and fill in the values from{" "}
        <code>contracts/deployments/&lt;chainid&gt;.json</code>.
      </p>
    </Card>
  );
}

export function BackLink() {
  return (
    <Link href="/borrow" className="text-sm text-muted hover:text-teal">
      ← Borrower dashboard
    </Link>
  );
}
