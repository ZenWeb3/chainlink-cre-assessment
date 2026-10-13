import {
	blockNumber,
	bytesToBigint,
	bytesToHex,
	cre,
	encodeCallMsg,
	getNetwork,
	hexToBase64,
	LAST_FINALIZED_BLOCK_NUMBER,
	prepareReportRequest,
	protoBigIntToBigint,
	TxStatus,
	type EVMLog,
	type HTTPPayload,
	type Runtime,
} from '@chainlink/cre-sdk'
import { EVM_PB } from '@chainlink/cre-sdk/pb'
import {
	decodeFunctionResult,
	encodeAbiParameters,
	encodeFunctionData,
	formatUnits,
	toEventSelector,
	zeroAddress,
	type Address,
	type Hex,
} from 'viem'
import { z } from 'zod'
import { ANSWER_UPDATED_EVENT, dataFeedAbi, snapshotRecordParams } from './abi'

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------

export const configSchema = z.object({
	/** Chain selector name, e.g. "ethereum-testnet-sepolia". */
	chainName: z.string().min(1),
	/** Whether `chainName` is a testnet. Sepolia is. */
	isTestnet: z.boolean().default(true),
	/** Deployed PriceSnapshot consumer contract. */
	consumerAddress: z.string().regex(/^0x[0-9a-fA-F]{40}$/),
	/** Gas limit for the forwarder transaction that delivers the report. */
	gasLimit: z.string().regex(/^\d+$/),
	/**
	 * Allow-list of tokens the workflow will price, mapping an uppercase token
	 * symbol to its Chainlink Data Feed proxy address. Keeping this in config
	 * rather than accepting an arbitrary address from the HTTP body means a
	 * caller cannot point the workflow at a contract of their choosing.
	 */
	feeds: z.record(z.string(), z.string().regex(/^0x[0-9a-fA-F]{40}$/)),
	/**
	 * Reject an answer whose `updatedAt` is older than this. Guards against
	 * writing a stale price if a feed stops updating. 0 disables the check.
	 */
	maxFeedAgeSeconds: z.number().int().nonnegative().default(7200),
	/** Average block time, used to size the `AnswerUpdated` log search window. */
	avgBlockTimeSeconds: z.number().int().positive().default(12),
	/** Extra blocks searched either side of the estimate. */
	lookbackMarginBlocks: z.number().int().nonnegative().default(300),
	/** Hard cap on the log search window. */
	maxLookbackBlocks: z.number().int().positive().default(45000),
})

export type Config = z.infer<typeof configSchema>

/** Body of the HTTP request that triggers the workflow: `{"token":"ETH"}`. */
export const triggerPayloadSchema = z.object({
	token: z.string().min(1).max(32),
})

export type SnapshotRecord = {
	token: string
	price: bigint
	blockNumber: bigint
	timestamp: bigint
}

export type WorkflowResult = {
	token: string
	feed: string
	description: string
	decimals: number
	price: string
	priceFormatted: string
	/** Block at which the Data Feed answer was last updated. */
	blockNumber: string
	/** The feed's `updatedAt` for that answer. */
	timestamp: string
	roundId: string
	consumer: string
	txHash: string
}

type EvmClient = InstanceType<typeof cre.capabilities.EVMClient>

const UINT64_MASK = (1n << 64n) - 1n

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

const evmClientFor = (config: Config): EvmClient => {
	const network = getNetwork({
		chainFamily: 'evm',
		chainSelectorName: config.chainName,
		isTestnet: config.isTestnet,
	})
	if (!network) {
		throw new Error(`Unknown chain selector name: ${config.chainName}`)
	}
	return new cre.capabilities.EVMClient(network.chainSelector.selector)
}

/**
 * Resolves the requested token to a configured Data Feed address.
 * Lookup is case-insensitive, and only tokens present in `config.feeds` are
 * accepted.
 */
export const resolveFeedAddress = (config: Config, token: string): { token: string; feed: Address } => {
	const wanted = token.trim().toUpperCase()
	for (const [symbol, address] of Object.entries(config.feeds)) {
		if (symbol.toUpperCase() === wanted) {
			return { token: symbol.toUpperCase(), feed: address as Address }
		}
	}
	const supported = Object.keys(config.feeds).sort().join(', ')
	throw new Error(`Unsupported token "${token}". Configured feeds: ${supported}`)
}

/** Reads a view function on `address` at the last finalized block. */
const readFeed = <TFunctionName extends string>(
	runtime: Runtime<Config>,
	evmClient: EvmClient,
	address: Address,
	functionName: TFunctionName,
) => {
	const reply = evmClient
		.callContract(runtime, {
			call: encodeCallMsg({
				from: zeroAddress,
				to: address,
				// biome-ignore lint/suspicious/noExplicitAny: viem's generic needs the literal name
				data: encodeFunctionData({ abi: dataFeedAbi, functionName: functionName as any }),
			}),
			// Every node must read the same state for consensus to be reached.
			blockNumber: LAST_FINALIZED_BLOCK_NUMBER,
		})
		.result()

	return decodeFunctionResult({
		abi: dataFeedAbi,
		// biome-ignore lint/suspicious/noExplicitAny: viem's generic needs the literal name
		functionName: functionName as any,
		data: bytesToHex(reply.data),
	})
}

