import { describe, expect, it } from "vitest";
import { BaseError, ContractFunctionRevertedError, UserRejectedRequestError } from "viem";
import { gestureSeriesMarketAbi } from "./abi/gesture-series-market";
import { describeTxError } from "./errors";

function revertError(errorName: string): BaseError {
  const cause = new ContractFunctionRevertedError({
    abi: gestureSeriesMarketAbi,
    functionName: "betYes",
    data: ("0x" +
      // 4-byte selector is irrelevant; construct via errorName instead.
      "") as `0x${string}`,
  });
  // ContractFunctionRevertedError only decodes errorName from real calldata;
  // emulate a decoded revert by patching the instance the way viem exposes it.
  Object.defineProperty(cause, "data", {
    value: { errorName, args: [], abiItem: { type: "error", name: errorName, inputs: [] } },
  });
  return new BaseError("execution reverted", { cause });
}

describe("describeTxError", () => {
  it("maps user rejection to a friendly message", () => {
    const err = new BaseError("denied", {
      cause: new UserRejectedRequestError(new Error("User rejected the request")),
    });
    expect(describeTxError(err)).toBe("Transaction cancelled in your wallet.");
  });

  it("maps every contract error name to a specific explanation", () => {
    expect(describeTxError(revertError("RoundNotActive"))).toMatch(/already over/i);
    expect(describeTxError(revertError("RoundNotInitialized"))).toMatch(/hasn't been opened/i);
    expect(describeTxError(revertError("OutcomeDecided"))).toMatch(/crossed the threshold/i);
    expect(describeTxError(revertError("NotResolvable"))).toMatch(/isn't known yet/i);
    expect(describeTxError(revertError("AlreadyResolved"))).toMatch(/already been resolved/i);
    expect(describeTxError(revertError("NotResolved"))).toMatch(/hasn't been resolved/i);
    expect(describeTxError(revertError("Slippage"))).toMatch(/slippage/i);
    expect(describeTxError(revertError("DeadlineExpired"))).toMatch(/expired/i);
    expect(describeTxError(revertError("InsufficientLiquidity"))).toMatch(/liquidity/i);
    expect(describeTxError(revertError("InsufficientShares"))).toMatch(/shares|paired/i);
    expect(describeTxError(revertError("TransferFailed"))).toMatch(/transfer failed/i);
    expect(describeTxError(revertError("ReentrantCall"))).toMatch(/reentrancy/i);
  });

  it("falls back to the revert name for unknown custom errors", () => {
    expect(describeTxError(revertError("SomethingWeird"))).toMatch(/SomethingWeird/);
  });

  it("detects error names embedded in plain messages", () => {
    const err = new BaseError('The contract function "betYes" reverted with: OutcomeDecided');
    expect(describeTxError(err)).toMatch(/crossed the threshold/i);
  });

  it("explains insufficient gas funds", () => {
    const err = new BaseError("insufficient funds for gas * price + value");
    expect(describeTxError(err)).toMatch(/ETH to pay for gas/);
  });

  it("handles plain Errors and non-errors", () => {
    expect(describeTxError(new Error("boom"))).toBe("boom");
    expect(describeTxError(new Error("User rejected the request."))).toBe("Transaction cancelled in your wallet.");
    expect(describeTxError("weird")).toMatch(/something went wrong/i);
    expect(describeTxError(undefined)).toMatch(/something went wrong/i);
  });
});
