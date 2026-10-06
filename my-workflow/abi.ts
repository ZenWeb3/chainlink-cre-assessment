import { parseAbi, parseAbiParameters } from 'viem'

/// Chainlink Data Feed proxy (`AggregatorV3Interface` plus the proxy extras we
/// need). `aggregator()` returns the underlying aggregator that emits
/// `AnswerUpdated`, and `latestRoundData().roundId` on a proxy is
/// `phaseId << 64 | aggregatorRoundId`.
export const dataFeedAbi = parseAbi([
	'function decimals() view returns (uint8)',
	'function description() view returns (string)',
	'function aggregator() view returns (address)',
	'function latestRoundData() view returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)',
])

/// Emitted by the underlying aggregator every time the feed answer changes. The
/// block of this log is the block at which the answer was last updated — the
/// value the workflow stores in `Record.blockNumber`.
export const ANSWER_UPDATED_EVENT = 'AnswerUpdated(int256,uint256,uint256)' as const

/// Report payload written on-chain: a single `abi.encode(ISnapshot.Record)`
/// tuple, which `PriceSnapshot.onReport` decodes with
/// `abi.decode(report, (Record))`.
export const snapshotRecordParams = parseAbiParameters(
	'(string token, uint256 price, uint256 blockNumber, uint256 timestamp) record',
)
