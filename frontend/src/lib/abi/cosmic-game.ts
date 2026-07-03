/** ABI of `src/ICosmicSignatureGame.sol` — the three getters the market reads. */
export const cosmicGameAbi = [
  {
    type: "function",
    name: "bidderAddresses",
    inputs: [{ name: "roundNum", type: "uint256", internalType: "uint256" }],
    outputs: [{ name: "numItems", type: "uint256", internalType: "uint256" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "roundNum",
    inputs: [],
    outputs: [{ name: "", type: "uint256", internalType: "uint256" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "token",
    inputs: [],
    outputs: [{ name: "", type: "address", internalType: "address" }],
    stateMutability: "view",
  },
] as const;
