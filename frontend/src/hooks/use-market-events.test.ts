import fc from "fast-check";
import { describe, expect, it } from "vitest";
import type { AbiEvent, Log } from "viem";
import { encodeAbiParameters, encodeEventTopics, getAddress } from "viem";
import { gestureSeriesMarketAbi } from "@/lib/abi/gesture-series-market";
import { decodeScan } from "./use-market-events";

const SERIES = "0x1111111111111111111111111111111111111111" as const;
const TX = ("0x" + "ab".repeat(32)) as `0x${string}`;
const BLOCK_HASH = ("0x" + "cd".repeat(32)) as `0x${string}`;

/** Encodes a REAL log for any market event, exactly as a node would emit it. */
function encodeLog(
  eventName: string,
  args: Record<string, unknown>,
  blockNumber = 100n,
  logIndex = 0,
): Log {
  const item = gestureSeriesMarketAbi.find(
    (entry): entry is Extract<(typeof gestureSeriesMarketAbi)[number], { type: "event" }> =>
      entry.type === "event" && entry.name === eventName,
  );
  if (!item) throw new Error(`no such event: ${eventName}`);
  const topics = encodeEventTopics({
    abi: [item as AbiEvent],
    eventName,
    args,
  } as Parameters<typeof encodeEventTopics>[0]);
  const nonIndexed = item.inputs.filter((input) => !input.indexed);
  const data = encodeAbiParameters(
    nonIndexed,
    nonIndexed.map((input) => args[input.name as string]),
  );
  return {
    address: SERIES,
    topics,
    data,
    blockNumber,
    logIndex,
    transactionHash: TX,
    transactionIndex: 0,
    blockHash: BLOCK_HASH,
    removed: false,
  } as Log;
}

const arbAddress = fc
  .bigInt({ min: 1n, max: (1n << 160n) - 1n })
  .map((n) => getAddress(`0x${n.toString(16).padStart(40, "0")}`));
const arbU256 = fc.bigInt({ min: 0n, max: 2n ** 200n }); // plenty of range, well-formed
const arbRound = fc.bigInt({ min: 0n, max: 10n ** 9n });
const arbBlock = fc.bigInt({ min: 1n, max: 10n ** 9n });
const arbLogIndex = fc.integer({ min: 0, max: 10_000 });

describe("decodeScan: the new lifecycle events", () => {
  it("decodes RoundInitialized (no threshold arg anymore)", () => {
    const { activity, poolEvents } = decodeScan([encodeLog("RoundInitialized", { roundId: 7n })], 7n);
    expect(activity).toHaveLength(1);
    expect(activity[0]).toMatchObject({ kind: "roundInitialized", user: null, amount: 0n, secondary: 0n });
    expect(poolEvents).toHaveLength(0);
  });

  it("decodes ThresholdLocked with the locked value", () => {
    const { activity } = decodeScan([encodeLog("ThresholdLocked", { roundId: 7n, threshold: 950n })], 7n);
    expect(activity).toHaveLength(1);
    expect(activity[0]).toMatchObject({ kind: "thresholdLocked", user: null, secondary: 950n });
  });

  it("filters both to their own round", () => {
    const logs = [
      encodeLog("RoundInitialized", { roundId: 8n }),
      encodeLog("ThresholdLocked", { roundId: 8n, threshold: 1n }),
    ];
    expect(decodeScan(logs, 7n).activity).toHaveLength(0);
  });
});

