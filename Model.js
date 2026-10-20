.pragma library

// Property values as Hisense defines them for air conditioners (device type
// 009). They are plain integers on the wire, but ButtonGroup compares option
// values as strings, so the UI carries them as strings throughout.
var MODES = [
  { value: "4", label: "Auto" },
  { value: "2", label: "Cool" },
  { value: "1", label: "Heat" },
  { value: "3", label: "Dry" },
  { value: "0", label: "Fan" }
]

// Six speeds. 0 is the automatic one; the rest climb from 5 to 9 in the
// protocol, which is why the values do not line up with anything.
var FAN_SPEEDS = [
  { value: "0", label: "Auto" },
  { value: "5", label: "Low" },
  { value: "6", label: "Medium low" },
  { value: "7", label: "Medium" },
  { value: "8", label: "Medium high" },
  { value: "9", label: "High" }
]

// Hisense's sleep curves. The names are the data dictionary's, in plain words.
var SLEEP_MODES = [
  { value: "0", label: "Off" },
  { value: "1", label: "Standard" },
  { value: "2", label: "Elderly" },
  { value: "3", label: "Young" },
  { value: "4", label: "Child" }
]

var SWING_MODES = [
  { value: "0", label: "Fixed" },
  { value: "1", label: "Swing" }
]

var MIN_TEMP = 16
var MAX_TEMP = 32

function emptyStatus() {
  return { units: [], error: "", needsLogin: false }
}

// The bridge always answers with one JSON object: either {units: [...]} or
// {error, needsLogin}. Anything else means the bridge itself broke, and that
// is an error worth showing rather than an empty panel.
function parseStatus(raw) {
  var status = emptyStatus()
  var text = String(raw || "").trim()
  if (text === "") {
    status.error = "The bridge returned nothing."
    return status
  }
  var data
  try {
    data = JSON.parse(text)
  } catch (e) {
    status.error = "The bridge returned something unreadable: " + text.split("\n")[0]
    return status
  }
  if (data && data.error) {
    status.error = String(data.error)
    status.needsLogin = data.needsLogin === true
    return status
  }
  var units = (data && data.units) || []
  for (var i = 0; i < units.length; i++) status.units.push(normalizeUnit(units[i]))
  return status
}

// A unit that does not report a property gets null for it, and the panel hides
// the control rather than sending a command to a field that does not exist.
function normalizeUnit(raw) {
  var properties = raw.properties || {}
  return {
    puid: String(raw.puid || ""),
    name: String(raw.name || "Air conditioner"),
    room: String(raw.room || ""),
    online: raw.online === true,
    power: toNumber(raw.power),
    target: toNumber(raw.target),
    current: toNumber(raw.current),
    mode: toNumber(raw.mode),
    fan: toNumber(raw.fan),
    eco: toNumber(raw.eco),
    sleep: toNumber(raw.sleep),
    swing: toNumber(raw.swing),
    powerProperty: propertyName(properties.power),
    targetProperty: propertyName(properties.target),
    modeProperty: propertyName(properties.mode),
    fanProperty: propertyName(properties.fan),
    ecoProperty: propertyName(properties.eco),
    sleepProperty: propertyName(properties.sleep),
    swingProperty: propertyName(properties.swing)
  }
}

function propertyName(value) {
  return value === null || value === undefined ? "" : String(value)
}

// null stays null: "the unit never said" has to stay distinct from "zero",
// which for t_power means off.
function toNumber(value) {
  if (value === null || value === undefined || value === "") return null
  var n = Number(value)
  return isFinite(n) ? n : null
}

function isOn(unit) {
  return unit && unit.power === 1
}

function anyOn(units) {
  for (var i = 0; i < units.length; i++) if (isOn(units[i])) return true
  return false
}

function summary(units, error) {
  if (error) return "Unavailable"
  if (units.length === 0) return "No air conditioner"
  var on = 0
  for (var i = 0; i < units.length; i++) if (isOn(units[i])) on++
  var label = units.length === 1 ? "1 unit" : units.length + " units"
  return label + " · " + (on === 0 ? "all off" : on + " on")
}

function optionLabel(options, value) {
  var wanted = String(value)
  for (var i = 0; i < options.length; i++) if (options[i].value === wanted) return options[i].label
  return "—"
}

function modeLabel(value) {
  return value === null ? "—" : optionLabel(MODES, value)
}

function fanLabel(value) {
  return value === null ? "—" : optionLabel(FAN_SPEEDS, value)
}

function sleepLabel(value) {
  return value === null ? "—" : optionLabel(SLEEP_MODES, value)
}

function swingLabel(value) {
  return value === null ? "—" : optionLabel(SWING_MODES, value)
}

// What a sleeping unit would do if you woke it: enough to decide without
// turning it on first.
function offSummary(unit) {
  var parts = []
  if (unit.target !== null) parts.push(formatTemp(unit.target, false))
  if (unit.mode !== null) parts.push(modeLabel(unit.mode))
  if (unit.fan !== null) parts.push("fan " + fanLabel(unit.fan).toLowerCase())
  return parts.join(" · ")
}

function clampTemp(value) {
  var n = Math.round(Number(value))
  if (!isFinite(n)) return MIN_TEMP
  return Math.max(MIN_TEMP, Math.min(MAX_TEMP, n))
}

// Whole degrees for a setpoint, one decimal for a reading: the unit reports the
// room temperature in halves and rounding it away loses the only moving number
// in the panel.
function formatTemp(value, decimals) {
  if (value === null || value === undefined) return "—"
  var n = Number(value)
  if (!isFinite(n)) return "—"
  return (decimals ? n.toFixed(1) : String(Math.round(n))) + "°"
}

// --- Call budget -----------------------------------------------------------
//
// Pure arithmetic so it can be tested outside QML: Service.qml keeps the list
// of call timestamps and asks these two how long to wait.

var CALL_WINDOW_MS = 60000

// The calls still inside the rolling window, oldest first.
function recentCalls(times, now) {
  var kept = []
  for (var i = 0; i < times.length; i++) {
    if (now - times[i] < CALL_WINDOW_MS) kept.push(times[i])
  }
  return kept
}

// 0 means "go now". Anything else is the milliseconds to wait before the call
// is allowed: either because the previous one is too recent, or because the
// budget for the last minute is spent and the oldest call has to age out
// first. The caller waits that long and asks again, so nothing is lost.
function callDelay(times, now, lastCallAt, minGapMs, maxPerMinute) {
  var wait = Math.max(0, minGapMs - (now - lastCallAt))
  var recent = recentCalls(times, now)
  if (recent.length >= maxPerMinute) {
    wait = Math.max(wait, CALL_WINDOW_MS - (now - recent[0]) + 50)
  }
  return wait
}
