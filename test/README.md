# SwarmDerby test coverage

Run `forge build` and `forge test`. No RPC, environment changes, downloaded dependencies or FFI are required.

The original application tests, browser parity vectors and factory deployment rehearsals remain intact. The additional suites instantiate the unchanged `SwarmDerby` with the requested IMD address and prices. All helper tokens and ArbSys behavior are local test fixtures, not launch outputs.

`SwarmDerbyFailures.t.sol` covers atomic rollback of failed incoming transfers, failed burns, failed ops withdrawals and failed settler tips; refused prizes; empty ERC20 return data; insufficient balances and allowances; maximum purchase counts; invalid league arguments; unavailable block hashes; terminal swings; session signature domains, malleability and replacement rollback; and player attribution in the public events. Purchase arithmetic is exercised at minimum prices plus one wei and with 1,000 fuzz cases, including amounts with fractional split remainders.

`SwarmDerbyInvariant.t.sol` uses a handler with twelve players and twelve independently consenting session keys. Its ten selected actions interleave single/pack purchases, swings, reveals, expiry, time advancement, settlement, ops withdrawals, direct donations, recipient refusal and session binding/revocation. Inputs are bounded; known failure paths assert specific errors. Unexpected handler reverts fail the campaign. Inline settings request 256 sequences of 64 calls.

The invariant checks, after each call:

- Token custody equals both leagues' pots and vaults, outstanding ops and independently tracked donations. Purchases equal burned, held and paid tokens.
- Each league's deposits fund only its own pot and vault payouts; the owner can withdraw only earned ops.
- Turn credits match purchases less swings, session mappings agree in both directions, and arcade usage stays within the daily cap.
- Swing identities, commitments and status match the action history; final swings stay final.
- Open days stay in chronological order, each settles once, and pots equal open day funds plus rollover.
- Scoreboards contain unique, correctly ordered top players, with longest homer scores for arcade and cumulative homer scores for agents.

A deterministic handler test exercises payments, rejection, sessions and expiry. The campaign's `afterInvariant` hook then expires remaining swings, drains every settlement queue and withdraws the entire ops balance, checking liveness and accounting after each generated history. Homers and slams enter through `finalize`; the invariant does not expose internal scoring functions or write application storage.

The token stand-in models exact transfers with normal or empty return data and refused transfers that move no tokens. It does not establish the live IMD contract's behavior or compatibility with fee-on-transfer/rebasing assets. Robinhood Chain's live IMD code and ArbSys behavior still need verification against chain state; this offline suite makes no deployment or live-chain verification claim.