describe("decodeScan: fuzzed encode/decode round-trips", () => {
  it("property: Bet logs round-trip every field into activity and pool replay", () => {
    fc.assert(
      fc.property(
        arbRound,
        arbAddress,
        fc.boolean(),
        arbU256,
        arbU256,
        arbU256,
        arbBlock,
        arbLogIndex,
        (roundId, user, yes, cstIn, netIn, tokensOut, blockNumber, logIndex) => {
          const log = encodeLog("Bet", { roundId, user, yes, cstIn, netIn, tokensOut }, blockNumber, logIndex);
          const { activity, poolEvents } = decodeScan([log], roundId);

          expect(activity).toHaveLength(1);
          expect(activity[0]).toMatchObject({
            kind: "bet",
            user,
            side: yes ? "yes" : "no",
            amount: cstIn,
            secondary: tokensOut,
            blockNumber,
            logIndex,
            transactionHash: TX,
          });
          expect(poolEvents).toHaveLength(1);
          expect(poolEvents[0]).toMatchObject({ kind: "bet", cstIn, netIn, tokensOut });
        },
      ),
    );
  });

  it("property: LiquidityAdded logs round-trip, fee vote included", () => {
    const arbFee = fc.integer({ min: 0, max: 1_000 });
    fc.assert(
      fc.property(
        arbRound,
        arbAddress,
        arbU256,
        arbFee,
        arbU256,
        arbU256,
        arbU256,
        (roundId, provider, cstIn, declaredFeeBps, sharesOut, yesToPool, noToPool) => {
          const log = encodeLog("LiquidityAdded", {
            roundId,
            provider,
            cstIn,
            declaredFeeBps,
            sharesOut,
            yesToPool,
            noToPool,
          });
          const { activity, poolEvents } = decodeScan([log], roundId);
          expect(activity[0]).toMatchObject({ kind: "add", user: provider, feeBps: declaredFeeBps, amount: cstIn });
          expect(poolEvents[0]).toMatchObject({ kind: "add", declaredFeeBps, sharesOut, yesToPool, noToPool });
        },
      ),
    );
  });

  it("property: ThresholdLocked logs round-trip for any round and value", () => {
    fc.assert(
      fc.property(arbRound, arbU256, arbBlock, arbLogIndex, (roundId, threshold, blockNumber, logIndex) => {
        const log = encodeLog("ThresholdLocked", { roundId, threshold }, blockNumber, logIndex);
        const { activity } = decodeScan([log], roundId);
        expect(activity[0]).toMatchObject({ kind: "thresholdLocked", secondary: threshold, blockNumber, logIndex });
      }),
    );
  });

  it("property: logs for OTHER rounds are always dropped, never mixed in", () => {
    fc.assert(
      fc.property(arbRound, arbRound, arbU256, (roundId, otherRound, threshold) => {
        fc.pre(roundId !== otherRound);
        const logs = [
          encodeLog("ThresholdLocked", { roundId: otherRound, threshold }),
          encodeLog("RoundInitialized", { roundId: otherRound }),
          encodeLog("Resolved", { roundId: otherRound, finalCount: threshold, yesWon: true }),
        ];
        const { activity, poolEvents } = decodeScan(logs, roundId);
        expect(activity).toHaveLength(0);
        expect(poolEvents).toHaveLength(0);
      }),
    );
  });

  it("property: unrecognizable logs never crash the scan", () => {
    fc.assert(
      fc.property(fc.uint8Array({ minLength: 32, maxLength: 32 }), arbRound, (topicBytes, roundId) => {
        const junk = {
          address: SERIES,
          topics: [`0x${Buffer.from(topicBytes).toString("hex")}`],
          data: "0x",
          blockNumber: 1n,
          logIndex: 0,
          transactionHash: TX,
          transactionIndex: 0,
          blockHash: BLOCK_HASH,
          removed: false,
        } as Log;
        const { activity, poolEvents } = decodeScan([junk], roundId);
        expect(activity).toHaveLength(0);
        expect(poolEvents).toHaveLength(0);
      }),
    );
  });

  it("property: a mixed batch decodes each event to its own round, in place", () => {
    fc.assert(
      fc.property(arbRound, arbAddress, arbU256, (roundId, user, amount) => {
        const logs = [
          encodeLog("RoundInitialized", { roundId }, 1n, 0),
          encodeLog("SetsMinted", { roundId, user, amount }, 2n, 1),
          encodeLog("ThresholdLocked", { roundId, threshold: amount }, 3n, 2),
          encodeLog("SetsMinted", { roundId: roundId + 1n, user, amount }, 4n, 3), // foreign
          encodeLog("Claimed", { roundId, user, cstOut: amount }, 5n, 4),
        ];
        const { activity } = decodeScan(logs, roundId);
        const kinds = activity.map((event) => event.kind);
        expect(kinds).toEqual(
          amount > 0n
            ? ["roundInitialized", "mint", "thresholdLocked", "claimed"]
            : ["roundInitialized", "mint", "thresholdLocked"], // zero claims are dropped
        );
      }),
    );
  });
});
