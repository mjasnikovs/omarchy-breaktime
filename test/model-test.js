// Run with: node test/model-test.js
const M = require("../Model.js")

let passed = 0
const failures = []

function check(name, fn) {
  try {
    fn()
    passed++
  } catch (e) {
    failures.push(name + "\n    " + e.message)
  }
}

function eq(actual, expected, what) {
  const a = JSON.stringify(actual)
  const b = JSON.stringify(expected)
  if (a !== b) throw new Error((what || "value") + ": expected " + b + ", got " + a)
}

const MIN = M.MS_PER_MINUTE
const T0 = new Date(2026, 8, 30, 14, 0, 0, 0).getTime()
const INTERVAL = 30 * MIN

check("interval is clamped to 15..120 with default 30", () => {
  eq(M.intervalMinutes(undefined), 30)
  eq(M.intervalMinutes("garbage"), 30)
  eq(M.intervalMinutes(0), 15)
  eq(M.intervalMinutes(45), 45)
  eq(M.intervalMinutes(999), 120)
  eq(M.intervalMinutes("60"), 60)
})

check("boolSetting reads strings and booleans", () => {
  eq(M.boolSetting(undefined, true), true)
  eq(M.boolSetting(false, true), false)
  eq(M.boolSetting("false", true), false)
  eq(M.boolSetting("on", false), true)
})

check("start sets a deadline one interval ahead", () => {
  const s = M.start(T0, INTERVAL)
  eq(s.deadline, T0 + INTERVAL)
  eq(s.due, false)
  eq(s.idleSince, 0)
  eq(s.snoozes, 0)
})

check("tick is quiet before the deadline", () => {
  const s = M.start(T0, INTERVAL)
  eq(M.tick(s, T0 + 10 * MIN), null)
})

check("tick fires at the deadline", () => {
  const s = M.start(T0, INTERVAL)
  eq(M.tick(s, T0 + INTERVAL), "fire")
  eq(M.tick(s, T0 + INTERVAL + 2 * MIN), "fire")
})

check("tick restarts when the deadline is long gone (suspend)", () => {
  const s = M.start(T0, INTERVAL)
  eq(M.tick(s, T0 + INTERVAL + M.STALE_GRACE_MS + 1000), "restart")
})

check("tick is quiet while due or away", () => {
  const s = M.start(T0, INTERVAL)
  eq(M.tick(M.fire(s), T0 + INTERVAL + MIN), null)
  eq(M.tick(M.goIdle(s, T0 + 5 * MIN), T0 + INTERVAL + MIN), null)
})

check("snooze moves the deadline 5 minutes out and counts", () => {
  const s = M.fire(M.start(T0, INTERVAL))
  const later = M.snooze(s, T0 + INTERVAL)
  eq(later.deadline, T0 + INTERVAL + M.SNOOZE_MS)
  eq(later.due, false)
  eq(later.snoozes, 1)
  eq(M.snooze(later, T0 + INTERVAL + M.SNOOZE_MS).snoozes, 2)
})

check("done starts a fresh interval", () => {
  const s = M.fire(M.start(T0, INTERVAL))
  const next = M.done(T0 + INTERVAL, INTERVAL)
  eq(next.deadline, T0 + 2 * INTERVAL)
  eq(next.due, false)
  eq(next.snoozes, 0)
})

check("going idle keeps the deadline; coming back resets", () => {
  const s = M.start(T0, INTERVAL)
  const away = M.goIdle(s, T0 + 10 * MIN)
  eq(away.idleSince, T0 + 10 * MIN)
  eq(away.deadline, s.deadline)
  eq(M.goIdle(away, T0 + 11 * MIN).idleSince, T0 + 10 * MIN, "idleSince is kept")
  const back = M.endIdle(away, T0 + 20 * MIN, INTERVAL)
  eq(back.deadline, T0 + 20 * MIN + INTERVAL)
  eq(back.idleSince, 0)
})

check("coming back while the popup is due clears it", () => {
  const s = M.goIdle(M.fire(M.start(T0, INTERVAL)), T0 + INTERVAL + MIN)
  eq(M.endIdle(s, T0 + INTERVAL + 10 * MIN, INTERVAL).due, false)
})

check("state survives a round trip through JSON", () => {
  const s = M.snooze(M.fire(M.start(T0, INTERVAL)), T0 + INTERVAL)
  eq(M.parseState(M.serializeState(s), T0 + INTERVAL, INTERVAL), s)
})

check("garbage or missing state becomes a fresh start", () => {
  eq(M.parseState("", T0, INTERVAL), M.start(T0, INTERVAL))
  eq(M.parseState("{not json", T0, INTERVAL), M.start(T0, INTERVAL))
  eq(M.parseState("[]", T0, INTERVAL), M.start(T0, INTERVAL))
  eq(M.parseState('{"deadline": "x"}', T0, INTERVAL), M.start(T0, INTERVAL))
})

check("a deadline from a clock that jumped forward is reset", () => {
  const far = JSON.stringify({ deadline: T0 + 10 * 60 * MIN, due: false, idleSince: 0, snoozes: 0 })
  eq(M.parseState(far, T0, INTERVAL), M.start(T0, INTERVAL))
})

check("status and text", () => {
  const s = M.start(T0, INTERVAL)
  eq(M.statusOf(s, false, T0), "off")
  eq(M.statusOf(s, true, T0), "running")
  eq(M.statusOf(M.fire(s), true, T0), "due")
  eq(M.statusOf(M.goIdle(s, T0), true, T0), "away")
  eq(M.statusText(s, true, T0 + 12 * MIN), "Next break in 18 min")
  eq(M.statusText(s, true, T0 + INTERVAL - 1000), "Next break in 1 min")
  eq(M.statusText(s, true, T0 + INTERVAL), "Next break in now")
  eq(M.statusText(s, false, T0), "Off")
})

check("remainingMs never goes negative", () => {
  const s = M.start(T0, INTERVAL)
  eq(M.remainingMs(s, T0 + INTERVAL + MIN), 0)
})

if (failures.length) {
  console.log(passed + " passed, " + failures.length + " failed\n")
  failures.forEach(f => console.log("FAIL " + f + "\n"))
  process.exit(1)
}
console.log(passed + " passed")
