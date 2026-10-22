"use client";

import Link from "next/link";
import Image from "next/image";
import { useConnection, useSwitchChain } from "wagmi";
import { useAppKit } from "@reown/appkit/react";
import { useChain, useTx } from "@/lib/hooks";
import { ADDR, CHAIN_ID } from "@/lib/config";
import { stableAbi } from "@/lib/abis";
import { projectId } from "@/lib/wagmi";
import { Btn } from "./ui";
import { short } from "@/lib/format";

export function Header() {
  const { address, isConnected, chainId } = useConnection();
  const { open } = useAppKit();
  const { mutate: switchChain } = useSwitchChain();
  const { send, busy } = useTx();

  const claimed = useChain(["claimed", address], (c) => c.readContract({ address: ADDR.stable, abi: stableAbi, functionName: "claimed", args: [address!] }), !!address);

  return (
    <>
      {!projectId && (
        <div className="bg-gold/15 px-4 py-2 text-center text-xs text-gold">
          Set NEXT_PUBLIC_REOWN_PROJECT_ID (free at cloud.reown.com) to enable the wallet list.
        </div>
      )}
      <header className="sticky top-0 z-20 border-b border-line bg-bg/80 backdrop-blur">
        <div className="mx-auto flex max-w-5xl flex-wrap items-center gap-x-4 gap-y-2 px-4 py-3">
          <Link href="/" className="flex items-center gap-2 font-semibold">
            <Image src="/logo.svg" alt="" width={28} height={28} unoptimized />
            PortalCredit
          </Link>
          <nav className="flex gap-4 text-sm text-muted">
            <Link href="/" className="hover:text-teal">Vault</Link>
            <Link href="/borrow" className="hover:text-teal">Borrow</Link>
          </nav>
          <div className="ml-auto flex items-center gap-2">
            {isConnected && claimed.data === false && (
              <Btn variant="ghost" disabled={busy} onClick={() => send("Faucet", { address: ADDR.stable, abi: stableAbi, functionName: "faucet" })}>
                Get 10,000 pcUSD
              </Btn>
            )}
            {isConnected && chainId !== CHAIN_ID ? (
              <Btn variant="danger" onClick={() => switchChain({ chainId: CHAIN_ID })}>Switch network</Btn>
            ) : isConnected ? (
              <Btn variant="ghost" onClick={() => open({ view: "Account" })}>{short(address)}</Btn>
            ) : (
              <Btn onClick={() => open({ view: "Connect" })}>Connect wallet</Btn>
            )}
          </div>
        </div>
      </header>
    </>
  );
}
