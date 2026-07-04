import type { Metadata } from "next";
import { appConfig } from "@/lib/config";
import { FaqContent } from "@/components/faq/faq-content";
import { Footer } from "@/components/layout/footer";
import { Header } from "@/components/layout/header";

export const metadata: Metadata = {
  title: "FAQ — Gesture Market",
  description:
    "How Gesture Market works: placing YES/NO bets on Cosmic Signature rounds, how odds and fees form, round resolution, liquidity provision, and the safety model.",
};

export default function FaqPage() {
  return (
    <>
      <Header />
      <main className="mx-auto w-full max-w-6xl flex-1 px-4 py-8 sm:px-6">
        <FaqContent />
        <Footer marketAddress={appConfig.marketAddress} cstAddress={null} />
      </main>
    </>
  );
}
