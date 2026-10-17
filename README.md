# MOR-C6 PoC — SessionRouter self-dealing session farm (LumerinDiamond, Base)

Foundry fork test against the deployed LumerinDiamond
`0x6aBE1d282f72B474E54527D93b979A4f64d3030a` on Base, pinned at block
52,725,925.

## Run

```sh
forge test -vv
```

That is the only command. The fork RPC endpoint is configured in
`foundry.toml` (`https://base.drpc.org`); any Base mainnet RPC URL can be
substituted there. No other setup is required.

Note: the public Base endpoint rate-limits fork bursts. If a run fails with
an HTTP 429 from the RPC, re-run the single failing test, for example:

```sh
forge test --match-test testSybilFarmCycle -vv
```

## What it proves

`SessionRouterTest.testSybilFarmCycle` — one actor controlling a provider
wallet and a user wallet extracts MOR from the protocol funding account with
no inference service rendered and no capital lost:

1. The actor registers as a provider (5,000 MOR stake), registers a model,
   and posts a bid at the maximum price (0.01 MOR/second).
2. The actor's user wallet opens a session against that bid, staking
   100,000 MOR, with a provider approval the actor signed themselves.
3. Time is warped past the session end. Nobody served anything.
4. `claimForProvider` — called with no session close and no valid provider
   receipt — pays the provider **292.11 MOR**, taken 1:1 from the funding
   account `0x5160C0311A95E0A1072FA85Df23712A7BA1cD4b1`.
5. The session is then closed with a receipt signed by a stranger (invalid),
   and after the day-lock the user withdraws the remainder. The user wallet
   ends with exactly its starting balance: the pair is up 292.11 MOR of
   protocol funds per cycle at zero capital cost.

The only brake is the provider reward limiter, proven by
`SessionRouterLimiterTest.testLimiterCapEqualsProviderStake`: a provider
registered at the 0.2 MOR minimum stake runs three sessions owed ~87.6 MOR
and can claim exactly 0.2 MOR in total — cumulative claims per 365-day
window are capped at the provider's own stake. Extraction per provider
identity is therefore bounded by that identity's stake per year; identities
cost 0.2 MOR minimum stake each.

Supporting tests in the same file document that the provider approval is
not bound to the user it names (an approval signed for user A opens a
session for user B), that approval replay and expiry are enforced, and that
the delegatee fences on `openSession`/`claimForProvider` hold.

No privileged account is used anywhere: all actors are fresh keys funded
with test capital (anyone can buy MOR), and every protocol call is made
from an unprivileged address.
