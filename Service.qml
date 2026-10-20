import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "Model.js" as Model

Item {
  id: root

  property var settings: ({})

  property var units: []
  property bool installed: false
  property bool checkedInstall: false
  property bool needsLogin: false
  property string lastError: ""
  property string actionStatus: ""
  // True until the first answer, so the panel can say "loading" instead of
  // "no air conditioner".
  property bool loading: true

  // Polled faster while the panel is open: closed, nobody is watching, and the
  // library's author warns that hammering the cloud can get the account locked.
  property bool panelOpen: false

  readonly property bool anyOn: Model.anyOn(units)
  readonly property string summary: Model.summary(units, lastError)

  readonly property int idleIntervalSec: intSetting("refreshIntervalSec", 120, 30, 3600)
  readonly property int openIntervalSec: intSetting("openRefreshIntervalSec", 10, 5, 120)
  readonly property string pythonPath: String(setting("pythonPath", "") || "")

  // Ships next to this file, so the path follows the plugin wherever it lives.
  readonly property string bridgeScript: String(Qt.resolvedUrl("scripts/connectlife-bridge")).replace(/^file:\/\//, "")

  readonly property string defaultPython: {
    var dataHome = Quickshell.env("XDG_DATA_HOME")
    if (!dataHome || dataHome === "") dataHome = Quickshell.env("HOME") + "/.local/share"
    return dataHome + "/omarchy-electroline/venv/bin/python"
  }
  readonly property string interpreter: pythonPath !== "" ? pythonPath : defaultPython

  // One failed poll is not a broken bridge: a reload can kill a call in flight
  // and the cloud drops a request now and then. Only a run of failures replaces
  // the last known state with an error.
  readonly property int failuresBeforeError: 3
  property int _consecutiveFailures: 0

  // A command reaches the cloud long before the cloud admits it happened, so a
  // poll in between would snap the control back to the old value. Each written
  // field is held at what was asked for until the cloud agrees or the hold
  // expires.
  readonly property int pendingHoldMs: 20000
  property var _pending: ({})
  property var _queue: []

  // --- Call budget -----------------------------------------------------
  //
  // Hisense can lock an account that calls too often, and this panel can
  // produce calls far faster than anyone means to: a wheel over the slider
  // fires one release per notch, a run along the mode buttons is a write
  // each, and every panel open, "r" and middle click asks for a poll. So
  // every single call to the cloud passes three gates, here and nowhere
  // else: fields touched within a breath of each other leave as one
  // request, consecutive requests keep a minimum distance, and a bucket
  // caps the widget's whole traffic per minute. A call that trips a gate is
  // deferred to the first moment it is allowed, never dropped.
  readonly property int writeDebounceMs: 500
  readonly property int minStatusGapMs: 2500
  readonly property int minWriteGapMs: 900
  readonly property int maxCallsPerMinute: intSetting("maxCallsPerMinute", 20, 6, 120)

  property var _callTimes: []
  property real _lastStatusAt: 0
  property real _lastWriteAt: 0
  // Properties waiting to leave, per unit. Writing the same field twice before
  // the flush keeps only the last value.
  property var _draft: ({})

  property bool _recheckWanted: false

  function recordCall() {
    var now = Date.now()
    var times = Model.recentCalls(_callTimes, now)
    times.push(now)
    _callTimes = times
  }

  function callDelay(lastAt, minGap) {
    return Model.callDelay(_callTimes, Date.now(), lastAt, minGap, maxCallsPerMinute)
  }

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function intSetting(name, fallback, min, max) {
    var n = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(n)) n = fallback
    if (n < min) n = min
    if (n > max) n = max
    return n
  }

  function bridgeCommand(args) {
    return [root.interpreter, root.bridgeScript].concat(args)
  }

  function checkAvailability() {
    if (installProcess.running) {
      // The interpreter changed while a check was in flight. That check is
      // about the old path and its answer must not be believed, so another one
      // is queued for when it lands — dropping it here is what left the widget
      // declaring the default virtualenv missing while a perfectly good
      // interpreter sat in the settings.
      _recheckWanted = true
      return
    }
    _recheckWanted = false
    installProcess.command = ["test", "-x", root.interpreter]
    installProcess.running = true
  }

  function refresh() {
    if (!installed) {
      if (!checkedInstall) checkAvailability()
      return
    }
    if (statusProcess.running) return
    var wait = callDelay(_lastStatusAt, minStatusGapMs)
    if (wait > 0) {
      statusRetry.interval = wait
      statusRetry.restart()
      return
    }
    _lastStatusAt = Date.now()
    recordCall()
    statusProcess.command = bridgeCommand(["status"])
    statusProcess.running = true
    // A status call that never returns would freeze every later poll, because
    // each one is skipped while the previous is still running.
    if (!pollWatchdog.running) pollWatchdog.restart()
  }

  function unitAt(puid) {
    for (var i = 0; i < units.length; i++) if (units[i].puid === puid) return units[i]
    return null
  }

  function holdValue(puid, field, value) {
    var held = _pending[puid] || {}
    held[field] = { value: value, until: Date.now() + root.pendingHoldMs }
    _pending[puid] = held
    // Mutating the map in place leaves the binding unaware, so the panel would
    // keep the stale value until the next poll.
    _pending = _pending

    // And show it at once. The cloud needs seconds to admit a change, and a
    // control that does not move when clicked reads as broken — this is also
    // what the plus and minus buttons count from.
    var next = []
    for (var i = 0; i < units.length; i++) {
      var unit = units[i]
      if (unit.puid === puid) {
        unit = Object.assign({}, unit)
        unit[field] = value
      }
      next.push(unit)
    }
    units = next
  }

  // Keeps what was asked for in view while the cloud catches up, and lets go
  // the moment the cloud reports the same value or the hold runs out.
  function reconcile(fresh) {
    var now = Date.now()
    for (var i = 0; i < fresh.length; i++) {
      var unit = fresh[i]
      var held = _pending[unit.puid]
      if (!held) continue
      for (var field in held) {
        var entry = held[field]
        if (entry.until < now || unit[field] === entry.value) {
          delete held[field]
          continue
        }
        unit[field] = entry.value
      }
      if (Object.keys(held).length === 0) delete _pending[unit.puid]
    }
    _pending = _pending
    return fresh
  }

  function applyStatus(status) {
    loading = false
    needsLogin = status.needsLogin
    lastError = status.error
    if (status.error === "") units = reconcile(status.units)
  }

  function setActionStatus(text) {
    actionStatus = String(text || "")
    if (actionStatus !== "") actionStatusTimer.restart()
  }

  // Nothing leaves here directly: the value is shown at once and parked in the
  // draft, which goes out as one request per unit once the clicking stops.
  function send(puid, property, value, field, label) {
    if (property === "") {
      setActionStatus("This unit does not report " + field)
      return
    }
    holdValue(puid, field, value)
    setActionStatus(label)
    var draft = _draft[puid] || {}
    draft[property] = value
    _draft[puid] = draft
    _draft = _draft
    flushTimer.restart()
  }

  function flushDraft() {
    for (var puid in _draft) {
      var properties = _draft[puid]
      if (Object.keys(properties).length === 0) continue
      // A unit still waiting its turn takes the new values into the request it
      // has not sent yet, rather than earning a second one.
      var queued = null
      for (var i = 0; i < _queue.length; i++) if (_queue[i].puid === puid) queued = _queue[i]
      if (queued) {
        for (var name in properties) queued.properties[name] = properties[name]
      } else {
        _queue.push({ puid: puid, properties: properties })
      }
    }
    _draft = ({})
    _queue = _queue
    pumpQueue()
  }

  // One write at a time: the cloud answers slowly and two overlapping writes to
  // the same unit can come back in either order.
  function pumpQueue() {
    if (setProcess.running || _queue.length === 0) return
    var wait = callDelay(_lastWriteAt, minWriteGapMs)
    if (wait > 0) {
      queueRetry.interval = wait
      queueRetry.restart()
      return
    }
    var next = _queue.shift()
    _queue = _queue
    var assignments = []
    for (var name in next.properties) assignments.push(name + "=" + next.properties[name])
    _lastWriteAt = Date.now()
    recordCall()
    setProcess.command = bridgeCommand(["set", next.puid].concat(assignments))
    setProcess.running = true
  }

  function setPower(puid, on) {
    var unit = unitAt(puid)
    if (!unit) return
    send(puid, unit.powerProperty, on ? 1 : 0, "power", on ? "Turning on…" : "Turning off…")
  }

  function togglePower(puid) {
    var unit = unitAt(puid)
    if (unit) setPower(puid, !Model.isOn(unit))
  }

  function setTarget(puid, celsius) {
    var unit = unitAt(puid)
    if (!unit) return
    var value = Model.clampTemp(celsius)
    if (unit.target === value) return
    send(puid, unit.targetProperty, value, "target", "Setting " + value + "°…")
  }

  function setMode(puid, mode) {
    var unit = unitAt(puid)
    if (!unit) return
    send(puid, unit.modeProperty, parseInt(mode, 10), "mode", "Switching to " + Model.modeLabel(mode) + "…")
  }

  function stepTarget(puid, degrees) {
    var unit = unitAt(puid)
    if (!unit || unit.target === null) return
    setTarget(puid, unit.target + degrees)
  }

  function setFan(puid, fan) {
    var unit = unitAt(puid)
    if (!unit) return
    send(puid, unit.fanProperty, parseInt(fan, 10), "fan", "Fan " + Model.fanLabel(fan) + "…")
  }

  function setEco(puid, on) {
    var unit = unitAt(puid)
    if (!unit) return
    send(puid, unit.ecoProperty, on ? 1 : 0, "eco", on ? "Eco on…" : "Eco off…")
  }

  function setSleep(puid, value) {
    var unit = unitAt(puid)
    if (!unit) return
    send(puid, unit.sleepProperty, parseInt(value, 10), "sleep", "Sleep " + Model.sleepLabel(value) + "…")
  }

  function setSwing(puid, value) {
    var unit = unitAt(puid)
    if (!unit) return
    send(puid, unit.swingProperty, parseInt(value, 10), "swing", "Airflow " + Model.swingLabel(value) + "…")
  }

  Process {
    id: installProcess
    running: false
    command: []
    onExited: function (exitCode) {
      if (root._recheckWanted) {
        root.checkAvailability()
        return
      }
      root.checkedInstall = true
      root.installed = exitCode === 0
      if (root.installed) root.refresh()
      else {
        root.loading = false
        root.lastError = "No interpreter at " + root.interpreter + ". Run scripts/setup-electroline."
      }
    }
  }

  Process {
    id: statusProcess
    running: false
    command: []
    stdout: StdioCollector { id: statusStdout; waitForEnd: true }
    stderr: StdioCollector { id: statusStderr; waitForEnd: true }
    onExited: function (exitCode) {
      pollWatchdog.stop()
      var parsed = Model.parseStatus(String(statusStdout.text || ""))
      // The bridge reports its own failures as JSON on stdout; a non-zero exit
      // with nothing there means it never got that far.
      if (parsed.error === "" && exitCode !== 0) {
        parsed.error = String(statusStderr.text || "").trim() ||
                       "The bridge exited with code " + exitCode
      }
      if (parsed.error !== "") {
        root._consecutiveFailures += 1
        // A sign-in that has run out will not fix itself, so it is shown at once.
        if (parsed.needsLogin || root._consecutiveFailures >= root.failuresBeforeError) {
          root.applyStatus(parsed)
        }
        root.loading = false
        return
      }
      root._consecutiveFailures = 0
      root.applyStatus(parsed)
    }
  }

  Process {
    id: setProcess
    running: false
    command: []
    stdout: StdioCollector { id: setStdout; waitForEnd: true }
    stderr: StdioCollector { id: setStderr; waitForEnd: true }
    onExited: function (exitCode) {
      var parsed = Model.parseStatus(String(setStdout.text || ""))
      if (exitCode !== 0 || parsed.error !== "") {
        root.lastError = parsed.error ||
                         String(setStderr.text || "").trim() ||
                         "The command exited with code " + exitCode
        root.needsLogin = parsed.needsLogin
        root.setActionStatus("The command failed")
        // A command that never landed must not keep showing its value, and
        // whatever was still waiting to go must not follow it into the same
        // failure.
        root._pending = ({})
        root._draft = ({})
        root._queue = []
      } else {
        root.lastError = ""
        root.setActionStatus("Sent")
        root.applyStatus(parsed)
        // The answer is usually still the old state, so look again shortly.
        confirmTimer.restart()
      }
      root.pumpQueue()
    }
  }

  Timer {
    id: refreshTimer
    interval: (root.panelOpen ? root.openIntervalSec : root.idleIntervalSec) * 1000
    repeat: true
    running: root.installed
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Timer {
    // Gives the cloud time to apply a command before the state is read back.
    id: confirmTimer
    interval: 4000
    repeat: false
    onTriggered: root.refresh()
  }

  Timer {
    // Collects every control touched in the same breath into one request.
    id: flushTimer
    interval: root.writeDebounceMs
    repeat: false
    onTriggered: root.flushDraft()
  }

  Timer {
    // A poll that arrived too early comes back exactly when it is allowed.
    id: statusRetry
    interval: 1000
    repeat: false
    onTriggered: root.refresh()
  }

  Timer {
    id: queueRetry
    interval: 1000
    repeat: false
    onTriggered: root.pumpQueue()
  }

  Timer {
    id: pollWatchdog
    interval: 25000
    repeat: false
    onTriggered: if (statusProcess.running) statusProcess.running = false
  }

  Timer {
    id: actionStatusTimer
    interval: 2600
    repeat: false
    onTriggered: root.actionStatus = ""
  }

  onPanelOpenChanged: if (panelOpen) refresh()

  // Settings arrive after the component is built, so the first availability
  // check can run against the default interpreter and latch a verdict about a
  // path the widget was never going to use.
  onInterpreterChanged: {
    checkedInstall = false
    installed = false
    lastError = ""
    checkAvailability()
  }

  Component.onCompleted: checkAvailability()
}
