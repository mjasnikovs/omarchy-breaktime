// Pure scheduling for the Break Time plugin.
//
// Compiled to Model.mjs at the repo root, which the QML files import. No Qt
// here. Every function returns a fresh object. Nothing is mutated.
//
// The schedule is one absolute timestamp: `deadline`. Every bar instance and
// the popup read the same state file and derive everything from that number.
export const MS_PER_MINUTE = 60000;
export const MIN_INTERVAL_MINUTES = 15;
export const MAX_INTERVAL_MINUTES = 120;
export const DEFAULT_INTERVAL_MINUTES = 30;
/** How long the break itself lasts. The popup shows this as a progress bar. */
export const BREAK_MS = 5 * MS_PER_MINUTE;
/** "Snooze" pushes the reminder this far out. */
export const SNOOZE_MS = 5 * MS_PER_MINUTE;
// No input for this long means the user left the desk. Coming back after
// that starts a fresh interval.
export const IDLE_RESET_SECONDS = 300;
// A deadline overshot by more than this means nobody was here (suspend, shell
// down). Start over instead of firing the moment a laptop lid opens.
export const STALE_GRACE_MS = 5 * MS_PER_MINUTE;
// ---------------------------------------------------------------- settings
function clampInt(value, min, max, fallback) {
    if (value === undefined || value === null || value === '')
        return fallback;
    const n = Number(value);
    if (!isFinite(n))
        return fallback;
    return Math.max(min, Math.min(max, Math.round(n)));
}
export function intervalMinutes(raw) {
    return clampInt(raw, MIN_INTERVAL_MINUTES, MAX_INTERVAL_MINUTES, DEFAULT_INTERVAL_MINUTES);
}
export function boolSetting(raw, fallback) {
    if (raw === undefined || raw === null)
        return fallback;
    if (typeof raw === 'boolean')
        return raw;
    const text = String(raw).toLowerCase();
    if (text === 'true' || text === '1' || text === 'yes' || text === 'on')
        return true;
    if (text === 'false' || text === '0' || text === 'no' || text === 'off')
        return false;
    return fallback;
}
// ------------------------------------------------------------------- state
function sanitizeTime(value, fallback) {
    const n = Number(value);
    return isFinite(n) && n > 0 ? n : fallback;
}
export function start(now, intervalMs) {
    return { deadline: now + intervalMs, idleSince: 0, due: false, breakStartedAt: 0, snoozes: 0 };
}
export function defaultState(now, intervalMs) {
    return start(now, intervalMs);
}
function safeJsonParse(text) {
    try {
        return JSON.parse(String(text === undefined || text === null ? '' : text));
    }
    catch (_a) {
        return null;
    }
}
export function parseState(text, now, intervalMs) {
    return normalizeState(safeJsonParse(text), now, intervalMs);
}
export function normalizeState(raw, now, intervalMs) {
    if (!raw || typeof raw !== 'object' || Array.isArray(raw))
        return defaultState(now, intervalMs);
    const record = raw;
    const deadline = sanitizeTime(record.deadline, 0);
    // A deadline far in the future is a clock that moved. Start over.
    if (deadline === 0 || deadline > now + MAX_INTERVAL_MINUTES * MS_PER_MINUTE + MS_PER_MINUTE)
        return defaultState(now, intervalMs);
    let idleSince = sanitizeTime(record.idleSince, 0);
    if (idleSince > now + MS_PER_MINUTE)
        idleSince = 0;
    const due = record.due === true;
    let breakStartedAt = due ? sanitizeTime(record.breakStartedAt, now) : 0;
    if (breakStartedAt > now + MS_PER_MINUTE)
        breakStartedAt = now;
    let snoozes = Number(record.snoozes);
    if (!isFinite(snoozes) || snoozes < 0)
        snoozes = 0;
    return {
        deadline,
        idleSince,
        due,
        breakStartedAt,
        snoozes: Math.floor(snoozes)
    };
}
export function serializeState(state) {
    return JSON.stringify({
        deadline: state.deadline,
        idleSince: state.idleSince,
        due: state.due,
        breakStartedAt: state.breakStartedAt,
        snoozes: state.snoozes
    });
}
// ------------------------------------------------------------- transitions
/** The popup went up. The break clock starts now. */
export function fire(state, now) {
    return Object.assign(Object.assign({}, state), { due: true, breakStartedAt: now });
}
/** "Not now." The reminder comes back in SNOOZE_MS. */
export function snooze(state, now) {
    return { deadline: now + SNOOZE_MS, idleSince: 0, due: false, breakStartedAt: 0, snoozes: state.snoozes + 1 };
}
/** The break ran its course. A fresh interval begins. */
export function finishBreak(now, intervalMs) {
    return start(now, intervalMs);
}
/** Take the popup down without judging the break (the plugin was turned off). */
export function cancelBreak(state) {
    return Object.assign(Object.assign({}, state), { due: false, breakStartedAt: 0 });
}
export function goIdle(state, now) {
    if (state.idleSince > 0)
        return state;
    return Object.assign(Object.assign({}, state), { idleSince: now });
}
/**
 * The idle monitor only reports idle after IDLE_RESET_SECONDS, so being idle
 * at all already means "away long enough". Coming back is a fresh start.
 */
