// Pure scheduling for the Break Time plugin.
//
// No Qt here. `node test/model-test.js` runs this file as-is.
// Every function returns a fresh object. Nothing is mutated.
//
// The schedule is one absolute timestamp: `deadline`. Every bar instance and
// the popup read the same state file and derive everything from that number.

var MS_PER_MINUTE = 60000

var MIN_INTERVAL_MINUTES = 15
var MAX_INTERVAL_MINUTES = 120
var DEFAULT_INTERVAL_MINUTES = 30

var SNOOZE_MS = 5 * MS_PER_MINUTE

// No input for this long means the user left the desk. Coming back after
// that starts a fresh interval.
var IDLE_RESET_SECONDS = 300

// A deadline overshot by more than this means nobody was here (suspend, shell
// down). Start over instead of firing the moment a laptop lid opens.
var STALE_GRACE_MS = 5 * MS_PER_MINUTE

// ---------------------------------------------------------------- settings

function clampInt(value, min, max, fallback) {
  if (value === undefined || value === null || value === "") return fallback
  var n = Number(value)
  if (!isFinite(n)) return fallback
  return Math.max(min, Math.min(max, Math.round(n)))
}

function intervalMinutes(raw) {
  return clampInt(raw, MIN_INTERVAL_MINUTES, MAX_INTERVAL_MINUTES, DEFAULT_INTERVAL_MINUTES)
}

function boolSetting(raw, fallback) {
  if (raw === undefined || raw === null) return fallback === true
  if (typeof raw === "boolean") return raw
  var text = String(raw).toLowerCase()
  if (text === "true" || text === "1" || text === "yes" || text === "on") return true
  if (text === "false" || text === "0" || text === "no" || text === "off") return false
  return fallback === true
}

// ------------------------------------------------------------------- state
//
//   deadline   epoch ms the next reminder is due
//   idleSince  epoch ms the user went away, or 0 while active
//   due        true while the popup is up and unanswered
//   snoozes    how many times the current reminder was snoozed

function sanitizeTime(value, fallback) {
  var n = Number(value)
  return isFinite(n) && n > 0 ? n : fallback
}

function start(now, intervalMs) {
  return { deadline: now + intervalMs, idleSince: 0, due: false, snoozes: 0 }
}

function defaultState(now, intervalMs) {
  return start(now, intervalMs)
}

function parseState(text, now, intervalMs) {
  var raw = null
  try {
    raw = JSON.parse(String(text === undefined || text === null ? "" : text))
  } catch (e) {
    raw = null
  }
  return normalizeState(raw, now, intervalMs)
}

function normalizeState(raw, now, intervalMs) {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return defaultState(now, intervalMs)

  var deadline = sanitizeTime(raw.deadline, 0)
  // A deadline far in the future is a clock that moved. Start over.
  if (deadline === 0 || deadline > now + MAX_INTERVAL_MINUTES * MS_PER_MINUTE + MS_PER_MINUTE)
    return defaultState(now, intervalMs)

  var idleSince = sanitizeTime(raw.idleSince, 0)
  if (idleSince > now + MS_PER_MINUTE) idleSince = 0

  var snoozes = Number(raw.snoozes)
  if (!isFinite(snoozes) || snoozes < 0) snoozes = 0

  return {
    deadline: deadline,
    idleSince: idleSince,
    due: raw.due === true,
    snoozes: Math.floor(snoozes)
  }
}

function serializeState(state) {
  return JSON.stringify({
    deadline: state.deadline,
    idleSince: state.idleSince,
    due: state.due,
    snoozes: state.snoozes
  })
}

// ------------------------------------------------------------- transitions

// The popup went up.
function fire(state) {
  return { deadline: state.deadline, idleSince: state.idleSince, due: true, snoozes: state.snoozes }
}

function snooze(state, now) {
  return { deadline: now + SNOOZE_MS, idleSince: 0, due: false, snoozes: state.snoozes + 1 }
}

// "Done" on the popup, or a manual reset. Same thing: a fresh interval.
function done(now, intervalMs) {
  return start(now, intervalMs)
}

function goIdle(state, now) {
  if (state.idleSince > 0) return state
  return { deadline: state.deadline, idleSince: now, due: state.due, snoozes: state.snoozes }
}

// The idle monitor only reports idle after IDLE_RESET_SECONDS, so being idle
// at all already means "away long enough". Coming back is a fresh start.
function endIdle(state, now, intervalMs) {
  return start(now, intervalMs)
}

// What the once-a-second tick should do. Returns:
//   "fire"     the deadline passed and the user is here
//   "restart"  the deadline passed long ago; nobody was here
//   null       nothing to do
function tick(state, now) {
  if (state.due) return null
  if (state.idleSince > 0) return null
  if (now < state.deadline) return null
  if (now - state.deadline > STALE_GRACE_MS) return "restart"
  return "fire"
}

// ------------------------------------------------------------------ readers

function remainingMs(state, now) {
  return Math.max(0, state.deadline - now)
}

function statusOf(state, enabled, now) {
  if (!enabled) return "off"
  if (state.due) return "due"
  if (state.idleSince > 0) return "away"
  return "running"
}

function formatMinutes(ms) {
  var minutes = Math.ceil(ms / MS_PER_MINUTE)
  if (minutes <= 0) return "now"
  if (minutes === 1) return "1 min"
  return minutes + " min"
}

function statusText(state, enabled, now) {
  var status = statusOf(state, enabled, now)
  if (status === "off") return "Off"
  if (status === "due") return "Break is due"
  if (status === "away") return "Away from the desk"
  return "Next break in " + formatMinutes(remainingMs(state, now))
}

function tooltipFor(state, enabled, intervalMinutes, now) {
  return "Break Time: " + statusText(state, enabled, now) + " (every " + intervalMinutes + " min)"
}

if (typeof module !== "undefined") {
  module.exports = {
    MS_PER_MINUTE: MS_PER_MINUTE,
    MIN_INTERVAL_MINUTES: MIN_INTERVAL_MINUTES,
    MAX_INTERVAL_MINUTES: MAX_INTERVAL_MINUTES,
    DEFAULT_INTERVAL_MINUTES: DEFAULT_INTERVAL_MINUTES,
    SNOOZE_MS: SNOOZE_MS,
    IDLE_RESET_SECONDS: IDLE_RESET_SECONDS,
    STALE_GRACE_MS: STALE_GRACE_MS,
    intervalMinutes: intervalMinutes,
    boolSetting: boolSetting,
    start: start,
    defaultState: defaultState,
    parseState: parseState,
    normalizeState: normalizeState,
    serializeState: serializeState,
    fire: fire,
    snooze: snooze,
    done: done,
    goIdle: goIdle,
    endIdle: endIdle,
    tick: tick,
    remainingMs: remainingMs,
    statusOf: statusOf,
    formatMinutes: formatMinutes,
    statusText: statusText,
    tooltipFor: tooltipFor
  }
}