/**
 * Finds the block in which the aggregator last updated to `aggregatorRoundId`.
 *
 * Chainlink's `AccessControlledOffchainAggregator` exposes no view returning the
 * block of an answer — `latestRoundData` only gives timestamps. It does emit
 * `AnswerUpdated(int256 indexed current, uint256 indexed roundId, uint256
 * updatedAt)` though, so the block of that event for the current round is
 * exactly "the block at which the Data Feed answer was last updated".
 *
 * The search window is derived from how old the answer is, so a frequently
 * updating feed costs a small query. Everything is bounded by the last finalized
 * block to keep the result identical across DON nodes.
 */
export const findAnswerUpdatedBlock = (
	runtime: Runtime<Config>,
	evmClient: EvmClient,
	aggregator: Address,
	aggregatorRoundId: bigint,
	updatedAt: bigint,
	finalizedBlock: bigint,
	finalizedTimestamp: bigint,
): bigint => {
	const config = runtime.config
	const topic0 = toEventSelector(ANSWER_UPDATED_EVENT)
	const maxLookback = BigInt(config.maxLookbackBlocks)

	const ageSeconds = finalizedTimestamp > updatedAt ? finalizedTimestamp - updatedAt : 0n
	const estimated =
		ageSeconds / BigInt(config.avgBlockTimeSeconds) + BigInt(config.lookbackMarginBlocks)

	// Try the tight estimate first, then the hard cap before giving up.
	const spans = estimated < maxLookback ? [estimated, maxLookback] : [maxLookback]

	for (const span of spans) {
		const fromBlock = finalizedBlock > span ? finalizedBlock - span : 0n

		const { logs } = evmClient
			.filterLogs(runtime, {
				filterQuery: {
					addresses: [hexToBase64(aggregator)],
					topics: [{ topic: [hexToBase64(topic0)] }],
					fromBlock: blockNumber(fromBlock),
					toBlock: blockNumber(finalizedBlock),
				},
			})
			.result()

		const match = logs.find((log: EVMLog) => roundIdOf(log) === aggregatorRoundId)
		if (match?.blockNumber) {
			const found = protoBigIntToBigint(match.blockNumber)
			runtime.log(
				`AnswerUpdated round=${aggregatorRoundId} found in block ${found} ` +
					`(searched ${fromBlock}..${finalizedBlock}, ${logs.length} logs)`,
			)
			return found
		}
	}

	throw new Error(
		`Could not locate the AnswerUpdated log for round ${aggregatorRoundId} on aggregator ` +
			`${aggregator} within ${maxLookback} blocks of block ${finalizedBlock}`,
	)
}

/** `AnswerUpdated`'s second indexed argument is the aggregator round id. */
const roundIdOf = (log: EVMLog): bigint | undefined =>
	log.topics.length >= 3 ? bytesToBigint(log.topics[2]) : undefined

// ---------------------------------------------------------------------------
// Handler
// ---------------------------------------------------------------------------

