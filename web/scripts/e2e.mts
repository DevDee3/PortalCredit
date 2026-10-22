// End-to-end smoke test of the exact ABIs the frontend uses, against a local deployment.
// Usage: RPC_URL=... DEPLOYMENT=../contracts/deployments/31337.json node --experimental-strip-types scripts/e2e.mts
import { createPublicClient, createWalletClient, http, keccak256, toBytes, parseEther, type Address } from "viem";
import { generatePrivateKey, privateKeyToAccount } from "viem/accounts";
import { readFileSync } from "node:fs";
import { arbiterAbi, engineAbi, nftAbi, stableAbi, vaultAbi } from "../lib/abis.ts";

const rpc = process.env.RPC_URL ?? "http://127.0.0.1:8545";
const dep = JSON.parse(readFileSync(process.env.DEPLOYMENT ?? "../contracts/deployments/31337.json", "utf8"));
const A = { stable: dep.stable as Address, nft: dep.receivableNFT as Address, vault: dep.vault as Address, engine: dep.engine as Address, arbiter: dep.arbiter as Address };

const pub = createPublicClient({ transport: http(rpc) });
const raw = (method: string, params: unknown[]) => pub.request({ method, params } as never);
const mk = (pk: `0x${string}`) => createWalletClient({ account: privateKeyToAccount(pk), transport: http(rpc) });
const buyer = mk(generatePrivateKey());
const borrower = mk(generatePrivateKey());

async function tx(w: ReturnType<typeof mk>, address: Address, abi: any, functionName: string, args: unknown[] = []) {
  const hash = await w.writeContract({ address, abi, functionName, args, chain: null } as never);
  const r = await pub.waitForTransactionReceipt({ hash });
  if (r.status !== "success") throw new Error(`${functionName} reverted`);
  return hash;
}
const status = async (id: bigint) => Number(await pub.readContract({ address: A.engine, abi: engineAbi, functionName: "statusOf", args: [id] }));
const price = async () => Number(await pub.readContract({ address: A.vault, abi: vaultAbi, functionName: "sharePrice" })) / 1e6;
const warp = async (s: number) => { await raw("evm_increaseTime", [s]); await raw("evm_mine", []); };
const assert = (c: boolean, m: string) => { if (!c) throw new Error("ASSERT: " + m); console.log("ok  -", m); };

for (const w of [buyer, borrower]) await raw("anvil_setBalance", [w.account!.address, "0x" + parseEther("10").toString(16)]);
await tx(buyer, A.stable, stableAbi, "faucet");
await tx(borrower, A.stable, stableAbi, "faucet");

const newLoan = async (face: bigint) => {
  const now = BigInt((await pub.getBlock()).timestamp);
  await tx(borrower, A.nft, nftAbi, "mint", [face, now + 60n, keccak256(toBytes("Acme")), "ipfs://x"]);
  const id = await pub.readContract({ address: A.nft, abi: nftAbi, functionName: "nextId" });
  await tx(borrower, A.nft, nftAbi, "approve", [A.vault, id]);
  await tx(borrower, A.vault, vaultAbi, "advance", [id]);
  return id;
};

const p0 = await price();
// Happy path
const a = await newLoan(1_000_000_000n);
assert((await status(a)) === 1, "advance -> Performing");
const debt = await pub.readContract({ address: A.vault, abi: vaultAbi, functionName: "debtOf", args: [a] });
await tx(borrower, A.stable, stableAbi, "approve", [A.vault, debt]);
await tx(borrower, A.vault, vaultAbi, "repay", [a, debt]);
assert((await status(a)) === 8, "repay -> Repaid");
const p1 = await price();
assert(p1 > p0, `share price rises from fee (${p0} -> ${p1})`);

// Default path
const b = await newLoan(1_000_000_000n);
await warp(61 + 60);
await tx(buyer, A.engine, engineAbi, "flagOverdue", [b]);
assert((await status(b)) === 2, "flagOverdue -> Overdue");
await warp(125);
await tx(buyer, A.engine, engineAbi, "seize", [b]);
assert((await status(b)) === 4, "seize -> Seized");
const p2 = await price();
assert(p2 < p1, `share price drops at seizure (${p1} -> ${p2})`);
await warp(90);
const cur = await pub.readContract({ address: A.engine, abi: engineAbi, functionName: "currentPrice", args: [b] });
const max = (cur * 101n) / 100n;
await tx(buyer, A.stable, stableAbi, "approve", [A.vault, max]); // vault pulls the auction payment
await tx(buyer, A.engine, engineAbi, "liquidate", [b, max]);
const s = await status(b);
assert(s === 5 || s === 6, `liquidate -> ${s === 5 ? "Liquidated" : "Recovered"}`);
const tl = await pub.readContract({ address: A.engine, abi: engineAbi, functionName: "timeline", args: [b] });
assert(tl.length >= 4, `timeline has ${tl.length} checkpoints`);
console.log("final share price", await price());
void arbiterAbi;
console.log("E2E PASSED");
