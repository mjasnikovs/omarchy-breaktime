import {describe, expect, test} from 'bun:test'
import * as M from '../src/Model.mjs'

const MIN = M.MS_PER_MINUTE
const T0 = new Date(2026, 8, 30, 14, 0, 0, 0).getTime()
const INTERVAL = 30 * MIN
const DUE = T0 + INTERVAL

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
        expect(M.start(T0, INTERVAL)).toEqual({deadline: DUE, idleSince: 0, breakStartedAt: 0, snoozes: 0})
    })

    test('tick is quiet before the deadline', () => {
        expect(M.tick(M.start(T0, INTERVAL), T0 + 10 * MIN)).toBeNull()
    })

    test('tick fires at the deadline', () => {
        const s = M.start(T0, INTERVAL)
        expect(M.tick(s, DUE)).toBe('fire')
        expect(M.tick(s, DUE + 2 * MIN)).toBe('fire')
    })

    test('tick restarts when the deadline is long gone (suspend)', () => {
        expect(M.tick(M.start(T0, INTERVAL), DUE + M.STALE_GRACE_MS + 1000)).toBe('restart')
    })

    test('tick is quiet while away', () => {
        expect(M.tick(M.goIdle(M.start(T0, INTERVAL), T0 + 5 * MIN), DUE + MIN)).toBeNull()
    })

    test('tick waits during a break and finishes it after BREAK_MS', () => {
        const onBreak = M.fire(M.start(T0, INTERVAL), DUE)
        expect(M.tick(onBreak, DUE + MIN)).toBeNull()
        expect(M.tick(onBreak, DUE + M.BREAK_MS - 1)).toBeNull()
        expect(M.tick(onBreak, DUE + M.BREAK_MS)).toBe('finish')
        // Even if the user walked away during the break.
        expect(M.tick(M.goIdle(onBreak, DUE + MIN), DUE + M.BREAK_MS)).toBe('finish')
    })

    test('fire marks the break start; due is derived from it', () => {
        const s = M.start(T0, INTERVAL)
        expect(M.isDue(s)).toBe(false)
        const onBreak = M.fire(s, DUE)
        expect(onBreak.breakStartedAt).toBe(DUE)
        expect(onBreak.deadline).toBe(s.deadline)
        expect(M.isDue(onBreak)).toBe(true)
    })

    test('snooze moves the deadline 5 minutes out, ends the break, counts', () => {
        const later = M.snooze(M.fire(M.start(T0, INTERVAL), DUE), DUE)
        expect(later).toEqual({deadline: DUE + M.SNOOZE_MS, idleSince: 0, breakStartedAt: 0, snoozes: 1})
        expect(M.snooze(later, DUE + M.SNOOZE_MS).snoozes).toBe(2)
    })

    test('finishing the break starts a fresh interval', () => {
        const onBreak = M.fire(M.start(T0, INTERVAL), DUE)
        expect(M.finishBreak(onBreak, DUE + M.BREAK_MS, INTERVAL)).toEqual(M.start(DUE + M.BREAK_MS, INTERVAL))
    })

    test('finishing the break keeps "away" if the user left during it', () => {
        const away = M.goIdle(M.fire(M.start(T0, INTERVAL), DUE), DUE + 2 * MIN)
        const after = M.finishBreak(away, DUE + M.BREAK_MS, INTERVAL)
        expect(after.idleSince).toBe(DUE + 2 * MIN)
        expect(M.isDue(after)).toBe(false)
        expect(M.tick(after, DUE + M.BREAK_MS + INTERVAL)).toBeNull()
    })

    test('going idle keeps the deadline; coming back resets', () => {
        const s = M.start(T0, INTERVAL)
        const away = M.goIdle(s, T0 + 10 * MIN)
        expect(away.idleSince).toBe(T0 + 10 * MIN)
        expect(away.deadline).toBe(s.deadline)
        expect(M.goIdle(away, T0 + 11 * MIN).idleSince).toBe(T0 + 10 * MIN)
        expect(M.endIdle(T0 + 20 * MIN, INTERVAL)).toEqual(M.start(T0 + 20 * MIN, INTERVAL))
    })
})

