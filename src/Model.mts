// Pure scheduling for the Break Time plugin.
//
// Compiled to Model.mjs at the repo root, which the QML files import. No Qt
// here. Every function returns a fresh object. Nothing is mutated.
//
// The schedule is one absolute timestamp: `deadline`. Every bar instance and
// the popup read the same state file and derive everything from that number.

export const MS_PER_MINUTE = 60000

export const MIN_INTERVAL_MINUTES = 15
export const MAX_INTERVAL_MINUTES = 120
export const DEFAULT_INTERVAL_MINUTES = 30

export const SNOOZE_MS = 5 * MS_PER_MINUTE

// No input for this long means the user left the desk. Coming back after
// that starts a fresh interval.
export const IDLE_RESET_SECONDS = 300

// A deadline overshot by more than this means nobody was here (suspend, shell
// down). Start over instead of firing the moment a laptop lid opens.
export const STALE_GRACE_MS = 5 * MS_PER_MINUTE

export interface BreakState {
    /** Epoch ms the next reminder is due. */
    deadline: number
    /** Epoch ms the user went away, or 0 while active. */
    idleSince: number
    /** True while the popup is up and unanswered. */
    due: boolean
    /** How many times the current reminder was snoozed. */
    snoozes: number
}

export type TickAction = 'fire' | 'restart' | null
export type Status = 'off' | 'due' | 'away' | 'running'

// ---------------------------------------------------------------- settings

function clampInt(value: unknown, min: number, max: number, fallback: number): number {
    if (value === undefined || value === null || value === '') return fallback
    const n = Number(value)
    if (!isFinite(n)) return fallback
    return Math.max(min, Math.min(max, Math.round(n)))
}

export function intervalMinutes(raw: unknown): number {
    return clampInt(raw, MIN_INTERVAL_MINUTES, MAX_INTERVAL_MINUTES, DEFAULT_INTERVAL_MINUTES)
}

export function boolSetting(raw: unknown, fallback: boolean): boolean {
    if (raw === undefined || raw === null) return fallback
    if (typeof raw === 'boolean') return raw
    const text = String(raw).toLowerCase()
    if (text === 'true' || text === '1' || text === 'yes' || text === 'on') return true
    if (text === 'false' || text === '0' || text === 'no' || text === 'off') return false
    return fallback
}

// ------------------------------------------------------------------- state

function sanitizeTime(value: unknown, fallback: number): number {
    const n = Number(value)
    return isFinite(n) && n > 0 ? n : fallback
}

export function start(now: number, intervalMs: number): BreakState {
    return {deadline: now + intervalMs, idleSince: 0, due: false, snoozes: 0}
}

export function defaultState(now: number, intervalMs: number): BreakState {
    return start(now, intervalMs)
}

function safeJsonParse(text: unknown): unknown {
    try {
        return JSON.parse(String(text === undefined || text === null ? '' : text))
    } catch {
        return null
    }
}

export function parseState(text: unknown, now: number, intervalMs: number): BreakState {
    return normalizeState(safeJsonParse(text), now, intervalMs)
}

export function normalizeState(raw: unknown, now: number, intervalMs: number): BreakState {
    if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return defaultState(now, intervalMs)
    const record = raw as Record<string, unknown>

    const deadline = sanitizeTime(record.deadline, 0)
    // A deadline far in the future is a clock that moved. Start over.
    if (deadline === 0 || deadline > now + MAX_INTERVAL_MINUTES * MS_PER_MINUTE + MS_PER_MINUTE)
        return defaultState(now, intervalMs)

    let idleSince = sanitizeTime(record.idleSince, 0)
    if (idleSince > now + MS_PER_MINUTE) idleSince = 0

    let snoozes = Number(record.snoozes)
    if (!isFinite(snoozes) || snoozes < 0) snoozes = 0

    return {
        deadline,
        idleSince,
        due: record.due === true,
        snoozes: Math.floor(snoozes)
    }
}

export function serializeState(state: BreakState): string {
    return JSON.stringify({
        deadline: state.deadline,
        idleSince: state.idleSince,
        due: state.due,
        snoozes: state.snoozes
    })
}

// ------------------------------------------------------------- transitions

/** The popup went up. */
export function fire(state: BreakState): BreakState {
    return {...state, due: true}
}

export function snooze(state: BreakState, now: number): BreakState {
    return {deadline: now + SNOOZE_MS, idleSince: 0, due: false, snoozes: state.snoozes + 1}
}

/** "Done" on the popup, or a manual reset. Same thing: a fresh interval. */
export function done(now: number, intervalMs: number): BreakState {
    return start(now, intervalMs)
}

export function goIdle(state: BreakState, now: number): BreakState {
    if (state.idleSince > 0) return state
    return {...state, idleSince: now}
}

/**
 * The idle monitor only reports idle after IDLE_RESET_SECONDS, so being idle
 * at all already means "away long enough". Coming back is a fresh start.
 */
export function endIdle(_state: BreakState, now: number, intervalMs: number): BreakState {
    return start(now, intervalMs)
}

/**
 * What the once-a-second tick should do.
 *   "fire"     the deadline passed and the user is here
 *   "restart"  the deadline passed long ago; nobody was here
 *   null       nothing to do
 */
export function tick(state: BreakState, now: number): TickAction {
    if (state.due) return null
    if (state.idleSince > 0) return null
    if (now < state.deadline) return null
    if (now - state.deadline > STALE_GRACE_MS) return 'restart'
    return 'fire'
}

// ------------------------------------------------------------------ readers

export function remainingMs(state: BreakState, now: number): number {
    return Math.max(0, state.deadline - now)
}

export function statusOf(state: BreakState, enabled: boolean): Status {
    if (!enabled) return 'off'
    if (state.due) return 'due'
    if (state.idleSince > 0) return 'away'
    return 'running'
}

export function formatMinutes(ms: number): string {
    const minutes = Math.ceil(ms / MS_PER_MINUTE)
    if (minutes <= 0) return 'now'
    if (minutes === 1) return '1 min'
    return `${minutes} min`
}

export function statusText(state: BreakState, enabled: boolean, now: number): string {
    const status = statusOf(state, enabled)
    if (status === 'off') return 'Off'
    if (status === 'due') return 'Break is due'
    if (status === 'away') return 'Away from the desk'
    return `Next break in ${formatMinutes(remainingMs(state, now))}`
}

export function tooltipFor(state: BreakState, enabled: boolean, interval: number, now: number): string {
    return `Break Time: ${statusText(state, enabled, now)} (every ${interval} min)`
}
