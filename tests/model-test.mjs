// Run with: node tests/model-test.mjs
// Model.js is a QML .pragma library, so it is loaded as plain source here.
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { dirname, join } from "node:path"
import vm from "node:vm"

const here = dirname(fileURLToPath(import.meta.url))
const source = readFileSync(join(here, "..", "Model.js"), "utf8").replace(".pragma library", "")
const Model = {}
vm.createContext(Model)
vm.runInContext(source, Model)

const unit = {
  puid: "abc", name: "Studio", room: "Studio", online: true,
  power: 1, target: 24, current: 26.5, mode: 2, fan: 0, eco: 0, sleep: 0, swing: 1,
  properties: { power: "t_power", target: "t_temp", current: "f_temp_in", mode: "t_work_mode",
                fan: "t_fan_speed", eco: "t_eco", sleep: "t_sleep", swing: "t_up_down" }
}

// A unit the cloud answered for
let status = Model.parseStatus(JSON.stringify({ units: [unit] }))
assert.equal(status.error, "")
assert.equal(status.units.length, 1)
assert.equal(status.units[0].target, 24)
assert.equal(status.units[0].powerProperty, "t_power")
assert.equal(status.units[0].swing, 1)
assert.equal(status.units[0].sleepProperty, "t_sleep")
assert.ok(Model.isOn(status.units[0]))
assert.ok(Model.anyOn(status.units))

// A property the unit never reported stays null and leaves its control hidden,
// which is not the same as the zero that means "off".
status = Model.parseStatus(JSON.stringify({
  units: [{ ...unit, fan: null, properties: { ...unit.properties, fan: null } }]
}))
assert.equal(status.units[0].fan, null)
assert.equal(status.units[0].fanProperty, "")

// Off is zero, not missing
status = Model.parseStatus(JSON.stringify({ units: [{ ...unit, power: 0 }] }))
assert.equal(status.units[0].power, 0)
assert.ok(!Model.isOn(status.units[0]))
assert.ok(!Model.anyOn(status.units))

// The bridge's own failures
status = Model.parseStatus(JSON.stringify({ error: "Not signed in", needsLogin: true }))
assert.equal(status.error, "Not signed in")
assert.equal(status.needsLogin, true)
assert.equal(status.units.length, 0)

// Anything that is not JSON is an error, not an empty panel
assert.ok(Model.parseStatus("Traceback (most recent call last):").error !== "")
assert.ok(Model.parseStatus("").error !== "")

// Labels and formatting
assert.equal(Model.modeLabel(2), "Cool")
assert.equal(Model.modeLabel(null), "—")
assert.equal(Model.fanLabel(9), "High")
assert.equal(Model.sleepLabel(2), "Elderly")
assert.equal(Model.swingLabel(1), "Swing")
assert.equal(Model.swingLabel(null), "—")
assert.equal(Model.formatTemp(26.54, true), "26.5°")
assert.equal(Model.formatTemp(23.6, false), "24°")
assert.equal(Model.formatTemp(null, false), "—")
assert.equal(Model.clampTemp(12), 16)
assert.equal(Model.clampTemp(40), 32)
assert.equal(Model.clampTemp(23.4), 23)

// The line an off unit shows instead of its controls
assert.equal(Model.offSummary(Model.parseStatus(JSON.stringify({ units: [unit] })).units[0]),
             "24° · Cool · fan auto")
// A unit that reports nothing but power says nothing, rather than "null · null"
assert.equal(Model.offSummary(Model.parseStatus(JSON.stringify({
  units: [{ ...unit, target: null, mode: null, fan: null,
            properties: { ...unit.properties, target: null, mode: null, fan: null } }]
})).units[0]), "")

assert.equal(Model.summary([], ""), "No air conditioner")
assert.equal(Model.summary([unit], ""), "1 unit · 1 on")
assert.equal(Model.summary([unit, { ...unit, power: 0 }], ""), "2 units · 1 on")
assert.equal(Model.summary([unit], "boom"), "Unavailable")

// --- call budget ---
const now = 1_000_000

// Nothing called recently: go.
assert.equal(Model.callDelay([], now, 0, 2500, 20), 0)

// The previous call is too close: wait out the rest of the gap.
assert.equal(Model.callDelay([now - 1000], now, now - 1000, 2500, 20), 1500)

// Calls older than the window do not count against the budget.
// Array.from: the library runs in its own vm context, so its arrays are not
// reference-equal to this file's Array.
assert.deepEqual(Array.from(Model.recentCalls([now - 70000, now - 100], now)), [now - 100])
assert.equal(Model.callDelay([now - 70000], now, 0, 2500, 1), 0)

// Budget spent: wait until the oldest call leaves the window, whatever the gap
// says.
const spent = [now - 50000, now - 40000, now - 10]
assert.equal(Model.callDelay(spent, now, 0, 2500, 3), 60000 - 50000 + 50)

// The two gates do not cancel each other out: the longer wait wins, here the
// minimum gap rather than the budget.
assert.equal(Model.callDelay([now - 59000, now - 100], now, now - 100, 2500, 2), 2400)
assert.equal(Model.callDelay([now - 100], now, now - 100, 5000, 20), 4900)

console.log("Model.js: all checks passed")
