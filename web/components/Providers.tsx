"use client";

import { useState } from "react";
import { WagmiProvider } from "wagmi";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { createAppKit } from "@reown/appkit/react";
import { chain } from "@/lib/config";
import { projectId, wagmiAdapter, wagmiConfig } from "@/lib/wagmi";

// Initialised once at module scope: powers the wallet modal (300+ wallets, desktop extensions, mobile deep links).
createAppKit({
  adapters: [wagmiAdapter],
  projectId: projectId || "missing-project-id",
  networks: [chain],
  defaultNetwork: chain,
  metadata: {
    name: "PortalCredit",
    description: "RWA credit vault with an on-chain default lifecycle, on Portaldot",
    url: typeof window !== "undefined" ? window.location.origin : "https://portalcredit.app",
    icons: ["/logo.svg"],
  },
  features: { analytics: false, email: false, socials: false },
  themeMode: "dark",
  themeVariables: { "--w3m-accent": "#2dd4bf", "--w3m-border-radius-master": "2px" },
});

export function Providers({ children }: { children: React.ReactNode }) {
  const [qc] = useState(() => new QueryClient({ defaultOptions: { queries: { refetchInterval: 6000, staleTime: 3000 } } }));
  return (
    <WagmiProvider config={wagmiConfig}>
      <QueryClientProvider client={qc}>{children}</QueryClientProvider>
    </WagmiProvider>
  );
}
