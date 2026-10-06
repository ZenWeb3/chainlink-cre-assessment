import { describe, expect } from 'bun:test'
import { newTestRuntime, test } from '@chainlink/cre-sdk/test'
import { decodeAbiParameters, encodeAbiParameters, toEventSelector } from 'viem'
import { ANSWER_UPDATED_EVENT, snapshotRecordParams } from './abi'
import {
	configSchema,
	initWorkflow,
	onHttpTrigger,
	resolveFeedAddress,
	triggerPayloadSchema,
	type Config,
} from './workflow'

const ETH_FEED = '0x694AA1769357215DE4FAC081bf1f309aDC325306'
const BTC_FEED = '0x1b44F3514812d835EB1BDB0acB33d3fA3351Ee43'

const baseConfig = (): Config =>
	configSchema.parse({
		chainName: 'ethereum-testnet-sepolia',
		isTestnet: true,
		consumerAddress: '0x1111111111111111111111111111111111111111',
		gasLimit: '600000',
		feeds: { ETH: ETH_FEED, BTC: BTC_FEED },
	})

describe('configSchema', () => {
	test('applies defaults for the optional tuning fields', () => {
		const config = baseConfig()
		expect(config.maxFeedAgeSeconds).toBe(7200)
		expect(config.avgBlockTimeSeconds).toBe(12)
		expect(config.lookbackMarginBlocks).toBe(300)
		expect(config.maxLookbackBlocks).toBe(45000)
		expect(config.isTestnet).toBe(true)
	})

	test('rejects a malformed consumer address', () => {
		expect(() => configSchema.parse({ ...baseConfig(), consumerAddress: '0xnope' })).toThrow()
	})

	test('rejects a malformed feed address', () => {
		expect(() => configSchema.parse({ ...baseConfig(), feeds: { ETH: 'not-an-address' } })).toThrow()
	})

	test('rejects a non-numeric gas limit', () => {
		expect(() => configSchema.parse({ ...baseConfig(), gasLimit: 'lots' })).toThrow()
	})

	test('parses the committed staging config', async () => {
		const raw = await Bun.file(`${import.meta.dir}/config.staging.json`).json()
		const config = configSchema.parse(raw)
		expect(config.chainName).toBe('ethereum-testnet-sepolia')
		expect(Object.keys(config.feeds)).toContain('ETH')
	})
})

describe('triggerPayloadSchema', () => {
	test('accepts the documented body', () => {
		expect(triggerPayloadSchema.parse({ token: 'ETH' })).toEqual({ token: 'ETH' })
	})

	test('rejects a missing or empty token', () => {
		expect(() => triggerPayloadSchema.parse({})).toThrow()
		expect(() => triggerPayloadSchema.parse({ token: '' })).toThrow()
	})
})

describe('resolveFeedAddress', () => {
	test('resolves a configured token', () => {
		expect(resolveFeedAddress(baseConfig(), 'ETH')).toEqual({ token: 'ETH', feed: ETH_FEED })
	})

	test('is case- and whitespace-insensitive', () => {
		expect(resolveFeedAddress(baseConfig(), ' eth ')).toEqual({ token: 'ETH', feed: ETH_FEED })
		expect(resolveFeedAddress(baseConfig(), 'bTc')).toEqual({ token: 'BTC', feed: BTC_FEED })
	})

	test('rejects a token that is not in the allow-list, listing what is', () => {
		expect(() => resolveFeedAddress(baseConfig(), 'DOGE')).toThrow(
			/Unsupported token "DOGE". Configured feeds: BTC, ETH/,
		)
	})

	test('does not accept a raw address as a token', () => {
		expect(() => resolveFeedAddress(baseConfig(), ETH_FEED)).toThrow(/Unsupported token/)
	})
})

describe('onHttpTrigger', () => {
	test('rejects an empty request body', () => {
		const runtime = newTestRuntime<Config>(null, undefined, baseConfig())

		expect(() => onHttpTrigger(runtime, { input: new Uint8Array(0) } as never)).toThrow(
			/Request body is required/,
		)
	})

	test('rejects a body that is not valid JSON', () => {
		const runtime = newTestRuntime<Config>(null, undefined, baseConfig())

		expect(() =>
			onHttpTrigger(runtime, { input: new TextEncoder().encode('not json') } as never),
		).toThrow()
	})

	test('rejects an unconfigured token before touching the chain', () => {
		const runtime = newTestRuntime<Config>(null, undefined, baseConfig())

		expect(() =>
			onHttpTrigger(runtime, {
				input: new TextEncoder().encode(JSON.stringify({ token: 'DOGE' })),
			} as never),
		).toThrow(/Unsupported token "DOGE"/)
	})
})

describe('onHttpTrigger consumer guard', () => {
	test('refuses to run while consumerAddress is the zero placeholder', () => {
		const config = configSchema.parse({
			...baseConfig(),
			consumerAddress: '0x0000000000000000000000000000000000000000',
		})
		const runtime = newTestRuntime<Config>(null, undefined, config)

		expect(() =>
			onHttpTrigger(runtime, {
				input: new TextEncoder().encode(JSON.stringify({ token: 'ETH' })),
			} as never),
		).toThrow(/consumerAddress is still the zero address/)
	})
})

describe('initWorkflow', () => {
	test('registers a single HTTP trigger handler', () => {
		const handlers = initWorkflow(baseConfig())
		expect(handlers).toHaveLength(1)
		expect(handlers[0].fn).toBe(onHttpTrigger)
	})
})

describe('report payload', () => {
	test('round-trips a Record through the tuple encoding onReport decodes', () => {
		const record = {
			token: 'ETH',
			price: 269574660667n,
			blockNumber: 11857693n,
			timestamp: 1791312240n,
		}

		const encoded = encodeAbiParameters(snapshotRecordParams, [record])

		// A single dynamic tuple: an outer offset word, then the tuple body.
		expect(encoded.slice(0, 66)).toBe(
			'0x0000000000000000000000000000000000000000000000000000000000000020',
		)

		const [decoded] = decodeAbiParameters(snapshotRecordParams, encoded)
		expect(decoded).toEqual(record)
	})
})

describe('AnswerUpdated event', () => {
	test('matches the topic the Sepolia aggregator actually emits', () => {
		expect(toEventSelector(ANSWER_UPDATED_EVENT)).toBe(
			'0x0559884fd3a460db3073b7fc896cc77986f16e378210ded43186175bf646fc5f',
		)
	})
})
