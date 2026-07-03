import { BaseError, ContractFunctionRevertedError, UserRejectedRequestError } from "viem";

/** Human explanations for every custom error the market can revert with. */
const CONTRACT_ERRORS: Record<string, string> = {
  TradingClosed: "The round has ended — trading is closed. You can resolve the market and claim winnings.",
  NotResolvable: "The round is still live, so the market can't be resolved yet.",
  AlreadyResolved: "The market has already been resolved.",
  NotResolved: "The market hasn't been resolved yet — resolve it first, then claim.",
  Slippage: "Price moved beyond your slippage tolerance. Try again or raise the tolerance.",
  TransferFailed: "The CST token transfer failed. Check your balance and try again.",
  InvalidParams: "Invalid market parameters.",
};

/**
 * Maps any error thrown by a wallet/RPC interaction to a short, human-friendly
 * message. Never throws; always returns something presentable.
 */
export function describeTxError(error: unknown): string {
  if (error instanceof BaseError) {
    if (error.walk((e) => e instanceof UserRejectedRequestError)) {
      return "Transaction cancelled in your wallet.";
    }
    const revert = error.walk((e) => e instanceof ContractFunctionRevertedError);
    if (revert instanceof ContractFunctionRevertedError) {
      const name = revert.data?.errorName ?? revert.signature;
      if (name && CONTRACT_ERRORS[name]) return CONTRACT_ERRORS[name];
      if (name) return `Transaction reverted: ${name}`;
    }
    const short = error.shortMessage;
    if (/insufficient funds/i.test(short)) {
      return "Not enough ETH to pay for gas.";
    }
    // Some wallets surface revert names only in the message string.
    for (const [name, message] of Object.entries(CONTRACT_ERRORS)) {
      if (short.includes(name) || error.message.includes(name)) return message;
    }
    return short;
  }
  if (error instanceof Error) {
    if (/user rejected|user denied/i.test(error.message)) return "Transaction cancelled in your wallet.";
    return error.message;
  }
  return "Something went wrong. Please try again.";
}
