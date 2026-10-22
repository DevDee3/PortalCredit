import { cookieStorage, createStorage } from "wagmi";
import { WagmiAdapter } from "@reown/appkit-adapter-wagmi";
import { chain } from "./config";

// Free project id from https://cloud.reown.com (WalletConnect Cloud). Required for the wallet list and mobile deep links.
export const projectId = process.env.NEXT_PUBLIC_REOWN_PROJECT_ID ?? "";

export const wagmiAdapter = new WagmiAdapter({
  projectId: projectId || "missing-project-id",
  networks: [chain],
  ssr: true,
  storage: createStorage({ storage: cookieStorage }),
});

export const wagmiConfig = wagmiAdapter.wagmiConfig;
