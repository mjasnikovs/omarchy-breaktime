import {describe, expect, test} from 'bun:test'
import * as M from '../src/Model.mjs'

const MIN = M.MS_PER_MINUTE
const T0 = new Date(2026, 8, 30, 14, 0, 0, 0).getTime()
const INTERVAL = 30 * MIN

describe('settings', () => {
    test('interval is clamped to 15..120 with default 30', () => {
        expect(M.intervalMinutes(undefined)).toBe(30)
        expect(M.intervalMinutes('garbage')).toBe(30)
        expect(M.intervalMinutes(0)).toBe(15)
        expect(M.intervalMinutes(45)).toBe(45)
        expect(M.intervalMinutes(999)).toBe(120)
        expect(M.intervalMinutes('60')).toBe(60)
    })

    test('boolSetting reads strings and booleans', () => {
        expect(M.boolSetting(undefined, true)).toBe(true)
        expect(M.boolSetting(false, true)).toBe(false)
        expect(M.boolSetting('false', true)).toBe(false)
        expect(M.boolSetting('on', false)).toBe(true)
    })
})

describe('schedule', () => {
    test('start sets a deadline one interval ahead', () => {
        expect(M.start(T0, INTERVAL)).toEqual({deadline: T0 + INTERVAL, idleSince: 0, due: false, snoozes: 0})
    })

    test('tick is quiet before the deadline', () => {
        expect(M.tick(M.start(T0, INTERVAL), T0 + 10 * MIN)).toBeNull()
    })

    test('tick fires at the deadline', () => {
        const s = M.start(T0, INTERVAL)
        expect(M.tick(s, T0 + INTERVAL)).toBe('fire')
        expect(M.tick(s, T0 + INTERVAL + 2 * MIN)).toBe('fire')
    })

    test('tick restarts when the deadline is long gone (suspend)', () => {
        expect(M.tick(M.start(T0, INTERVAL), T0 + INTERVAL + M.STALE_GRACE_MS + 1000)).toBe('restart')
    })

    test('tick is quiet while due or away', () => {
        const s = M.start(T0, INTERVAL)
        expect(M.tick(M.fire(s), T0 + INTERVAL + MIN)).toBeNull()
        expect(M.tick(M.goIdle(s, T0 + 5 * MIN), T0 + INTERVAL + MIN)).toBeNull()
    })

    test('snooze moves the deadline 5 minutes out and counts', () => {
        const later = M.snooze(M.fire(M.start(T0, INTERVAL)), T0 + INTERVAL)
        expect(later).toEqual({deadline: T0 + INTERVAL + M.SNOOZE_MS, idleSince: 0, due: false, snoozes: 1})
        expect(M.snooze(later, T0 + INTERVAL + M.SNOOZE_MS).snoozes).toBe(2)
    })

    test('done starts a fresh interval', () => {
        expect(M.done(T0 + INTERVAL, INTERVAL)).toEqual({
            deadline: T0 + 2 * INTERVAL,
            idleSince: 0,
            due: false,
            snoozes: 0
        })
    })

    test('going idle keeps the deadline; coming back resets', () => {
        const s = M.start(T0, INTERVAL)
        const away = M.goIdle(s, T0 + 10 * MIN)
        expect(away.idleSince).toBe(T0 + 10 * MIN)
        expect(away.deadline).toBe(s.deadline)
        expect(M.goIdle(away, T0 + 11 * MIN).idleSince).toBe(T0 + 10 * MIN)
        const back = M.endIdle(away, T0 + 20 * MIN, INTERVAL)
        expect(back.deadline).toBe(T0 + 20 * MIN + INTERVAL)
        expect(back.idleSince).toBe(0)
    })

    test('coming back while the popup is due clears it', () => {
        const s = M.goIdle(M.fire(M.start(T0, INTERVAL)), T0 + INTERVAL + MIN)
        expect(M.endIdle(s, T0 + INTERVAL + 10 * MIN, INTERVAL).due).toBe(false)
    })
})

describe('persistence', () => {
    test('state survives a round trip through JSON', () => {
        const s = M.snooze(M.fire(M.start(T0, INTERVAL)), T0 + INTERVAL)
        expect(M.parseState(M.serializeState(s), T0 + INTERVAL, INTERVAL)).toEqual(s)
    })

    test('garbage or missing state becomes a fresh start', () => {
        const fresh = M.start(T0, INTERVAL)
        expect(M.parseState('', T0, INTERVAL)).toEqual(fresh)
        expect(M.parseState('{not json', T0, INTERVAL)).toEqual(fresh)
        expect(M.parseState('[]', T0, INTERVAL)).toEqual(fresh)
        expect(M.parseState('{"deadline": "x"}', T0, INTERVAL)).toEqual(fresh)
    })

    test('a deadline from a clock that jumped forward is reset', () => {
        const far = JSON.stringify({deadline: T0 + 10 * 60 * MIN, due: false, idleSince: 0, snoozes: 0})
        expect(M.parseState(far, T0, INTERVAL)).toEqual(M.start(T0, INTERVAL))
    })
})

describe('readers', () => {
    test('status and text', () => {
        const s = M.start(T0, INTERVAL)
        expect(M.statusOf(s, false)).toBe('off')
        expect(M.statusOf(s, true)).toBe('running')
        expect(M.statusOf(M.fire(s), true)).toBe('due')
        expect(M.statusOf(M.goIdle(s, T0), true)).toBe('away')
        expect(M.statusText(s, true, T0 + 12 * MIN)).toBe('Next break in 18 min')
        expect(M.statusText(s, true, T0 + INTERVAL - 1000)).toBe('Next break in 1 min')
        expect(M.statusText(s, true, T0 + INTERVAL)).toBe('Next break in now')
        expect(M.statusText(s, false, T0)).toBe('Off')
    })

    test('remainingMs never goes negative', () => {
        expect(M.remainingMs(M.start(T0, INTERVAL), T0 + INTERVAL + MIN)).toBe(0)
    })
})