export function endIdle(_state, now, intervalMs) {
    return start(now, intervalMs);
}
/**
 * What the once-a-second tick should do.
 *   "fire"     the deadline passed and the user is here
 *   "restart"  the deadline passed long ago; nobody was here
 *   null       nothing to do
 */
export function tick(state, now) {
    if (state.due)
        return null;
    if (state.idleSince > 0)
        return null;
    if (now < state.deadline)
        return null;
    if (now - state.deadline > STALE_GRACE_MS)
        return 'restart';
    return 'fire';
}
// ------------------------------------------------------------------ readers
export function remainingMs(state, now) {
    return Math.max(0, state.deadline - now);
}
export function breakElapsedMs(state, now) {
    if (!state.due || state.breakStartedAt <= 0)
        return 0;
    return Math.max(0, now - state.breakStartedAt);
}
export function breakRemainingMs(state, now) {
    return Math.max(0, BREAK_MS - breakElapsedMs(state, now));
}
/** 0 at the start of the break, 1 when it is over. */
export function breakProgress(state, now) {
    return Math.min(1, breakElapsedMs(state, now) / BREAK_MS);
}
export function isBreakOver(state, now) {
    return state.due && breakElapsedMs(state, now) >= BREAK_MS;
}
export function statusOf(state, enabled) {
    if (!enabled)
        return 'off';
    if (state.due)
        return 'due';
    if (state.idleSince > 0)
        return 'away';
    return 'running';
}
export function formatMinutes(ms) {
    const minutes = Math.ceil(ms / MS_PER_MINUTE);
    if (minutes <= 0)
        return 'now';
    if (minutes === 1)
        return '1 min';
    return `${minutes} min`;
}
/** "4:32" */
export function formatClock(ms) {
    const totalSeconds = Math.max(0, Math.ceil(ms / 1000));
    const minutes = Math.floor(totalSeconds / 60);
    const seconds = totalSeconds % 60;
    return `${minutes}:${seconds < 10 ? '0' : ''}${seconds}`;
}
export function statusText(state, enabled, now) {
    const status = statusOf(state, enabled);
    if (status === 'off')
        return 'Off';
    if (status === 'due')
        return `On a break, ${formatClock(breakRemainingMs(state, now))} left`;
    if (status === 'away')
        return 'Away from the desk';
    return `Next break in ${formatMinutes(remainingMs(state, now))}`;
}
export function tooltipFor(state, enabled, interval, now) {
    return `Break Time: ${statusText(state, enabled, now)} (every ${interval} min)`;
}