describe('break progress', () => {
    test('starts empty and fills over BREAK_MS', () => {
        expect(M.breakProgress(DUE, DUE)).toBe(0)
        expect(M.breakProgress(DUE, DUE + M.BREAK_MS / 2)).toBe(0.5)
        expect(M.breakProgress(DUE, DUE + M.BREAK_MS)).toBe(1)
        expect(M.breakProgress(DUE, DUE + 2 * M.BREAK_MS)).toBe(1)
    })

    test('remaining counts down to zero', () => {
        expect(M.breakRemainingMs(DUE, DUE)).toBe(M.BREAK_MS)
        expect(M.breakRemainingMs(DUE, DUE + M.BREAK_MS + 1000)).toBe(0)
        expect(M.breakRemainingMs(0, DUE)).toBe(0)
    })

    test('no progress when not on a break', () => {
        expect(M.breakProgress(0, DUE)).toBe(0)
        expect(M.isBreakOver(M.start(T0, INTERVAL), DUE + M.BREAK_MS)).toBe(false)
    })
})

describe('persistence', () => {
    test('state survives a round trip through JSON', () => {
        const s = M.fire(M.start(T0, INTERVAL), DUE)
        expect(M.parseState(M.serializeState(s), DUE, INTERVAL)).toEqual(s)
        const snoozed = M.snooze(s, DUE)
        expect(M.parseState(M.serializeState(snoozed), DUE, INTERVAL)).toEqual(snoozed)
    })

    test('garbage or missing state becomes a fresh start', () => {
        const fresh = M.start(T0, INTERVAL)
        expect(M.parseState('', T0, INTERVAL)).toEqual(fresh)
        expect(M.parseState('{not json', T0, INTERVAL)).toEqual(fresh)
        expect(M.parseState('[]', T0, INTERVAL)).toEqual(fresh)
        expect(M.parseState('{"deadline": "x"}', T0, INTERVAL)).toEqual(fresh)
    })

    test('a deadline from a clock that jumped forward is reset', () => {
        const far = JSON.stringify({deadline: T0 + 10 * 60 * MIN, idleSince: 0, breakStartedAt: 0, snoozes: 0})
        expect(M.parseState(far, T0, INTERVAL)).toEqual(M.start(T0, INTERVAL))
    })

    test('a break start from the future is clamped to now', () => {
        const odd = JSON.stringify({deadline: DUE, idleSince: 0, breakStartedAt: T0 + 5 * MIN, snoozes: 0})
        expect(M.parseState(odd, T0, INTERVAL).breakStartedAt).toBe(T0)
    })
})

describe('readers', () => {
    test('status and text', () => {
        const s = M.start(T0, INTERVAL)
        expect(M.statusOf(s, false)).toBe('off')
        expect(M.statusOf(s, true)).toBe('running')
        expect(M.statusOf(M.fire(s, DUE), true)).toBe('due')
        expect(M.statusOf(M.goIdle(s, T0), true)).toBe('away')
        expect(M.statusText(s, true, T0 + 12 * MIN)).toBe('Next break in 18 min')
        expect(M.statusText(s, true, DUE - 1000)).toBe('Next break in 1 min')
        expect(M.statusText(s, true, DUE)).toBe('Break due now')
        expect(M.statusText(M.fire(s, DUE), true, DUE + 28 * 1000)).toBe('On a break, 4:32 left')
        expect(M.statusText(s, false, T0)).toBe('Off')
    })

    test('formatClock', () => {
        expect(M.formatClock(0)).toBe('0:00')
        expect(M.formatClock(5 * MIN)).toBe('5:00')
        expect(M.formatClock(61 * 1000)).toBe('1:01')
        expect(M.formatClock(500)).toBe('0:01')
    })

    test('remainingMs never goes negative', () => {
        expect(M.remainingMs(M.start(T0, INTERVAL), DUE + MIN)).toBe(0)
    })
})
