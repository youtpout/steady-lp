import React, { useEffect } from "react";
import { createRoot } from "react-dom/client";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { ConnectButton, RainbowKitProvider, getDefaultConfig, lightTheme } from "@rainbow-me/rainbowkit";
import "@rainbow-me/rainbowkit/styles.css";
import { WagmiProvider, http } from "wagmi";
import { arbitrum, arbitrumSepolia, base, baseSepolia, mainnet, optimism, polygon, sepolia } from "wagmi/chains";
import { useAccount, useWalletClient } from "wagmi";

const projectId = import.meta.env.VITE_WALLETCONNECT_PROJECT_ID || "00000000000000000000000000000000";
const chains = [mainnet, optimism, polygon, base, arbitrum, sepolia, baseSepolia, arbitrumSepolia];

const config = getDefaultConfig({
  appName: "SteadyLP Console",
  projectId,
  chains,
  transports: Object.fromEntries(chains.map((chain) => [chain.id, http()])),
});

const queryClient = new QueryClient();

function WalletBridge({ onWalletChange }) {
  const { address, chainId, isConnected } = useAccount();
  const { data: walletClient } = useWalletClient();

  useEffect(() => {
    onWalletChange({ address, chainId, isConnected, walletClient });
  }, [address, chainId, isConnected, walletClient, onWalletChange]);

  return (
    <ConnectButton
      accountStatus={{ smallScreen: "avatar", largeScreen: "full" }}
      chainStatus={{ smallScreen: "icon", largeScreen: "full" }}
      showBalance={false}
    />
  );
}

export function bootstrapWallet(onWalletChange) {
  createRoot(document.getElementById("walletRoot")).render(
    <React.StrictMode>
      <WagmiProvider config={config}>
        <QueryClientProvider client={queryClient}>
          <RainbowKitProvider
            modalSize="compact"
            theme={lightTheme({
              accentColor: "#161713",
              accentColorForeground: "#c9ff46",
              borderRadius: "small",
            })}
          >
            <WalletBridge onWalletChange={onWalletChange} />
          </RainbowKitProvider>
        </QueryClientProvider>
      </WagmiProvider>
    </React.StrictMode>,
  );
}

export const walletConnectConfigured = Boolean(import.meta.env.VITE_WALLETCONNECT_PROJECT_ID);
