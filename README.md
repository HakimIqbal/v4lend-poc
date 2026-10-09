# v4lend PoC bundle — int24 config/execution overflow (commit f6d0fb4)

## Environment
- Repo: https://github.com/revert-finance/v4lend.git @ commit f6d0fb4 (main)
- Toolchain: Foundry forge 1.7.2-dev, Solc 0.8.30 (per foundry.toml), EVM version cancun
- Any mainnet RPC as MAINNET_RPC_URL (the suites run fork tests; example uses drpc.org)

```bash
git clone https://github.com/revert-finance/v4lend.git && cd v4lend
git checkout f6d0fb4
forge install
```

## Files
| File | Place at | Purpose |
|---|---|---|
| Scan3PlanOverflow.t.sol | test/hook/ | Site 1 hook-path behavioral PoC (136 bound-fuzz runs) |
| Scan3LimitOverflow.t.sol | test/automators/ | Site 2 PoC: 6 tests (3 unit isReady, 3 E2E config->panic) |
| Scan3NegRangeLimit.t.sol | test/hook/ | Negative-limit variants (2 tests) |
| Scan3Verify.t.sol | test/shared/ | Fix-verification probes: FAIL with panic(0x11) on clean f6d0fb4 |
| FixDiffRegression.t.sol | test/hook/ | Post-fix regression (9 tests; expected to fail on UNPATCHED code) |
| fix-diff.patch | (repo root) | The proposed fix + FixDiffRegression, applied with `git apply` |

Copy each test file into the target directory above (directories already exist).

## Reproduce the vulnerability (clean f6d0fb4)

```bash
MAINNET_RPC_URL=https://eth.drpc.org forge test --match-contract "Scan3PlanOverflow|Scan3LimitOverflow|Scan3NegRangeLimit|Scan3Verify"
```

Expected on clean f6d0fb4 (verified 2026-10-09, forge 1.7.2-dev):
- Scan3PlanOverflow: 136 passed / 0 failed  (hook path: config accepted, plan panics, trigger consumed, automation dead)
- Scan3LimitOverflow: 6 passed / 0 failed    (isReady + zone checks panic with 0x11 as asserted)
- Scan3NegRangeLimit: 2 passed / 0 failed
- Scan3Verify: 1 passed / 2 failed            (test_PlanInt24Overflow, test_PlanInt24Underflow FAIL with exactly panic 0x11)
- Total: 281 passed, 2 failed — the 2 failures ARE the raw vulnerability evidence (they require the fix to pass)

## Apply the fix (red -> green)

```bash
git apply fix-diff.patch     # adds the saturating-int256 fix + FixDiffRegression.t.sol
MAINNET_RPC_URL=https://eth.drpc.org forge test --match-contract "Scan3PlanOverflow|Scan3LimitOverflow|Scan3NegRangeLimit|Scan3Verify|FixDiffRegression"
```

Expected with the patch:
- FixDiffRegression: 9 / 9 pass (every previously-panicking input now returns its saturated sentinel)
- Scan3Verify: 3 / 3 pass
- Scan3PlanOverflow: 136 / 136 pass (hook-path suite unchanged)
- Scan3NegRangeLimit: 2 / 2 pass
- Scan3LimitOverflow: 5 of the 6 panic-demonstrations now "fail" by flipping to NotReady() / SameRange() / no-revert — this flip IS the proof the panics are gone (the 6th test, test_Uint128AbiDecodeTruncatesOrReverts, stays green)

Undo with `git checkout -- src/` (the patch only touches src/shared/planning/AutoRangeLib.sol,
src/automators/AutoLend.sol and adds the regression test).
