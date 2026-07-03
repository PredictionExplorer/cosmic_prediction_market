import { Suspense } from "react";
import { Header } from "@/components/layout/header";
import { MarketSkeleton } from "@/components/market/empty-states";
import { MarketGate } from "@/components/market/market-gate";

export default function Home() {
  return (
    <>
      <Header />
      <main className="mx-auto w-full max-w-6xl flex-1 px-4 py-8 sm:px-6">
        <Suspense fallback={<MarketSkeleton />}>
          <MarketGate />
        </Suspense>
      </main>
    </>
  );
}
