import { formatUnits, parseUnits } from "viem";
import { STABLE_DECIMALS } from "./config";

export const fmt = (v: bigint | undefined, dp = 2) => {
  if (v === undefined) return "-";
  const n = Number(formatUnits(v, STABLE_DECIMALS));
  return n.toLocaleString(undefined, { minimumFractionDigits: dp, maximumFractionDigits: dp });
};

export const parseStable = (s: string): bigint | undefined => {
  try {
    if (!s || Number(s) <= 0) return undefined;
    return parseUnits(s as `${number}`, STABLE_DECIMALS);
  } catch {
    return undefined;
  }
};

export const short = (a?: string) => (a ? `${a.slice(0, 6)}…${a.slice(-4)}` : "-");

export const dateTime = (ts: bigint | number) =>
  new Date(Number(ts) * 1000).toLocaleString(undefined, { dateStyle: "medium", timeStyle: "short" });

export function countdown(seconds: number) {
  if (seconds <= 0) return "now";
  const d = Math.floor(seconds / 86400);
  const h = Math.floor((seconds % 86400) / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  const s = seconds % 60;
  if (d > 0) return `${d}d ${h}h`;
  if (h > 0) return `${h}h ${m}m`;
  if (m > 0) return `${m}m ${s}s`;
  return `${s}s`;
}
