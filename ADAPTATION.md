# SwarmDerby launch adaptation

## Launch scope

Deploy only `src/SwarmDerby.sol:SwarmDerby` on Robinhood Chain (4663).
Its existing nonpayable constructor already accepts four supported static ABI words,
in this order:

| Argument | ABI type | Launch value |
| --- | --- | --- |
| `owner_` | `address` | `$owner` |
| `imd_` | `address` | `0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127` |
| `singlePrice_` | `uint256` | `150000000000000000` |
| `packPrice_` | `uint256` | `500000000000000000` |

The factory sends zero ETH. Ownership is assigned to `owner_`, not the factory.
No initializer or additional application deployment is needed. `DerbyOdds` has only
internal functions and requires no linked library deployment. There is no new token,
distributor, pool, proxy or launch manifest in this adaptation. The later manifest
step must list only SwarmDerby with the arguments above; test addresses are not owners
or dependencies to use in that manifest. No transaction was broadcast.

## Changes and reasons

- `test/SwarmDerby.t.sol`: explicitly routes the two ArbSys read selectors through
  the existing mock using `vm.mockFunction`. This fixes the Forge 1.8.5 fixture
  incompatibility described below without changing any of the 53 original test
  cases or assertions. Mock storage and injected block hashes still live at
  address 100. The new launch suite uses the same routing.
- `test/SwarmDerbyLaunch.t.sol`: adds four offline regression tests using the actual
  SwarmDerby creation code, the exact launch arguments and a zero-value CREATE2
  probe equivalent to the supplied protected probe. They verify explicit ownership,
  address prediction, constructor configuration, immediate purchases, unchanged
  splits, one application with no constructor-created children, runtime limits and
  forbidden opcodes. They also reproduce both imported low findings and verify
  session recovery and rejection of reused consent. Existing MockIMD and MockArbSys
  fixtures model external chain state; they are not launch contracts.
- `DEPLOY.md`: documents the offline rehearsal, the separate protected harness's
  dependency-state requirement, and the effect of signing session consent with a
  funded playing wallet. These are operational mitigations for the two low findings;
  they do not change the deployed contract or the separately published site.
- `ADAPTATION.md`: records the exact launch inputs, changes, audit dispositions and
  validation limits required by this assignment.

Neither production Solidity file has been edited. Their SHA-256 hashes are:

```text
4866aee00e05de0f195c69bcb3a957cdc73c97548c74f8b3e7fb055c31fcee84  src/SwarmDerby.sol
9931884e49e10a163b9d5bba38eb1e6876b3c5a0d0d9b33a84a7e242e6eff28b  src/DerbyOdds.sol
```

The ABI, events, errors, constants, price behavior, 40/45/10/5 split, payout math,
browser odds, and all explicitly accepted behaviors remain unchanged. Build
configuration and dependencies are unchanged; `bytecode_hash = "none"` was already
configured. No additional dependency is required.

## Imported audit dispositions

### 980f397e0d1445a01070230c7b6c357a68b1f535cc5a73d50001ef1b63a538e2 — low

Reproduced by `test_emptyChainRehearsalRequiresImdCode`: with no code at the specified
IMD address, direct construction reverts `NotAContract()` and CREATE2 through the
probe reverts `application constructor failed`. With the test-only dependency code
present, the exact same constructor succeeds in the factory tests. This is a local
rehearsal precondition, not a critical or high contract defect; the guard is preserved
under the request to deploy the audited code unchanged.

The supplied `ContractsProtectedTest.setUp()` does not install external dependency
state. Its independent run still needs a Robinhood fork or a test fixture installed
at IMD **before** construction. Merely setting `IMD_PROJECT_CHAIN_ID=4663` is not
enough. Fixtures installed by our separate test suite do not carry into that harness.
An unmodified, empty-state protected run therefore remains incompatible with this
unchanged constructor. This adaptation does not claim that independent run passes.
The launch rehearsal must supply the dependency state rather than weaken the guard.

### 4f16c38ce1f82561876a70354c53a42b76db080938f51a5c215995553f9e9704 — low

Reproduced by `test_fundedSessionSignerRedirectsActivityUntilItLeaves`: a wallet buys
ten turns, consents to act for another player, then pays for two turns credited to
that player and swings using that player's turns. Its own ten turns remain recorded
and become spendable again after `leaveSession()`. The test also verifies that the
old signature cannot bind it again after leaving.

This exposure requires the key's valid, player-specific consent; it is not an
unauthorized binding. It remains a phishing risk. Refusing funded or previously active
session keys would change existing behavior, so no such restriction was introduced
under the brief's critical/high-only code-change rule. `DEPLOY.md` now explicitly
documents the effect and dedicated-key practice. No claim is made that the owner
accepted this particular finding, that leaving reverses credited activity, or that
the separate site's UI was changed.

### a48d011c0df6ba1d2c5ae4cf29420f2e7373c1865b67b8de74616df534ac46a2 — informational

This is a coverage statement, not a defect requiring a reproduction or patch.
Both production contracts and the original tests were read. The factory regression
checks the application runtime against EIP-170 and the supplied floor's opcode scan,
skipping PUSH data. The built runtime is 12,551 bytes; init code including the four
arguments is 13,033 bytes, below the 49,152-byte limit. The ABI reports a nonpayable
constructor with `(address,address,uint256,uint256)` and no library links.

Read-only RPC requests to `https://rpc.mainnet.chain.robinhood.com` for chain ID,
IMD code/symbol/decimals and ArbSys block number all returned HTTP 403 here. The
imported audit's live IMD identity, transfer semantics and ArbSys observations were
therefore not independently reverified. Offline mocks cannot prove those live facts.
The existing dependency assumptions remain: standard IMD transfers without fees or
receiver callbacks, with token-admin blocklist/transfer powers outside SwarmDerby.
No critical or high issue was reproduced in this review.

## Validation

The installed toolchain is Forge 1.8.5 with the project's pinned Solidity 0.8.26,
optimizer enabled for 2,000 runs and via-IR. The incoming suite exhibited a test
fixture incompatibility: Forge's ArbSys emulation returned block 1 after the etched
mock's `setBlock(1006)`, causing 18 of the original 53 tests to fail. Production
contract changes are not a remedy for that test-runner behavior.

Explicit `vm.mockFunction` routing fixes the fixture while retaining its block-range
checks and per-block hashes. A scratch reproduction confirmed both the updated
block-number read and a hash injected into storage at address 100; that temporary
test was removed after verification.

Final checks:

- `forge build`: succeeds with the existing configuration; existing contract lint
  warnings remain. These include timestamp/cast, rounding and external-call
  patterns; they do not establish a critical or high finding by themselves.
- `forge test`: 57 passing tests, zero failures, comprising the original 53 plus
  four launch tests. Both original fuzz tests run 256 cases. Browser parity,
  settlement conservation, reveal boundaries, slam payouts and session tests pass.
- The constructor ABI, init/runtime sizes and absence of linked libraries were
  checked against the compiled artifact. The deployed runtime's forbidden-opcode
  scan passes in the launch test.
- `git diff --check` passes, and both production source hashes match their inputs.

No Slither, Mythril, live fork, live deployment or explorer verification was run.
The independent protected-harness dependency precondition and RPC limitation above
remain explicit handoff items, separate from the passing local suite.
