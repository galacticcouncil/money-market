# Propeller: optimize swap costs with operator-funded gas

The user objective is **funded crypto after debt, protocol fees and trading
losses**. Gas is operator-funded and does not justify delaying a useful trade.
The specified **$10/month total** for the two operators, RPCs and monitoring is
recorded in the external operating budget. It is not a new charge against users'
collateral. All-cost strategy economics remain visible separately.

This updates the interpretation of the
[three-round operations campaign](operations-tuning-three-rounds-2026-10-03.md).
The original 64 contract simulations and their logs are unchanged. The
[new analysis](evidence/sponsored-gas-swaps-2026-10-03/analysis.json) verifies and
re-ranks the 46 optimization cases and adds 24 source-pool slicing comparisons.
It does **not** represent another three-round contract campaign or simulate
disabling the existing keeper's gas-batching gate.

## Effect on the earlier choices

Excluding gas changes the first-round winner from a 25bp harvest threshold to
1bp. That round's average funded return is 3.4912% at 1bp and 3.4895% at 25bp:
the difference is only about $0.17/year on $10,000, and is sensitive to the
measurement horizon. Gas savings were the reason to prefer 25bp in the original
comparison. That reason no longer supports the user objective.

Among all configurations already tested, the 30bp / $8,000 / $5,000-per-day case
still has the best average funded return: **3.54% ETH / 3.74% BTC** on isolated
$10,000 vaults with the modeled external liquidity replenishment. These figures
already include modeled trading losses and protocol fees, and exclude unconverted
yield. They are conditional first-year model results, not live APY quotes.

This is the best **previously tested** case, not an established optimum for
operator-funded gas: later rounds inherited the old cost-weighted first-round
winner. In particular, the 1bp runs still contain thousands of gas-gate skips;
merely removing gas from their score does not remove those skipped trades.
The prior 30bp setting should not be activated as a newly validated recommendation
for this objective. No keeper policy or on-chain configuration changes here.

The subsequent [Neckwork recovery comparison](prime-recovery-history-2026-10-03.md)
adds 1,970 exact reserve observations and historical versus perfect recovery
timing. Periodic replenishment is modeled explicitly, but the fast recent flow
is dominated by a finite Treasury DCA whose budget was already 96.95% consumed.
Its active period must not be repeated indefinitely in an annual simulation.

## Where the modeled trading losses occur

For the best previously tested case, per $10,000 over the first year:

| Item | ETH | BTC |
| --- | ---: | ---: |
| HOLLAR spent buying PRIME | $45,707.40 | $48,780.27 |
| Estimated source entry loss at modeled 5bp | $22.85 | $24.39 |
| Remaining crypto/interest-servicing loss and rounding | $6.41 | $11.42 |
| Total reconciled trading loss | **$29.26** | **$35.81** |
| Funded user crypto after trading, debt and protocol fees | **$354.42** | **$373.88** |
| External operations, including $120/year shared budget | $129.93 | $130.84 |

These are realized losses within the mocked execution boundary, not a clean
separation of pool fees and slippage. The annual model applies fixed all-in
haircuts: source entry 5bp, source unwind 7bp, and crypto/servicing routes 60bp ETH
or 100bp BTC. The latter are assumptions, not measurements of every actual route.
A slippage tolerance is a rejection limit; it is not a fee automatically paid.

The direct loss is approximately 0.29 / 0.36 percentage points of planned
capital. Its full effect on return can be larger because entry losses delay
readiness, further borrowing and reinvestment. A zero-cost counterfactual has
not been simulated here. Complete source unwind remains an additional
illustrative $33.10 / $35.33 trading expense under the earlier 7bp assumption.

## Does splitting trades reduce cost?

Using the official stable-swap SDK math at the original block 15,318,402 pin,
source pool 143 has a nominal **4bp pool fee**. At that state, the effective
quote loss also reflects reserve imbalance, the pool peg and the oracle
reference. Fee, price impact and quote-to-inclusion slippage are distinct.

For $8,000 of total HOLLAR input:

| Execution pattern | Total modeled loss | Effective loss |
| --- | ---: | ---: |
| One $8,000 trade | $3.8115 | 4.7644bp |
| Eight $1,000 trades, sequential reserve updates | $3.8113 | 4.7642bp |
| Eighty $100 trades, sequential reserve updates | $3.8114 | 4.7642bp |
| Eight $1,000 trades, original liquidity restored before each | $2.7757 | 3.4697bp |
| Eighty $100 trades, original liquidity restored before each | $2.6426 | 3.3033bp |

Immediate slicing against the same reserves provides essentially no saving.
Percentage fees apply to the same total volume, and later slices encounter the
imbalance created by earlier ones. Waiting helps only if the executable price
actually improves. The replenished rows assume an outside trader or liquidity
source restores the pool before every slice; elapsed time and a token-bucket
refill do not establish that condition. They are not funded-refill promises.

The analysis also tests $10,000 and $40,000 total inputs and records whether
every slice fits the 10bp source bound with 2bp quote margin. Pool math does not
include native circuit breakers, other traders or future peg/oracle changes;
an acceptable mathematical quote still requires a fresh executable preview.

## Implications for controls and further tuning

The useful control is a bound on **actual quote loss for the complete route**,
with size selected from current liquidity. A larger harvest should not be
preferred just because it uses fewer transactions. Equally, many immediate
small trades must not be treated as fresh copies of the original pool.

Preserve shared volume limits and fresh-quote/oracle floors. Choose a smaller
slice when it improves execution while still making useful progress. Wait for
quote recovery when further trades would create excessive impact, and compare
that saving with foregone crypto realization and reinvestment during the wait.

The next trading model needs measured size-dependent quotes for PRIME→ETH/BTC
and collateral→HOLLAR, in addition to the source pool. It should also evaluate
whether paying Main interest directly from earned PRIME→HOLLAR can avoid the
current PRIME→crypto→HOLLAR conversion on that portion, while preserving yield
ownership, vested protocol fees and principal backing. No saving from a different
route is booked before those quotes and accounting paths are validated.

Reproduce the new analysis from the repository root with the already installed
official SDK math packages:

```sh
HYDRATION_MATH_ROOT=/path/to/sdk/packages node scripts/propeller/analyze-sponsored-swaps.mjs propeller-vault/docs/evidence/operations-tuning-three-rounds-2026-10-03 /tmp/sponsored-swaps.json 10
```

The analysis checks original log hashes and parsed metrics before scoring them.
Original scenario files and the original three-round selection remain intact
as historical evidence of the earlier all-cost objective.
