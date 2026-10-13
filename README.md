# CRE Price Snapshot

A [Chainlink Runtime Environment](https://docs.chain.link/cre) workflow that, in a
single HTTP-triggered execution:

1. accepts a JSON body naming a token — `{"token":"ETH"}`,
2. reads that token's USD price from a **Chainlink Data Feed on Ethereum Sepolia**
   through the **EVM Read** capability,
3. writes the price, the block at which the feed answer was last updated, and the
   feed's `updatedAt` timestamp to a `PriceSnapshot` contract through the
   **EVM Write** capability.

```
HTTP POST {"token":"ETH"}
          │
          ▼
  ┌───────────────────┐   EVM Read    ┌──────────────────────────┐
  │   CRE workflow    │ ────────────▶ │ Chainlink Data Feed      │
  │  (my-workflow)    │               │ ETH/USD proxy + aggregator│
  │                   │ ◀──────────── │ answer, updatedAt, round  │
  └───────────────────┘               └──────────────────────────┘
          │  runtime.report()  →  DON-signed report
          │  EVM Write
          ▼
  ┌───────────────────┐  onReport()   ┌──────────────────────────┐
  │ KeystoneForwarder │ ────────────▶ │ PriceSnapshot.sol        │
  │ (verifies sigs)   │               │ forwarder check, Record  │
  └───────────────────┘               └──────────────────────────┘
```

---

## Deployed contract

| Item | Value |
| --- | --- |
| Network | Ethereum Sepolia (`ethereum-testnet-sepolia`, chain id 11155111) |
| `PriceSnapshot` | [`0x7593CAF3DabFB04BD0116Be2e191736aeAC08DC5`](https://sepolia.etherscan.io/address/0x7593CAF3DabFB04BD0116Be2e191736aeAC08DC5) |
| Deploy tx | [`0x523b6622…64b1f1`](https://sepolia.etherscan.io/tx/0x523b66224360396a5bdfdaa2bf1bb0c657cccc6beff06b6671341b9c8864b1f1) |
| Trusted forwarder | `0x15fC6ae953E024d975e77382eEeC56A9101f9F88` (Sepolia `MockKeystoneForwarder`, used by `cre workflow simulate --broadcast`) |
| Snapshot: ETH | [`0x240a8703…05b32a`](https://sepolia.etherscan.io/tx/0x240a8703a6a7a15570f26e8b7f816ec411ff7d1d7e54553359c8eb584205b32a) — `("ETH", 250782942174, 11906385, 1791898224)` |
| Snapshot: BTC | [`0xa0dc09cd…f39726`](https://sepolia.etherscan.io/tx/0xa0dc09cd42f464d78352877cedde9b590b844b07803e45ec60f4dd5bc4f39726) — `("BTC", 8312271000000, 11906276, 1791896916)` |

This address is already set as `consumerAddress` in
`my-workflow/config.staging.json`, so the workflow runs against it as committed.

---

## Repository layout

```
.
├── project.yaml                   CRE project settings (RPC per target)
├── secrets.yaml                   secrets template (this workflow needs none)
├── .env.example                   environment template — copy to .env
├── my-workflow/                   the CRE workflow
│   ├── main.ts                    WASM entry point
│   ├── workflow.ts                trigger handler, EVM read + write
│   ├── abi.ts                     Data Feed ABI and report payload shape
│   ├── workflow.test.ts           unit tests (bun test)
│   ├── workflow.yaml              workflow settings per target
│   ├── config.staging.json        feeds allow-list, consumer address, gas limit
│   ├── config.production.json
│   └── http_trigger_payload.json  sample trigger body
└── contracts/                     Foundry project
    ├── src/ISnapshot.sol          Record struct + snapshot() signature
    ├── src/PriceSnapshot.sol      consumer contract (forwarder check lives here)
    ├── src/IReceiver.sol          Chainlink receiver interface
    ├── src/IERC165.sol
    ├── test/PriceSnapshot.t.sol   30 tests
    └── script/DeployPriceSnapshot.s.sol
```

---

## Prerequisites

| Tool | Notes |
| --- | --- |
| [CRE CLI](https://docs.chain.link/cre/getting-started/cli-installation) | `curl -sSL https://app.chain.link/cre/install.sh \| bash` |
| CRE account | `cre login` — simulation requires an authenticated session |
| [Bun](https://bun.com) ≥ 1.2.21 | `curl -fsSL https://bun.sh/install \| bash` |
| [Foundry](https://getfoundry.sh) | `curl -L https://foundry.paradigm.xyz \| bash && foundryup` |
| Funded Sepolia account | `--broadcast` and the deploy both spend gas — [faucets.chain.link](https://faucets.chain.link/sepolia) |

---

## Setup

```bash
git clone --recurse-submodules <this-repo>
cd chainlink-cre-assignment

# 1. Environment
cp .env.example .env
#    then edit .env: set CRE_ETH_PRIVATE_KEY (64 hex chars, no 0x prefix)

# 2. Workflow dependencies
cd my-workflow && bun install && cd ..

# 3. Contract dependencies (only if lib/ is empty, e.g. cloned without --recurse-submodules)
cd contracts && forge install && cd ..

# 4. Authenticate the CRE CLI
cre login
```

---

## Deploy the contract

The constructor takes the forwarder address the contract will trust. **Simulation
and production use different forwarders**, so pick the one matching how you will
run the workflow:

| How you run the workflow | Forwarder to deploy with |
| --- | --- |
| `cre workflow simulate --broadcast` | `0x15fC6ae953E024d975e77382eEeC56A9101f9F88` (`MockKeystoneForwarder`) |
| Deployed workflow (`cre workflow deploy`) | `0xF8344CFd5c43616a4366C34E3EEE75af79a74482` (`KeystoneForwarder`) |

Both come from the [CRE Forwarder Directory](https://docs.chain.link/cre/guides/workflow/using-evm-client/forwarder-directory).
`.env.example` defaults `FORWARDER_ADDRESS` to the simulation one. You do not have
to redeploy to switch — the owner can call `setForwarder(address)`.

```bash
cd contracts
forge test                      # 30 tests, all local

set -a && source ../.env && set +a
cast send \
  --rpc-url "$ETHEREUM_SEPOLIA_RPC_URL" \
  --private-key "0x$CRE_ETH_PRIVATE_KEY" \
  --gas-limit 15000000 \
  --create "$(jq -r .bytecode.object out/PriceSnapshot.sol/PriceSnapshot.json)" \
  "constructor(address)" "$FORWARDER_ADDRESS"
```

Then put the `contractAddress` from the receipt into
**`my-workflow/config.staging.json`** → `consumerAddress`.

> **Why `cast send` with an explicit gas limit, and not `forge script`?**
>
> Sepolia has repriced contract creation well above what Foundry's `cancun`
> target assumes. This contract costs **1.25M gas locally but ~9.47M on Sepolia**,
> and the block gas limit there is now ~200M. `forge script` sizes the
> transaction from its own local estimate (~1.78M) and ignores `--gas-limit`, so
> the deployment runs out of gas and reverts with `status 0`. `eth_estimateGas`
> on two independent Sepolia RPCs returns 9,542,064, which matches the 9,465,772
> actually consumed. Gas is almost free there — the base fee was 17 wei — so a
> generous limit costs nothing.
>
> `script/DeployPriceSnapshot.s.sol` is kept for local use and for chains where
> Foundry's estimate is accurate (`forge script … --broadcast`).

Verification is optional:

```bash
forge verify-contract 0xYourDeployedPriceSnapshot \
  src/PriceSnapshot.sol:PriceSnapshot \
  --chain sepolia --etherscan-api-key "$ETHERSCAN_API_KEY" \
  --constructor-args "$(cast abi-encode 'f(address)' "$FORWARDER_ADDRESS")"
```

---

## Run the workflow

From the **project root**:

```bash
cre workflow simulate my-workflow --broadcast
```

That is the exact command required by the assignment — no `--target` is needed
because `.env` sets `CRE_TARGET=staging-settings`.

The simulator compiles the workflow to WASM, sees the single HTTP trigger, and
prompts for the JSON body. Enter:

```json
{"token":"ETH"}
```

Non-interactive equivalents:

```bash
# inline body
cre workflow simulate my-workflow --broadcast \
  --non-interactive --trigger-index 0 --http-payload '{"token":"ETH"}'

# body from the committed sample file
cre workflow simulate my-workflow --broadcast \
  --non-interactive --trigger-index 0 --http-payload http_trigger_payload.json
```

Drop `--broadcast` for a dry run: everything executes, but the write is not sent
and the transaction hash comes back as zeroes.

### Output of an actual run

Verbatim transcript from `cre workflow simulate my-workflow --broadcast`
(2026-10-13):

```
✓ Workflow compiled
✓ Simulation limits enabled
  Binary hash: d3273e338fa57539e6f97a61a48bbfc684c5f2915da79310f5376d8fc1748f81
✓ Parsed JSON input successfully
✓ Created HTTP trigger payload with 1 fields
2026-10-13T15:18:32Z [SIMULATION] Simulator Initialized

2026-10-13T15:18:32Z [SIMULATION] Running trigger trigger=http-trigger@1.0.0-alpha
2026-10-13T15:18:33Z [USER LOG] Snapshot requested for ETH via Data Feed 0x694AA1769357215DE4FAC081bf1f309aDC325306
2026-10-13T15:18:34Z [USER LOG] ETH / USD: answer=250782942174 decimals=8 (2507.82942174) updatedAt=1791898224 roundId=18446744073709588381
2026-10-13T15:18:34Z [USER LOG] AnswerUpdated round=36765 found in block 11906385 (searched 11906085..11906532, 1 logs)
2026-10-13T15:18:49Z [USER LOG] writeReport: txStatus=2 receiverStatus=0 txHash=0x240a8703a6a7a15570f26e8b7f816ec411ff7d1d7e54553359c8eb584205b32a
2026-10-13T15:18:49Z [USER LOG] Report delivered. https://sepolia.etherscan.io/tx/0x240a8703a6a7a15570f26e8b7f816ec411ff7d1d7e54553359c8eb584205b32a

✓ Workflow Simulation Result:
{
  "blockNumber": "11906385",
  "consumer": "0x7593CAF3DabFB04BD0116Be2e191736aeAC08DC5",
  "decimals": 8,
  "description": "ETH / USD",
  "feed": "0x694AA1769357215DE4FAC081bf1f309aDC325306",
  "price": "250782942174",
  "priceFormatted": "2507.82942174",
  "roundId": "18446744073709588381",
  "timestamp": "1791898224",
  "token": "ETH",
  "txHash": "0x240a8703a6a7a15570f26e8b7f816ec411ff7d1d7e54553359c8eb584205b32a"
}
```

`txStatus=2` is `TX_STATUS_SUCCESS` and `receiverStatus=0` is
`RECEIVER_CONTRACT_EXECUTION_STATUS_SUCCESS` — in these enums the success value
is not the one you might guess, so the workflow compares against the SDK
constants rather than truthiness.

> **The MockKeystoneForwarder does not report receiver reverts.** Running the
> same token twice inside one feed round is correctly rejected on-chain by
> `StaleSnapshot`, but the mock still returns `receiverStatus=0` (SUCCESS). A
> replay observed here used 158 326 gas instead of 1 369 018, emitted no
> `SnapshotRecorded` event, and left `snapshotCount` unchanged — yet the write
> reported success. So in simulation a successful write is **not** proof of a
> state change; confirm with `getSnapshot` below. The workflow still checks
> `receiverContractExecutionStatus`, which is meaningful against the production
> `KeystoneForwarder`, and its log says "Report delivered" rather than
> "Snapshot stored" for this reason.

### Verify on-chain

```bash
set -a && source .env && set +a
CONSUMER=0x7593CAF3DabFB04BD0116Be2e191736aeAC08DC5

cast call "$CONSUMER" "getSnapshot(string)((string,uint256,uint256,uint256))" "ETH" \
  --rpc-url "$ETHEREUM_SEPOLIA_RPC_URL"

cast call "$CONSUMER" "snapshotCount()(uint256)" --rpc-url "$ETHEREUM_SEPOLIA_RPC_URL"
```

After the run above:

```
("ETH", 250782942174, 11906385, 1791898224)
1
```

The stored `blockNumber` 11906385 is the block of the `AnswerUpdated` log for
round 36765, independently confirmed with `cast` in the section below, and the
stored `price` equals the answer that same log carries. The delivery transaction
is [`0x240a8703…05b32a`](https://sepolia.etherscan.io/tx/0x240a8703a6a7a15570f26e8b7f816ec411ff7d1d7e54553359c8eb584205b32a).

The transaction's `to` address is the **forwarder**, not `PriceSnapshot` — the
workflow submits a signed report to the forwarder, which verifies it and then
calls `onReport` on the consumer.

---

## Supported tokens

The workflow only prices tokens present in the `feeds` allow-list in
`config.staging.json`, so a caller cannot point it at an arbitrary contract.
Lookup is case-insensitive.

| Token | Sepolia Data Feed proxy | Decimals |
| --- | --- | --- |
| `ETH` | `0x694AA1769357215DE4FAC081bf1f309aDC325306` | 8 |
| `BTC` | `0x1b44F3514812d835EB1BDB0acB33d3fA3351Ee43` | 8 |
| `LINK` | `0xc59E3633BAAC79493d908e63626716e204A45EdF` | 8 |
| `USDC` | `0xA2F78ab2355fe2f984D808B5CeE7FD0A93D5270E` | 8 |
| `DAI` | `0x14866185B1962B63C3Ea9E03Bc1da838bab34C19` | 8 |
| `EUR` | `0x1a81afB8146aeFfCFc5E50e8479e826E7D55b910` | 8 |

Add more from the [Sepolia feed list](https://docs.chain.link/data-feeds/price-feeds/addresses?network=ethereum&page=1&testnetPage=1).
An unknown token fails fast, before any chain access:

```
Unsupported token "DOGE". Configured feeds: BTC, DAI, ETH, EUR, LINK, USDC
```

---

## The contract

`ISnapshot` carries the required `Record` struct and `snapshot` signature:

```solidity
interface ISnapshot {
    struct Record {
        string token;
        uint256 price;
        uint256 blockNumber;
        uint256 timestamp;
    }

    function snapshot(Record calldata record) external;
}
```

The report payload the workflow writes is exactly `abi.encode(Record)`, which
`onReport` decodes with `abi.decode(report, (Record))`. A Foundry test
(`test_reportEncoding_matchesWorkflowOutput`) and a Bun test pin that layout from
both sides, so the two cannot drift apart silently.

### The forwarder check

A CRE workflow never calls the consumer directly. It produces a DON-signed report;
the Chainlink `KeystoneForwarder` verifies the signatures and then calls
`onReport`. So the forwarder check *is* the contract's trust boundary:

```solidity
function onReport(bytes calldata metadata, bytes calldata report) external override {
    if (msg.sender != forwarder) {
        revert UnauthorizedForwarder(msg.sender, forwarder);
    }
    ...
}
```

Supporting properties, all covered by tests:

- **`snapshot` cannot be used to bypass it.** `onReport` routes through
  `this.snapshot(record)` so there is a single write path, and `snapshot` rejects
  any caller other than the contract itself. An EOA — including the owner and the
  forwarder — calling `snapshot` directly reverts.
- **`setForwarder` cannot disable the check.** `address(0)` is rejected, unlike
  Chainlink's `ReceiverTemplate`, where zeroing the field silently makes the
  contract world-writable.
- **ERC-165** is implemented, because the forwarder checks `supportsInterface`
  before delivering.
- **Metadata length.** The production forwarder passes a 64-byte word-aligned
  slice (62 identity bytes plus a 2-byte `reportId`), not 62. Both are accepted; a
  strict `== 62` check would break live delivery.
- **Optional identity checks.** `setExpectedWorkflowOwner` and
  `setExpectedWorkflowName` add defence in depth for a deployed workflow. They are
  off by default and must stay off during simulation, because the
  `MockKeystoneForwarder` supplies no metadata. A name may only be enforced
  together with an owner — 10-byte names are unique per owner, not globally.
- **Replay protection.** A reverted report is not consumed by the forwarder and
  can be resubmitted, so `snapshot` requires each record to be strictly newer than
  the stored one for that token (`StaleSnapshot`).

---

## How `blockNumber` is obtained

> Requirement: *the `blockNumber` stored on-chain must be the block number at which
> the Data Feed answer was last updated.*

This is the one part worth explaining, because it is **not** a view call.

The Sepolia ETH/USD feed is an `AggregatorProxy` in front of
`AccessControlledOffchainAggregator 3.0.0`. `latestRoundData()` returns
`startedAt` and `updatedAt`, both *timestamps*. Enumerating the aggregator's
selectors confirms the only view mentioning a block is
`latestConfigDetails().blockNumber`, which is the block its **config** was set —
not the block of the answer.

What the aggregator does expose is the event:

```solidity
event AnswerUpdated(int256 indexed current, uint256 indexed roundId, uint256 updatedAt);
```

The block of that event, for the current round, is precisely "the block at which
the answer was last updated". The workflow therefore:

1. reads `latestRoundData()`, `decimals()`, `description()` and `aggregator()`
   from the proxy, all at `LAST_FINALIZED_BLOCK_NUMBER` so every DON node observes
   identical state;
2. converts the proxy round id to the aggregator's own — a proxy round id is
   `phaseId << 64 | aggregatorRoundId`, so it masks off the low 64 bits;
3. calls `filterLogs` on the **aggregator** for `AnswerUpdated`, over a window
   sized from how old the answer is
   (`(finalizedTimestamp - updatedAt) / avgBlockTimeSeconds + lookbackMarginBlocks`,
   capped at `maxLookbackBlocks`), bounded above by the finalized block;
4. picks the log whose `roundId` topic equals the aggregator round id, and takes
   its block number.

Matching on the round id is what makes the result exact rather than approximate:
it ties the block to *this* answer. If no such log is found in the estimated
window, the search is retried at the full cap and then fails loudly rather than
storing a guess. The window parameters are config, not constants, so a slower
chain or a slower feed needs no code change.

### Verifying the lookup without CRE

The mechanism can be checked against live Sepolia with `cast` alone, which is
useful for confirming it independently of the CRE runtime:

```bash
RPC=https://ethereum-sepolia-rpc.publicnode.com
FEED=0x694AA1769357215DE4FAC081bf1f309aDC325306
AGG=$(cast call $FEED "aggregator()(address)" --rpc-url $RPC)
FIN=$(cast block finalized --rpc-url $RPC --field number)

# roundId, answer, updatedAt at the finalized block
cast call $FEED "latestRoundData()(uint80,int256,uint256,uint256,uint80)" \
  --block $FIN --rpc-url $RPC

# the aggregator's own round id is the low 64 bits of the proxy's
# then: the AnswerUpdated log carrying that round id
cast logs --from-block $((FIN-320)) --to-block $FIN --address $AGG \
  "$(cast keccak 'AnswerUpdated(int256,uint256,uint256)')" --rpc-url $RPC --json
```

A run at finalized block 11906404 produced:

| Step | Value |
| --- | --- |
| `latestRoundData` | roundId `18446744073709588381`, answer `250782942174`, `updatedAt` 1791898224 |
| Phase mask | phaseId `1`, aggregatorRoundId `36765` |
| Search window | answer 228s old → 319 blocks (11906085..11906404) |
| Matching log | round `36765`, answer `250782942174`, **block 11906385** |

The log's answer equals the one `latestRoundData` returned, which is what
confirms the block belongs to that answer rather than a neighbouring round.

`timestamp` in the `Record` is the feed's `updatedAt` for the same round, not
`block.timestamp` of the write — so a `Record` describes the feed observation,
not the moment it happened to be stored.

---

## Tests

```bash
cd contracts && forge test        # 30 tests: forwarder check, replay, encoding, admin
cd my-workflow && bun test        # 18 tests: config, payload, token allow-list, encoding
cd my-workflow && bunx tsc --noEmit
```

The suites cover the forwarder check from several angles (wrong caller, fuzzed
caller, stale forwarder after an update, direct `snapshot` call), the
62/64-byte metadata handling, replay rejection, and the exact report byte layout.

---

## Deploying the workflow (beyond the assignment)

`cre workflow simulate` is all the assignment requires. To register the workflow
with CRE instead, two changes are needed:

1. **Authorize callers.** A deployed HTTP trigger must list the EVM addresses
   allowed to invoke it; an empty config is simulation-only. In
   `my-workflow/workflow.ts`:

   ```ts
   http.trigger({
     authorizedKeys: [{ type: 'KEY_TYPE_ECDSA_EVM', publicKey: '0xYourAddress' }],
   })
   ```

2. **Point the contract at the production forwarder**, since a deployed workflow
   delivers through `KeystoneForwarder`, not the mock:

   ```bash
   cast send "$CONSUMER" "setForwarder(address)" \
     0xF8344CFd5c43616a4366C34E3EEE75af79a74482 \
     --rpc-url "$ETHEREUM_SEPOLIA_RPC_URL" --private-key "0x$CRE_ETH_PRIVATE_KEY"
   ```

   Then optionally enable `setExpectedWorkflowOwner` / `setExpectedWorkflowName`.

```bash
cre workflow deploy my-workflow --target production-settings
```

---

## Secrets

No real secrets are committed. `.env` is git-ignored; `.env.example` holds the
template. `secrets.yaml` is the secret-name manifest — this workflow needs none
(a public Data Feed and the EVM Write capability), so it ships empty with a
commented example, and `workflow.yaml` leaves `secrets-path` blank.

---

## Notes and limitations

- **Reads use the last finalized block.** Determinism across DON nodes matters
  more here than freshness; a finalized read is ~13 minutes behind head on
  Sepolia, and `maxFeedAgeSeconds` (default 2h) rejects an answer that has gone
  stale beyond that.
- **The feed answer is `int256`, the `Record` is `uint256`.** A non-positive
  answer is rejected rather than cast.
- **No generated bindings.** The workflow uses `callContract` + viem encoding
  directly instead of `cre generate-bindings`, so the repo builds from a clean
  clone with no code-generation step. The trade-off is explicit encode/decode
  calls in `workflow.ts`.
- **Sepolia gas pricing differs sharply from Foundry's local EVM**, and it
  affects both transactions in this project:

  | Operation | Local (Foundry) | Sepolia (measured) | Ratio |
  | --- | --- | --- | --- |
  | `PriceSnapshot` deployment | 1 250 412 | 9 465 772 | 7.6x |
  | `onReport` delivery | 282 605 | 1 369 018 | 4.8x |

  `gasLimit` in the workflow config is therefore **3 000 000**, not the 600 000 a
  local measurement would suggest — at 600 000 the forwarder transaction succeeds
  while `onReport` reverts out of gas, so the snapshot silently never lands.
  Check the real cost before changing it:

  ```bash
  cast estimate --rpc-url "$ETHEREUM_SEPOLIA_RPC_URL" \
    --from 0x15fC6ae953E024d975e77382eEeC56A9101f9F88 "$CONSUMER" \
    "onReport(bytes,bytes)" "$METADATA" "$REPORT"
  ```
- **The log search depends on RPC range limits.** `maxLookbackBlocks` defaults to
  45 000 to stay under the 50 000-block cap of the public Sepolia endpoint in
  `.env.example`. Lower it for stricter providers.

---

## References

- [CRE documentation](https://docs.chain.link/cre)
- [Building consumer contracts](https://docs.chain.link/cre/guides/workflow/using-evm-client/onchain-write/building-consumer-contracts)
- [Forwarder directory](https://docs.chain.link/cre/guides/workflow/using-evm-client/forwarder-directory)
- [Data Feed addresses](https://docs.chain.link/data-feeds/price-feeds/addresses)
- [Sepolia faucet](https://faucets.chain.link/sepolia)
