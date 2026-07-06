"use client";

import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { LazyMotion } from "motion/react";
import { useState } from "react";
import { preconnect } from "react-dom";
import { Toaster } from "sonner";
import { WagmiProvider } from "wagmi";
import { appConfig } from "@/lib/config";
import { wagmiConfig } from "@/lib/wagmi";

// Motion's animation engine loads as its own async chunk; only the tiny
// <m /> renderer ships in the first load (LazyMotion `strict` enforces it).
const loadMotionFeatures = () => import("@/lib/motion-features").then((mod) => mod.default);

/** Origin of the RPC endpoint the app hits immediately on load, if valid. */
export function rpcOrigin(): string | null {
  const url = appConfig.rpcUrl ?? appConfig.chain.rpcUrls.default?.http[0];
  if (!url) return null;
  try {
    const origin = new URL(url).origin;
    return origin.startsWith("http") ? origin : null;
  } catch {
    return null;
  }
}

export function Providers({ children }: { children: React.ReactNode }) {
  const [queryClient] = useState(
    () =>
      new QueryClient({
        defaultOptions: {
          queries: {
            // On-chain reads: refresh often enough to feel live, without hammering the RPC.
            staleTime: 4_000,
            refetchOnWindowFocus: true,
            retry: 2,
          },
        },
      }),
  );

  // Warm up the RPC connection (DNS + TLS) before the first contract read.
  const origin = rpcOrigin();
  if (origin) preconnect(origin);

  return (
    <WagmiProvider config={wagmiConfig}>
      <QueryClientProvider client={queryClient}>
        <LazyMotion features={loadMotionFeatures} strict>
          {children}
        </LazyMotion>
        <Toaster
          position="bottom-right"
          theme="dark"
          toastOptions={{
            style: {
              background: "#181529",
              border: "1px solid rgba(167, 155, 220, 0.2)",
              color: "#f0edfa",
            },
          }}
        />
      </QueryClientProvider>
    </WagmiProvider>
  );
}