export const onHttpTrigger = (runtime: Runtime<Config>, payload: HTTPPayload): WorkflowResult => {
	const config = runtime.config

	// --- 1. Parse and validate the request body ---------------------------
	if (!payload.input || payload.input.length === 0) {
		throw new Error('Request body is required, e.g. {"token":"ETH"}')
	}
	if (config.consumerAddress.toLowerCase() === zeroAddress) {
		throw new Error(
			'consumerAddress is still the zero address — deploy PriceSnapshot and put its ' +
				'address in the workflow config (see the README).',
		)
	}

	const body = triggerPayloadSchema.parse(JSON.parse(new TextDecoder().decode(payload.input)))
	const { token, feed } = resolveFeedAddress(config, body.token)
	runtime.log(`Snapshot requested for ${token} via Data Feed ${feed}`)

	const evmClient = evmClientFor(config)

	// --- 2. Read the Data Feed (EVM Read) ---------------------------------
	const header = evmClient
		.headerByNumber(runtime, { blockNumber: LAST_FINALIZED_BLOCK_NUMBER })
		.result().header
	if (!header?.blockNumber) {
		throw new Error('Could not read the last finalized block header')
	}
	const finalizedBlock = protoBigIntToBigint(header.blockNumber)
	const finalizedTimestamp = header.timestamp

	const decimals = readFeed(runtime, evmClient, feed, 'decimals') as number
	const description = readFeed(runtime, evmClient, feed, 'description') as string
	const aggregator = readFeed(runtime, evmClient, feed, 'aggregator') as Address
	const [roundId, answer, , updatedAt] = readFeed(
		runtime,
		evmClient,
		feed,
		'latestRoundData',
	) as readonly [bigint, bigint, bigint, bigint, bigint]

	if (answer <= 0n) {
		throw new Error(`Data Feed ${feed} returned a non-positive answer: ${answer}`)
	}
	if (updatedAt === 0n) {
		throw new Error(`Data Feed ${feed} returned an incomplete round (updatedAt = 0)`)
	}
	if (config.maxFeedAgeSeconds > 0) {
		const age = finalizedTimestamp > updatedAt ? finalizedTimestamp - updatedAt : 0n
		if (age > BigInt(config.maxFeedAgeSeconds)) {
			throw new Error(
				`Data Feed ${feed} answer is stale: updated ${age}s ago, ` +
					`limit is ${config.maxFeedAgeSeconds}s`,
			)
		}
	}

	runtime.log(
		`${description}: answer=${answer} decimals=${decimals} ` +
			`(${formatUnits(answer, decimals)}) updatedAt=${updatedAt} roundId=${roundId}`,
	)

	// --- 3. Resolve the block at which that answer was last updated -------
	// A proxy round id is `phaseId << 64 | aggregatorRoundId`; the aggregator's
	// own events use the lower 64 bits.
	const aggregatorRoundId = roundId & UINT64_MASK
	const answerBlockNumber = findAnswerUpdatedBlock(
		runtime,
		evmClient,
		aggregator,
		aggregatorRoundId,
		updatedAt,
		finalizedBlock,
		finalizedTimestamp,
	)

	// --- 4. Write the snapshot on-chain (EVM Write) ------------------------
	const record: SnapshotRecord = {
		token,
		price: answer,
		blockNumber: answerBlockNumber,
		timestamp: updatedAt,
	}
	const txHash = writeSnapshot(runtime, evmClient, record)

	return {
		token,
		feed,
		description,
		decimals,
		price: answer.toString(),
		priceFormatted: formatUnits(answer, decimals),
		blockNumber: answerBlockNumber.toString(),
		timestamp: updatedAt.toString(),
		roundId: roundId.toString(),
		consumer: config.consumerAddress,
		txHash,
	}
}

/**
 * Generates a DON-signed report containing `abi.encode(ISnapshot.Record)` and
 * submits it through the EVM Write capability. The capability hands the report
 * to the Chainlink Forwarder, which verifies the signatures and calls
 * `PriceSnapshot.onReport`.
 */
export const writeSnapshot = (
	runtime: Runtime<Config>,
	evmClient: EvmClient,
	record: SnapshotRecord,
): string => {
	const config = runtime.config

	const encodedRecord = encodeAbiParameters(snapshotRecordParams, [record]) as Hex

	const report = runtime.report(prepareReportRequest(encodedRecord)).result()

	const writeResult = evmClient
		.writeReport(runtime, {
			receiver: config.consumerAddress,
			report,
			gasConfig: { gasLimit: config.gasLimit },
		})
		.result()

	const txHash = bytesToHex(writeResult.txHash ?? new Uint8Array(32))
	runtime.log(
		`writeReport: txStatus=${writeResult.txStatus} ` +
			`receiverStatus=${writeResult.receiverContractExecutionStatus} txHash=${txHash}`,
	)

	// The two statuses are independent: the forwarder transaction can succeed
	// while the consumer's onReport reverts inside it, which would otherwise look
	// like a successful run that stored nothing.
	if (writeResult.txStatus !== TxStatus.SUCCESS) {
		throw new Error(
			`Report delivery failed with txStatus ${writeResult.txStatus}: ` +
				`${writeResult.errorMessage || 'no error message'}`,
		)
	}

	if (
		writeResult.receiverContractExecutionStatus ===
		EVM_PB.ReceiverContractExecutionStatus.REVERTED
	) {
		throw new Error(
			`The forwarder transaction succeeded but ${config.consumerAddress}.onReport reverted, ` +
				`so no snapshot was stored (tx ${txHash}). Most likely either a StaleSnapshot — the ` +
				`feed is still on round ${record.blockNumber}, already recorded for ${record.token} — ` +
				`or gasLimit (${config.gasLimit}) is too low for onReport on this chain.`,
		)
	}

	// Deliberately not claiming the snapshot was stored: under the
	// MockKeystoneForwarder used by `cre workflow simulate`,
	// receiverContractExecutionStatus comes back SUCCESS even when onReport
	// reverts, so a successful write here is not proof of a state change.
	// Confirm with getSnapshot() — see the README.
	runtime.log(`Report delivered. https://sepolia.etherscan.io/tx/${txHash}`)
	return txHash
}

// ---------------------------------------------------------------------------
// Workflow definition
// ---------------------------------------------------------------------------

export const initWorkflow = (_config: Config) => {
	const http = new cre.capabilities.HTTPCapability()

	// An empty trigger config is accepted in simulation. A deployed workflow
	// must list `authorizedKeys` — see the README.
	return [cre.handler(http.trigger({}), onHttpTrigger)]
}
