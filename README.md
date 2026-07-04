# Gesture Market

A perpetual series of binary prediction markets on one question, asked fresh
every [Cosmic Signature](https://cosmicsignature.com) round:

> **Will this round end with more gestures (bids) than the previous round?**

Denominated in CST, resolved trustlessly from the Cosmic Signature game
contract on Arbitrum One, with open multi-LP liquidity across **fee tiers the
LPs choose themselves** (Uniswap-style). The whole series — every round,
forever — is one dependency-free singleton contract with no owner, no admin
keys, and no upgradability:
[`src/GestureSeriesMarket.sol`](src/GestureSeriesMarket.sol).

A polished web app lives in [`frontend/`](frontend/README.md) (Next.js +
wagmi, deployable to Vercel): live YES-probability gauge and chart, the
count-vs-threshold race, one-click bets auto-routed to the best fee tier,
liquidity provision with per-tier fee earnings, and round navigation for
resolving and claiming past rounds.

## How it works

- **Markets launch themselves.** The first `addLiquidity` for the current
  round initializes that round's market, reading the threshold — the previous
  round's final gesture count, frozen the moment this round started — straight
  from the game. No per-round deployments, no keepers, no configuration.
- **Two outcome tokens per round.** 1 CST mints a complete set of
  1 YES + 1 NO (`mintSets`), and a complete set always redeems for 1 CST
  (`redeemSets`), so the contract is fully collateralized by construction.
  YES pays 1 CST iff the final count is **strictly** greater than the
  threshold (a tie means NO wins); NO pays 1 CST otherwise.
- **LPs choose their fee.** Liquidity lives in Uniswap-style constant-product
  pools (x·y=k) between YES and NO — one pool per fee tier (default deploy:
  1%, 2%, 5%). Anyone can provide liquidity into the tier whose fee they're
  willing to accept and earns that fee on every bet in their pool, pro rata by
  LP shares, claimable anytime (`claimFees`). A pool's implied probability is
  `reserveNo / (reserveYes + reserveNo)`.
  - The **first LP** of a pool opens it at their chosen YES probability (the
    seeding returns the surplus side to them as outcome tokens).
  - Later LPs join at the pool's current ratio; excess tokens are credited
    back. Rounding always favors incumbent LPs.
- **Betting** (`betYes`/`betNo`) mints sets with your CST and swaps the
  unwanted side into the pool, so you hold only your side. `betYesBest` /
  `betNoBest` route to whichever tier gives the best all-in execution —
  cross-tier prices stay aligned because buying both sides across tiers and
  redeeming pairs is a riskless arbitrage. To exit early, buy the opposite
  side and `redeemSets`.
- **Resolution** is permissionless. When the round ends (the game's round
  counter advances), `resolve(round)` compares the final count against the
  threshold. And because the gesture count is public and **only ever
  increases**, the instant it exceeds the threshold mid-round YES is already
  certain: betting and liquidity-adding halt atomically in that same block,
  and `resolve` fires early.
- **Claiming**: after resolution `claim(round)` pays winning tokens 1:1.
  LP positions are never confiscated or swept: `removeLiquidity` works at ANY
  time — live, decided, or after resolution — paying pro-rata reserves plus
  accrued fees.

## Battle hardening

Each mitigation below is enforced by the contract and proven by a scripted
attack in [`test/GestureSeriesMarketHardening.t.sol`](test/GestureSeriesMarketHardening.t.sol):

- **LP pulls liquidity right before your bet** (front-run): every bet carries
  a mandatory `minTokensOut` floor computed from the quote you saw — worse
  execution reverts instead of filling. Same-class guards exist everywhere:
  `minSharesOut` on adds, `minYesOut`/`minNoOut` on removes.
- **Sandwiches and stale transactions**: slippage floors cap the damage at
  exactly your tolerance, and every mutating call takes a `deadline`.
- **Betting on a decided outcome**: bets and adds check the live count
  against the threshold in the same call — there is no block in which
  certainty can be traded at stale prices. Round-over trading is blocked by
  the round counter.
- **First-depositor share inflation** (the ERC4626/Uniswap classic): minimum
  first deposit (0.001 CST), 1000 dead shares locked forever on every pool's
  first mint, zero-share mints revert, and all share math rounds against the
  depositor. The scripted attack recovers dust, not capital.
- **JIT fee sniping**: a just-in-time LP inherits zero pre-join fees, skims at
  most its pro-rata slice of the single sniped bet, and exits holding
  inventory risk rather than free cash (bounded in tests; Arbitrum's FCFS
  ordering makes the game pointless in practice anyway).
- **Donations**: reserves and balances are internal accounting — direct CST
  transfers move no price, no share value, no payout.
- **Reentrancy**: a contract-wide guard plus strict checks-effects-interactions
  on every path (exercised with a malicious callback token).
- **Fee/solvency accounting**: bet fees live in an explicit per-pool escrow
  (`feeReserve`) with a MasterChef-style accumulator, so the invariant
  *contract CST = outstanding sets + fee escrows* holds **exactly, to the
  wei** — re-checked after every call of every invariant campaign.
- **No trust surface**: no owner, no pause, no upgrade path; rounding always
  favors the contract, so it can never owe more than it holds.

## Cosmic Signature integration

The market reads three getters from the game proxy
([`src/ICosmicSignatureGame.sol`](src/ICosmicSignatureGame.sol)):

| Getter | Used for |
|---|---|
| `roundNum()` | round liveness/rollover; init + resolution gating |
| `bidderAddresses(round)` | gesture counts: threshold (round−1) and outcome (round) |
| `token()` | the CST token address |

Arbitrum One addresses:

- Game proxy: `0x6a714Ae7B5b6eA520F6BCA23d2E609C4Fd5863F2`
- CST token: `0xAD91843e6A58Ba560F577E676986AFb1dba6FBA0`

## Development and testing

Requires [Foundry](https://getfoundry.sh).

```bash
forge build
forge test                                   # full suite: unit + fuzz + invariant + attacks
FOUNDRY_PROFILE=heavy forge test             # long fuzzing campaign (50k fuzz runs,
                                             # 512x256 invariant campaigns)
ARBITRUM_RPC_URL=https://arb1.arbitrum.io/rpc \
  forge test --match-contract ForkTest -vv   # optional: validate against the live game
```

The test suite is organized in four layers plus a differential bridge to the
frontend:

- [`test/GestureSeriesMarket.t.sol`](test/GestureSeriesMarket.t.sol) — unit
  tests for every function: lazy initialization, tie semantics, early
  resolution, per-tier isolation, LP share/fee exactness, every guard.
- [`test/GestureSeriesMarketFuzz.t.sol`](test/GestureSeriesMarketFuzz.t.sol) —
  property-based fuzz tests. Each states an economic/safety property that must
  hold for all inputs: CST conservation across the whole lifecycle, x·y=k
  monotonicity, quotes equal execution, path independence, LP joins can't
  extract value from incumbents, add-then-remove never profits, fee escrow
  exact to the wei, best-tier routing beats every single tier, and the
  resolution truth table matches strict comparison for all counts.
- [`test/GestureSeriesMarketInvariant.t.sol`](test/GestureSeriesMarketInvariant.t.sol)
  — stateful invariant testing with `fail_on_revert`. A handler drives random
  interleavings of the full multi-round lifecycle (LPs in and out of every
  tier, bets, sets, gesture arrivals, threshold crossings, round rollovers,
  early/normal resolutions, claims) while ghost variables track every wei.
  After every call: exact collateralization, coherent share ledgers, fee
  solvency. After every campaign: force-drain everything and prove everyone is
  paid in full, with the retained remainder equal to dead-share reserves plus
  fee dust — exactly.
- [`test/GestureSeriesMarketHardening.t.sol`](test/GestureSeriesMarketHardening.t.sol)
  — the attack suite described above, one scripted adversary per mitigation.
- [`script/GenerateVectors.s.sol`](script/GenerateVectors.s.sol) — executes
  hundreds of real contract flows and dumps them to
  `frontend/src/test/fixtures/contract-vectors.json`; the frontend's math
  library must match **bit-for-bit** (CI regenerates and fails on drift).

Fuzzing intensity is configured per profile in [`foundry.toml`](foundry.toml);
crank the `heavy` numbers up arbitrarily for overnight runs.

## Deployment

Deploy the singleton **once**; every future round runs on it automatically:

```bash
FEE_TIERS=100,200,500 \
forge script script/Deploy.s.sol \
  --rpc-url $ARBITRUM_RPC_URL --private-key $PRIVATE_KEY --broadcast
```

No pre-funding needed — liquidity arrives permissionlessly per round, from
anyone, into the fee tier of their choice.

For frontend development there is a local sandbox
([`script/DeployLocal.s.sol`](script/DeployLocal.s.sol)) that deploys a mock
game + mock CST + the series with seeded liquidity on anvil; see
[`frontend/README.md`](frontend/README.md).

## Design notes and trade-offs

- **Live information is priced in, by design.** The gesture count is public
  while the round runs, so this is a live over/under against last round's
  count. Certainty accumulates monotonically — and asymmetrically: YES can
  become certain mid-round (handled by early resolution + the atomic trading
  halt), NO can't before the round ends. Late informed trading costs LPs
  money; the per-bet fee is the compensation, and LPs both pick that fee and
  can leave at any moment. Size positions accordingly.
- **Outcome manipulation is possible but costly.** Someone holding YES could
  place extra gestures to push the count over the threshold. Each gesture
  costs real ETH/CST in the game, so modest pool sizes keep manipulation
  unprofitable.
- **The game is an owner-upgradeable proxy.** The market trusts its
  `roundNum` and `bidderAddresses` getters.
- **Dead-share dust is the cost of inflation resistance.** Each pool
  permanently locks 1000 share-wei plus the CST backing them (wei-scale);
  in exchange, first-depositor inflation attacks are structurally dead.
