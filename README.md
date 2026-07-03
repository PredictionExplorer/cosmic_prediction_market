# Gesture Market

A minimal scalar prediction market on **how many gestures (bids) the current
[Cosmic Signature](https://cosmicsignature.com) round will end with**, denominated
in CST and resolved trustlessly from the Cosmic Signature game contract on
Arbitrum One.

The whole market is one dependency-free contract:
[`src/GestureMarket.sol`](src/GestureMarket.sol) (~150 lines of logic).

## How it works

Instead of a yes/no question like "will there be more than 800 bids?", the market
prices the number itself using two complementary outcome tokens over a range
`[minCount, maxCount]`:

- **1 CST mints 1 HIGHER + 1 LOWER** (a "complete set"), and a complete set is
  always worth exactly 1 CST at resolution. The contract is therefore fully
  collateralized at all times.
- HIGHER and LOWER trade against each other in a **Uniswap-style constant-product
  pool** (`x * y = k`). The pool's marginal price of HIGHER, mapped over the
  range, is the market's live consensus prediction:

  ```
  predictedCount = minCount + (maxCount - minCount) * reserveLower / (reserveHigher + reserveLower)
  ```

- **Betting**: `betHigher(cstIn, minTokensOut)` takes your CST, mints sets, and
  swaps the LOWER half into the pool so you hold only HIGHER (`betLower` is the
  mirror image). Buying HIGHER pushes the predicted count up; buying LOWER pushes
  it down. Your effective entry price is the prediction you traded at.
- **Resolution**: a round ends when its main prize is claimed, which increments
  the game's `roundNum`. From that moment anyone can call `resolve()`, which
  reads the round's final gesture count from the game contract, clamps it into
  the range, and fixes the payouts:

  ```
  f = (finalCount - minCount) / (maxCount - minCount)   // clamped to [0, 1]
  1 HIGHER pays f CST,  1 LOWER pays (1 - f) CST
  ```

  So if you bought HIGHER while the market predicted 700 and the round finishes
  at 1,000, each of your HIGHER tokens is worth more CST than you paid for it —
  payouts scale linearly with how far the count lands from your entry.
- **Claiming**: after resolution, `claim()` pays out all your tokens at the fixed
  rates.
- **Exiting early**: buy the opposite side, then `redeemSets` matched
  HIGHER/LOWER pairs back into CST at any time while the round is live.
- **Liquidity**: the deployer is the sole LP. The pool opens with equal reserves
  (prediction = range midpoint); at resolution the pool's leftover tokens plus
  all trading fees (`feeBps` per bet) go back to the deployer. No LP shares, no
  add/remove liquidity.

Trading halts automatically the instant the round ends, because every trading
function requires `game.roundNum()` to still equal the market's round — there is
no window to bet on an already-known outcome before `resolve()` is called.

## Cosmic Signature integration

The market reads three getters from the game proxy
([`src/ICosmicSignatureGame.sol`](src/ICosmicSignatureGame.sol)):

| Getter | Used for |
|---|---|
| `roundNum()` | market's round at deploy; round-over detection (`> round`) |
| `bidderAddresses(round)` | the round's total gesture count (`numItems`) |
| `token()` | the CST token address |

Arbitrum One addresses:

- Game proxy: `0x6a714Ae7B5b6eA520F6BCA23d2E609C4Fd5863F2`
- CST token: `0xAD91843e6A58Ba560F577E676986AFb1dba6FBA0`

## Development and testing

Requires [Foundry](https://getfoundry.sh).

```bash
forge build
forge test                                   # full suite: unit + fuzz + invariant
FOUNDRY_PROFILE=heavy forge test             # long fuzzing campaign (50k fuzz runs,
                                             # 512x256 invariant campaigns)
ARBITRUM_RPC_URL=https://arb1.arbitrum.io/rpc \
  forge test --match-contract ForkTest -vv   # optional: validate against the live game
```

The test suite is organized in four layers:

- [`test/GestureMarket.t.sol`](test/GestureMarket.t.sol) — unit tests for every
  function: happy paths, guards, boundary counts, idempotent claims.
- [`test/GestureMarketFuzz.t.sol`](test/GestureMarketFuzz.t.sol) — property-based
  fuzz tests. Each states an economic/safety property that must hold for all
  inputs: the pool can never be drained or lose value (`x*y=k` monotone), quotes
  always equal executed bets, the AMM is path-independent (splitting a bet gains
  nothing), no CST can be extracted pre-resolution beyond what was deposited,
  payouts are convex combinations of token balances, fees accrue to the wei, and
  the full lifecycle conserves CST for any fee, actors, and final count.
- [`test/GestureMarketInvariant.t.sol`](test/GestureMarketInvariant.t.sol) —
  stateful invariant testing. A handler drives random interleavings of the whole
  lifecycle (bets, sets, round end, resolve, claims) with `fail_on_revert`
  enabled, re-checking after every call that the market is exactly
  collateralized, solvent for all remaining claims, in-range, and coherent; after
  every campaign the market is force-drained to prove everyone can always be paid
  with at most a few wei of rounding dust left.
- [`test/GestureMarketHardening.t.sol`](test/GestureMarketHardening.t.sol) —
  adversarial tests: reentrancy attacks on `claim`/`redeemSets` via a malicious
  callback token, false-returning ERC20s, unsolicited CST donations, degenerate
  ranges (binary and widest-allowed), parallel markets, and post-resolution
  trading attempts.

Fuzzing intensity is configured per profile in [`foundry.toml`](foundry.toml);
crank the `heavy` numbers up arbitrarily for overnight runs.

## Deployment

One market per round; deploy while the round you want to bet on is live. The
deployer wallet needs `INITIAL_LIQUIDITY` CST (the script pre-approves the
market's predicted address, since the constructor pulls the liquidity).

```bash
MIN_COUNT=0 MAX_COUNT=2000 FEE_BPS=100 INITIAL_LIQUIDITY=1000000000000000000000 \
forge script script/Deploy.s.sol \
  --rpc-url $ARBITRUM_RPC_URL --private-key $PRIVATE_KEY --broadcast
```

Pick `MIN_COUNT`/`MAX_COUNT` generously around your expectation; final counts
outside the range simply pay out as if they landed on the nearest bound.

## Design notes and trade-offs

- **Live information is priced in, by design.** The current gesture count is
  public while the round runs, so the prediction should always sit at or above
  it — like a live over/under line. Late informed trading costs the LP money;
  the per-bet fee is the compensation. Size liquidity accordingly.
- **Outcome manipulation is possible but costly.** Someone holding HIGHER could
  place extra gestures to raise the count. Each gesture costs ETH/CST, so keeping
  pool liquidity modest keeps manipulation unprofitable.
- **The game is an owner-upgradeable proxy.** The market trusts its `roundNum`
  and `bidderAddresses` getters.
- **Rounding always favors the pool/contract** (swap outputs round down against
  the trader, claims round down), so the contract can never owe more CST than it
  holds; at most a few wei of dust are left behind.
