# Documentation archive

These documents left the tree before the release to keep it reviewable. They
record earlier revisions, dated validations, deployments and studies. The
[review package](external-review.md), the current specifications in the
[documentation index](README.md) and the code take precedence. Each link opens
the file at `8519575`, the last commit that carried it.

## Validation and verification records

- [`main-debt-verification.md`](https://github.com/galacticcouncil/money-market/blob/8519575/juicer-vault/docs/main-debt-verification.md): verification of the PR #60 Main-servicing revision against the 22 September fixture, including the 370-case contract campaign.
- [`route-execution-calibration.md`](https://github.com/galacticcouncil/money-market/blob/8519575/juicer-vault/docs/route-execution-calibration.md): production adapter, native lifecycle, real-route quotes and retention campaign, 23 September (RC1).
- [`pr60-completion.md`](https://github.com/galacticcouncil/money-market/blob/8519575/juicer-vault/docs/pr60-completion.md): PR #60 completion checks, 25 September: target-branch reconciliation and the RC1 model replay fixes.
- [`pr-integration-2026-10-02.md`](https://github.com/galacticcouncil/money-market/blob/8519575/juicer-vault/docs/pr-integration-2026-10-02.md): the #60, #61 and #63 integration checkpoint, 2 October.
- [`pr62-completion-2026-10-02.md`](https://github.com/galacticcouncil/money-market/blob/8519575/juicer-vault/docs/pr62-completion-2026-10-02.md): PR #62 implementation record for separate yield ownership and prompt reinvestment, 2 October.
- [`pr62-three-pass-validation-2026-10-02.md`](https://github.com/galacticcouncil/money-market/blob/8519575/juicer-vault/docs/pr62-three-pass-validation-2026-10-02.md): three validation passes over PR #62's accounting, native deployability and execution.
- [`execution-controls-validation-2026-10-03.md`](https://github.com/galacticcouncil/money-market/blob/8519575/juicer-vault/docs/execution-controls-validation-2026-10-03.md): execution-controller and keeper validation with measured native gas, 3 October.
- [`deferred-deployment-validation-2026-10-04.md`](https://github.com/galacticcouncil/money-market/blob/8519575/juicer-vault/docs/deferred-deployment-validation-2026-10-04.md): deferred deposits and price-aware execution, 4 October.

## Lark deployment records

- [`deployments/`](https://github.com/galacticcouncil/money-market/tree/8519575/juicer-vault/deployments): the Lark 4 address registry and journal of the 7 September deployment; the chain has been reforked since.
- [`lark-deployment-2026-10-05.md`](https://github.com/galacticcouncil/money-market/blob/8519575/juicer-vault/docs/lark-deployment-2026-10-05.md): the 5 October Lark 4 deployment with hosted operators, superseded two days later.
- [`lark-deployment-2026-10-07.md`](https://github.com/galacticcouncil/money-market/blob/8519575/juicer-vault/docs/lark-deployment-2026-10-07.md): the 7 October fresh-fork Lark 4 deployment of the PR #62 contracts.

## Models and studies

- [`market-stress-90d.md`](https://github.com/galacticcouncil/money-market/blob/8519575/juicer-vault/docs/market-stress-90d.md): readiness review and 90-day pressure tests, 18 September.
- [`hollar-peg-liquidity.md`](https://github.com/galacticcouncil/money-market/blob/8519575/juicer-vault/docs/hollar-peg-liquidity.md): HOLLAR peg stability and liquidity model, 22 September.
- [`interest-policy-comparison.md`](https://github.com/galacticcouncil/money-market/blob/8519575/juicer-vault/docs/interest-policy-comparison.md): the Main interest policy comparison behind the current servicing design, 22 September.
- [`coupled-liquidity-checkpoint.md`](https://github.com/galacticcouncil/money-market/blob/8519575/juicer-vault/docs/coupled-liquidity-checkpoint.md): coupled liquidity research checkpoint, 22 September.
- [`mainnet-tuning-five-rounds-2026-10-02.md`](https://github.com/galacticcouncil/money-market/blob/8519575/juicer-vault/docs/mainnet-tuning-five-rounds-2026-10-02.md): five rounds of mainnet model tuning, before the execution controller.
- [`operations-tuning-three-rounds-2026-10-03.md`](https://github.com/galacticcouncil/money-market/blob/8519575/juicer-vault/docs/operations-tuning-three-rounds-2026-10-03.md): three rounds of APY tuning with operating costs.
- [`sponsored-gas-swap-costs-2026-10-03.md`](https://github.com/galacticcouncil/money-market/blob/8519575/juicer-vault/docs/sponsored-gas-swap-costs-2026-10-03.md): swap costs re-ranked with operator-funded gas.
- [`prime-recovery-history-2026-10-03.md`](https://github.com/galacticcouncil/money-market/blob/8519575/juicer-vault/docs/prime-recovery-history-2026-10-03.md): observed PRIME pool recovery against perfect arbitrage.
- [`historical-apy-four-rounds-2026-10-03.md`](https://github.com/galacticcouncil/money-market/blob/8519575/juicer-vault/docs/historical-apy-four-rounds-2026-10-03.md): four rounds of historical APY modeling over 90 days of market inputs.

## Superseded designs and plans

- [`operating-buffer.md`](https://github.com/galacticcouncil/money-market/blob/8519575/juicer-vault/docs/operating-buffer.md): the sponsored HOLLAR operating-buffer proposal that yield-funded Main servicing replaced.
- [`operating-buffer-verification.md`](https://github.com/galacticcouncil/money-market/blob/8519575/juicer-vault/docs/operating-buffer-verification.md): its verification at `1efdf1d`.
- [`principal-safety-history.md`](https://github.com/galacticcouncil/money-market/blob/8519575/juicer-vault/docs/principal-safety-history.md): principal-safety design discussion and dated checkpoints, retained 23 September.
- [`next-version-plan.md`](https://github.com/galacticcouncil/money-market/blob/8519575/juicer-vault/docs/next-version-plan.md): the 8–9 October plan for the version after PR #62, which became the launch candidate.
- [`rename-juicer.md`](https://github.com/galacticcouncil/money-market/blob/8519575/juicer-vault/docs/rename-juicer.md): the Propeller to Juicer rename map and its exclusions.
- [`FUTURE_IMPROVEMENTS.md`](https://github.com/galacticcouncil/money-market/blob/8519575/juicer-vault/FUTURE_IMPROVEMENTS.md): backlog of the June audit remedies, Lark 2 follow-ups and ideas parked in October.

## Audit snapshots

Reviews of later revisions are listed under [earlier reviews](external-review.md#earlier-reviews) in the review package.

- [`AUDIT.md`](https://github.com/galacticcouncil/money-market/blob/8519575/juicer-vault/AUDIT.md): the finding ledger as of 7 August (`ys-propeller-fixes` at `0e7f9a4`), before PRs #53 and #57.
- [`audit/`](https://github.com/galacticcouncil/money-market/tree/8519575/juicer-vault/audit): the 31 July security review of `ys-propeller-fixes`, which the ledger superseded.
- [`x-ray/`](https://github.com/galacticcouncil/money-market/tree/8519575/juicer-vault/x-ray): the 7 August x-ray of the same revision: architecture, entry points and git signals.
