import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui

Item {
  id: root

  component Slider: Item {
    id: slider
    property string label: ""
    property real from: 0
    property real to: 100
    property real step: 1
    property real value: 0
    signal released(real next)
    implicitHeight: Style.space(36)
    implicitWidth: Style.space(280)
    readonly property color fg: Color.menu.text
    readonly property color accent: Color.accent
    readonly property color track: Util.alpha(Color.menu.text, 0.16)

    function snap(next) {
      var lo = Math.max(slider.from, Math.min(slider.to, next))
      if (slider.step <= 0) return lo
      var snapped = slider.from + Math.round((lo - slider.from) / slider.step) * slider.step
      snapped = Math.max(slider.from, Math.min(slider.to, snapped))
      return slider.step >= 1 ? Math.round(snapped) : Math.round(snapped * 100) / 100
    }

    function setFromX(x) {
      var span = Math.max(1, trackItem.width)
      var ratio = Math.max(0, Math.min(1, x / span))
      slider.value = snap(slider.from + ratio * (slider.to - slider.from))
    }

    Text {
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(108)
      text: slider.label
      color: slider.fg
      font.family: Style.font.menuFamily
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideRight
    }

    Rectangle {
      id: trackItem
      anchors.left: parent.left
      anchors.leftMargin: Style.space(112)
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      height: Style.space(4)
      radius: height / 2
      color: slider.track
      Rectangle {
        width: Math.max(height, (slider.value - slider.from) / Math.max(0.001, slider.to - slider.from) * parent.width)
        height: parent.height
        radius: parent.radius
        color: slider.accent
      }
      Rectangle {
        width: Style.space(14)
        height: Style.space(14)
        radius: width / 2
        color: slider.accent
        anchors.verticalCenter: parent.verticalCenter
        x: Math.max(0, Math.min(parent.width - width, (slider.value - slider.from) / Math.max(0.001, slider.to - slider.from) * parent.width - width / 2))
      }
      MouseArea {
        anchors.fill: parent
        anchors.margins: -Style.space(10)
        preventStealing: true
        onPressed: function(mouse) { slider.setFromX(mouse.x) }
        onPositionChanged: function(mouse) { if (pressed) slider.setFromX(mouse.x) }
        onReleased: slider.released(slider.value)
      }
    }
  }

  component Chip: Rectangle {
    id: chip
    property string caption: ""
    property bool active: false
    property bool accented: false
    property bool outlined: false
    signal clicked()
    Layout.fillWidth: true
    Layout.preferredHeight: Style.space(32)
    radius: root.cornerRadius
    opacity: enabled ? 1 : 0.38
    border.width: outlined && !active ? 1 : 0
    border.color: root.accent
    color: {
      if (chip.accented) return root.accent
      if (chip.active) return root.accent
      return chipArea.containsMouse ? Util.alpha(root.accent, 0.28) : root.faint
    }
    Text {
      anchors.centerIn: parent
      width: parent.width - Style.space(10)
      horizontalAlignment: Text.AlignHCenter
      elide: Text.ElideRight
      text: chip.caption
      color: (chip.active || chip.accented) ? root.cardBg : root.fg
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      font.bold: chip.accented
    }
    MouseArea {
      id: chipArea
      anchors.fill: parent
      hoverEnabled: true
      enabled: chip.enabled
      onClicked: chip.clicked()
    }
  }

  property var shell: null
  property var manifest: null
  property bool opened: false

  readonly property string py: Quickshell.env("HOME") + "/.config/omarchy/plugins/monitor.play/monitor_play.py"
  readonly property color fg: Color.menu.text
  readonly property color muted: Util.alpha(Color.menu.text, 0.62)
  readonly property color faint: Util.alpha(Color.menu.text, 0.12)
  readonly property color accent: Color.accent
  readonly property color cardBg: Color.menu.background
  readonly property color scrim: Color.menu.scrim
  readonly property int cornerRadius: Style.cornerRadius
  readonly property string fontFamily: Style.font.menuFamily
  readonly property var scaleSteps: [1, 1.25, 1.5, 1.75, 2]

  property int selected: 0
  property bool dragging: false
  property bool dirty: false
  property bool applying: false
  property bool trying: false
  property int tryLeft: 0
  property string pendingAction: ""
  property string liveLine: ""
  property bool worldReady: false
  property bool keepNotice: false
  property int revision: 0
  property string notice: ""
  property bool noticeError: false
  property string applyOut: ""
  property string applyErr: ""
  property var modeMap: ({})
  property var resOrder: ({})
  property var extraResolutions: []
  property var defaults: []

  property real worldX: 0
  property real worldY: 0
  property real worldW: 1
  property real worldH: 1

  readonly property real fit: {
    if (!worldReady || worldW < 1 || canvas.width < 2 || canvas.height < 2) return 0.05
    return Math.min(canvas.width / worldW, canvas.height / worldH)
  }
  readonly property real originX: (canvas.width - worldW * fit) / 2 - worldX * fit
  readonly property real originY: (canvas.height - worldH * fit) / 2 - worldY * fit

  readonly property string overlapHint: {
    var rev = root.revision
    if (monitors.count < 2) return ""
    for (var i = 0; i < monitors.count; i++) {
      var a = monitors.get(i)
      for (var j = i + 1; j < monitors.count; j++) {
        var b = monitors.get(j)
        var apart = a.lx + a.lw <= b.lx || b.lx + b.lw <= a.lx || a.ly + a.lh <= b.ly || b.ly + b.lh <= a.ly
        if (!apart) return "These screens overlap, so the pointer will see them in the same place."
      }
    }
    return rev ? "" : ""
  }

  function open(payloadJson) {
    root.opened = true
    root.notice = ""
    root.noticeError = false
    root.keepNotice = false
    root.dirty = false
    root.worldReady = false
    root.selected = 0
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
    loadProc.running = false
    loadProc.running = true
  }

  function close() {
    root.opened = false
    root.dragging = false
  }

  function dismiss() {
    root.close()
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "monitor.play")
  }

  function toggle() {
    if (root.opened) root.dismiss()
    else root.open("{}")
  }

  function logicalSize(pxW, pxH, scale, transform) {
    var w = pxW
    var h = pxH
    if (transform === 1 || transform === 3) { w = pxH; h = pxW }
    var safe = scale > 0 ? scale : 1
    return { w: w / safe, h: h / safe }
  }

  function resolutionKey(mon) {
    if (!mon) return ""
    if (!mon.mode || mon.mode === "preferred") return Math.round(mon.pxW) + "x" + Math.round(mon.pxH)
    return String(mon.mode).split("@")[0]
  }

  function selectedMonitor() {
    var rev = root.revision
    if (rev < 0 || root.selected < 0 || root.selected >= monitors.count) return null
    return monitors.get(root.selected)
  }

  function modeNote() {
    var mon = root.selectedMonitor()
    if (!mon) return ""
    var modes = root.modeMap[mon.name] || []
    for (var i = 0; i < modes.length; i++) {
      if (modes[i].mode === mon.mode) {
        var note = modes[i].fitNote || ""
        if (modes[i].note) note = note ? note + " " + modes[i].note : modes[i].note
        return note
      }
    }
    return ""
  }

  function syncChips() {
    resolutionModel.clear()
    refreshModel.clear()
    var mon = root.selected >= 0 && root.selected < monitors.count ? monitors.get(root.selected) : null
    if (!mon) return
    var order = root.resOrder[mon.name] || []
    var modes = root.modeMap[mon.name] || []
    var res = root.resolutionKey(mon)
    var featured = {
      "3440x1440": true,
      "3840x2160": true,
      "2560x1440": true,
      "2560x1080": true,
      "1920x1080": true,
      "1280x720": true
    }
    var extras = []
    for (var i = 0; i < order.length; i++) {
      var key = order[i]
      var featuredKey = !!featured[key]
      if (order.length > 8 && !featuredKey && key !== res) {
        extras.push(key)
        continue
      }
      var label = key.replace("x", "×")
      if (key === "3840x2160") label = "4K"
      else if (key === "1920x1080") label = "1080p"
      else if (key === "3440x1440") label = "3440×1440"
      var fit = ""
      for (var f = 0; f < modes.length; f++) {
        if ((modes[f].width + "x" + modes[f].height) === key) { fit = modes[f].fit || ""; break }
      }
      if (fit) label = label + " · " + fit
      resolutionModel.append({ key: key, label: label })
    }
    root.extraResolutions = extras
    if (extras.length) resolutionModel.append({ key: "more", label: "More" })
    for (var j = 0; j < modes.length; j++) {
      var item = modes[j]
      if ((item.width + "x" + item.height) !== res) continue
      refreshModel.append({
        mode: item.mode,
        label: item.label || String(item.refresh),
        note: item.note || "",
        advertised: item.advertised ? 1 : 0
      })
    }
  }

  function ingest(text) {
    var data
    try { data = JSON.parse(String(text || "")) } catch (e) {
      root.notice = "Could not read the connected screens."
      root.noticeError = true
      return
    }
    if (!data || !data.ok || !data.screens) {
      root.notice = (data && data.error) || "Could not read the connected screens."
      root.noticeError = true
      return
    }
    var nextModes = ({})
    var nextOrder = ({})
    monitors.clear()
    var pick = 0
    for (var i = 0; i < data.screens.length; i++) {
      var mon = data.screens[i]
      var scale = Number(mon.scale) || 1
      var pxW = Number(mon.width) || 1
      var pxH = Number(mon.height) || 1
      var transform = Number(mon.transform) || 0
      var size = logicalSize(pxW, pxH, scale, transform)
      nextModes[mon.name] = mon.modes || []
      nextOrder[mon.name] = mon.resolutions || []
      if (String(mon.name).indexOf("eDP") !== 0) pick = monitors.count
      monitors.append({
        name: mon.name,
        label: mon.label || mon.name,
        lx: Number(mon.x) || 0,
        ly: Number(mon.y) || 0,
        lw: size.w,
        lh: size.h,
        pxW: pxW,
        pxH: pxH,
        scale: scale,
        mode: mon.mode || "preferred",
        transform: transform,
        vrr: mon.vrr ? 1 : 0,
        bitdepth: Number(mon.bitdepth) || 0,
        brightness: mon.brightness === null || mon.brightness === undefined ? 0 : Number(mon.brightness),
        brightnessOriginal: mon.brightness === null || mon.brightness === undefined ? -1 : Number(mon.brightness),
        brightnessKnown: mon.brightness === null || mon.brightness === undefined ? 0 : 1
      })
    }
    root.modeMap = nextModes
    root.resOrder = nextOrder
    root.defaults = data.defaults || data.profile || []
    var liveBits = []
    var confirmed = data.confirmed || data.screens
    for (var c = 0; c < confirmed.length; c++) {
      var live = confirmed[c]
      liveBits.push((live.label || live.name) + " " + live.width + "×" + live.height + " at " + live.confirmedHz + " Hz")
    }
    root.liveLine = liveBits.length ? "On screen now: " + liveBits.join("   ·   ") : ""
    root.selected = monitors.count ? pick : -1
    root.revision += 1
    captureWorld()
    syncChips()
    if (!root.keepNotice) {
      root.noticeError = false
      root.notice = ""
    }
    root.keepNotice = false
  }

  function captureWorld() {
    if (monitors.count < 1) return
    var minX = monitors.get(0).lx
    var minY = monitors.get(0).ly
    var maxX = minX + monitors.get(0).lw
    var maxY = minY + monitors.get(0).lh
    for (var i = 1; i < monitors.count; i++) {
      var mon = monitors.get(i)
      minX = Math.min(minX, mon.lx)
      minY = Math.min(minY, mon.ly)
      maxX = Math.max(maxX, mon.lx + mon.lw)
      maxY = Math.max(maxY, mon.ly + mon.lh)
    }
    var spanX = Math.max(1, maxX - minX)
    var spanY = Math.max(1, maxY - minY)
    var padX = spanX * 0.28
    var padY = spanY * 0.38
    root.worldX = minX - padX
    root.worldY = minY - padY
    root.worldW = spanX + padX * 2
    root.worldH = spanY + padY * 2
    root.worldReady = true
  }

  function bump() {
    root.dirty = true
    root.revision += 1
  }

  function resizeSelected() {
    var mon = monitors.get(root.selected)
    var size = logicalSize(mon.pxW, mon.pxH, mon.scale, mon.transform)
    monitors.setProperty(root.selected, "lw", size.w)
    monitors.setProperty(root.selected, "lh", size.h)
  }

  function setMode(mode) {
    if (root.selected < 0) return
    var mon = monitors.get(root.selected)
    var modes = root.modeMap[mon.name] || []
    var chosen = null
    for (var i = 0; i < modes.length; i++) if (modes[i].mode === mode) chosen = modes[i]
    monitors.setProperty(root.selected, "mode", mode)
    if (chosen && mode !== "preferred") {
      monitors.setProperty(root.selected, "pxW", chosen.width)
      monitors.setProperty(root.selected, "pxH", chosen.height)
    }
    resizeSelected()
    bump()
    syncChips()
  }

  function moreResolution() {
    if (!root.extraResolutions.length || root.selected < 0) return
    var mon = monitors.get(root.selected)
    var current = root.resolutionKey(mon)
    var at = root.extraResolutions.indexOf(current)
    root.selectResolution(root.extraResolutions[(at + 1) % root.extraResolutions.length])
  }

  function selectResolution(key) {
    var mon = root.selectedMonitor()
    if (!mon) return
    var modes = root.modeMap[mon.name] || []
    var currentHz = 0
    if (mon.mode && mon.mode !== "preferred") currentHz = parseInt(String(mon.mode).split("@")[1], 10) || 0
    var matches = []
    for (var i = 0; i < modes.length; i++) {
      if ((modes[i].width + "x" + modes[i].height) === key) matches.push(modes[i])
    }
    if (!matches.length) return
    var chosen = matches[0]
    var matchedHz = false
    if (currentHz) {
      for (var j = 0; j < matches.length; j++) {
        if (matches[j].refresh === currentHz) { chosen = matches[j]; matchedHz = true }
      }
    }
    if (!matchedHz) {
      var best = null
      for (var k = 0; k < matches.length; k++) {
        if (matches[k].preferred) { chosen = matches[k]; best = matches[k]; break }
      }
      if (!best) {
        for (var n = 0; n < matches.length; n++) {
          if (!matches[n].advertised) continue
          if (!best || matches[n].refresh > best.refresh) best = matches[n]
        }
        chosen = best || matches[matches.length - 1]
      }
    }
    root.setMode(chosen.mode)
  }

  function snap(index, x, y, w, h, noSnap) {
    if (noSnap) return { x: x, y: y }
    var thresh = 80
    var sx = x
    var sy = y
    var bestDx = thresh
    var bestDy = thresh
    for (var i = 0; i < monitors.count; i++) {
      if (i === index) continue
      var other = monitors.get(i)
      var xs = [other.lx + other.lw, other.lx - w, other.lx, other.lx + other.lw - w]
      var ys = [other.ly + other.lh, other.ly - h, other.ly, other.ly + other.lh - h]
      for (var c = 0; c < xs.length; c++) {
        var dx = Math.abs(x - xs[c])
        if (dx < bestDx) { bestDx = dx; sx = xs[c] }
      }
      for (var k = 0; k < ys.length; k++) {
        var dy = Math.abs(y - ys[k])
        if (dy < bestDy) { bestDy = dy; sy = ys[k] }
      }
    }
    return { x: bestDx < thresh ? sx : x, y: bestDy < thresh ? sy : y }
  }

  function moveMonitor(index, x, y, w, h, noSnap) {
    var snapped = snap(index, Math.round(x), Math.round(y), w, h, noSnap)
    monitors.setProperty(index, "lx", snapped.x)
    monitors.setProperty(index, "ly", snapped.y)
    bump()
  }

  function nudge(dx, dy) {
    if (root.selected < 0 || root.selected >= monitors.count) return
    var mon = monitors.get(root.selected)
    moveMonitor(root.selected, mon.lx + dx, mon.ly + dy, mon.lw, mon.lh, true)
  }

  function stepScale(dir) {
    if (root.selected < 0) return
    var mon = monitors.get(root.selected)
    var best = 0
    var bestDist = 99
    for (var i = 0; i < root.scaleSteps.length; i++) {
      var dist = Math.abs(root.scaleSteps[i] - mon.scale)
      if (dist < bestDist) { bestDist = dist; best = i }
    }
    var next = Math.max(0, Math.min(root.scaleSteps.length - 1, best + dir))
    monitors.setProperty(root.selected, "scale", root.scaleSteps[next])
    resizeSelected()
    bump()
  }

  function cycleTransform() {
    if (root.selected < 0) return
    var mon = monitors.get(root.selected)
    monitors.setProperty(root.selected, "transform", (mon.transform + 1) % 4)
    resizeSelected()
    bump()
  }

  function toggleVrr() {
    if (root.selected < 0) return
    var mon = monitors.get(root.selected)
    monitors.setProperty(root.selected, "vrr", mon.vrr ? 0 : 1)
    bump()
  }

  function setBits(bits) {
    if (root.selected < 0) return
    monitors.setProperty(root.selected, "bitdepth", bits === 10 ? 10 : 0)
    bump()
  }

  function stepBrightness(dir) {
    if (root.selected < 0) return
    var mon = monitors.get(root.selected)
    if (!mon.brightnessKnown) return
    var next = Math.max(0, Math.min(100, mon.brightness + dir * 5))
    monitors.setProperty(root.selected, "brightness", next)
    bump()
  }

  function laptopIndex() {
    for (var i = 0; i < monitors.count; i++) {
      if (String(monitors.get(i).name).indexOf("eDP") === 0) return i
    }
    return 0
  }

  function arrange(kind) {
    if (monitors.count < 1) return
    var laptop = laptopIndex()
    var order = []
    if (kind === "right") {
      for (var i = 0; i < monitors.count; i++) if (i !== laptop) order.push(i)
      order.push(laptop)
    } else {
      order.push(laptop)
      for (var j = 0; j < monitors.count; j++) if (j !== laptop) order.push(j)
    }
    if (kind === "stack") {
      var y = 0
      for (var s = 0; s < order.length; s++) {
        var stacked = monitors.get(order[s])
        monitors.setProperty(order[s], "lx", 0)
        monitors.setProperty(order[s], "ly", y)
        y += stacked.lh
      }
    } else {
      var x = 0
      for (var n = 0; n < order.length; n++) {
        var placed = monitors.get(order[n])
        monitors.setProperty(order[n], "lx", x)
        monitors.setProperty(order[n], "ly", 0)
        x += placed.lw
      }
    }
    bump()
    root.worldReady = false
    captureWorld()
  }

  function useDefault() {
    if (!monitors.count) return
    for (var i = 0; i < monitors.count; i++) {
      var mon = monitors.get(i)
      var chosen = null
      for (var d = 0; d < root.defaults.length; d++) {
        var item = root.defaults[d]
        if (item.name === mon.name || String(mon.name).indexOf(item.match) === 0) chosen = item
      }
      if (!chosen) continue
      monitors.setProperty(i, "scale", Number(chosen.scale) || 1)
      monitors.setProperty(i, "transform", Number(chosen.transform) || 0)
      monitors.setProperty(i, "vrr", chosen.vrr ? 1 : 0)
      monitors.setProperty(i, "bitdepth", 0)
      monitors.setProperty(i, "lx", Number(chosen.x) || 0)
      monitors.setProperty(i, "ly", Number(chosen.y) || 0)
      root.selected = i
      root.setMode(chosen.mode || "preferred")
    }
    root.selected = 0
    for (var k = 0; k < monitors.count; k++) {
      if (String(monitors.get(k).name).indexOf("eDP") !== 0) root.selected = k
    }
    syncChips()
  }

  function scaleLabel(value) {
    if (Math.abs(value - Math.round(value)) < 0.01) return String(Math.round(value))
    return Number(value).toFixed(2).replace(/0+$/, "").replace(/\.$/, "")
  }

  function rotationLabel(value) {
    if (value === 1) return "90°"
    if (value === 2) return "180°"
    if (value === 3) return "270°"
    return "0°"
  }

  function formScreens() {
    var payload = []
    for (var i = 0; i < monitors.count; i++) {
      var mon = monitors.get(i)
      var item = {
        name: mon.name,
        x: mon.lx,
        y: mon.ly,
        scale: mon.scale,
        mode: mon.mode,
        transform: mon.transform,
        vrr: mon.vrr ? true : false
      }
      if (mon.bitdepth === 10) item.bitdepth = 10
      payload.push(item)
    }
    return payload
  }

  function runAction(action, body) {
    if (root.applying || monitors.count < 1) return
    root.pendingAction = action
    root.applying = true
    root.trying = action === "try"
    root.applyOut = ""
    root.applyErr = ""
    root.notice = action === "try" ? "Trying this for 10 seconds…" : (action === "save" ? "Saving profile…" : "Applying…")
    root.noticeError = false
    if (action === "try") {
      root.tryLeft = 10
      tryTimer.restart()
    }
    applyProc.command = ["python3", root.py, "api", action].concat([JSON.stringify(body)])
    applyProc.running = true
  }

  function apply() {
    root.runAction("apply", { screens: root.formScreens() })
  }

  function saveProfile() {
    root.runAction("save", { screens: root.formScreens() })
  }

  function tryMode() {
    root.runAction("try", { seconds: 10, screens: root.formScreens() })
  }

  function pushBrightness(level) {
    var mon = root.selectedMonitor()
    if (!mon || !mon.brightnessKnown || brightProc.running) return
    monitors.setProperty(root.selected, "brightness", level)
    brightProc.command = ["python3", root.py, "api", "brightness", JSON.stringify({
      screens: [{ name: mon.name, brightness: level }]
    })]
    brightProc.running = true
  }

  ListModel { id: monitors }
  ListModel { id: resolutionModel }
  ListModel { id: refreshModel }

  Process {
    id: loadProc
    command: ["python3", root.py, "api", "get"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.ingest(text)
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var err = String(text || "").trim()
        if (err && !root.notice) {
          root.notice = err
          root.noticeError = true
        }
      }
    }
  }

  Process {
    id: applyProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyOut = String(text || "")
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyErr = String(text || "").trim()
    }
    onExited: function(exitCode) {
      root.applying = false
      root.trying = false
      tryTimer.stop()
      var failed = exitCode !== 0
      var msg = failed ? (root.applyErr || "Could not apply that mode. The previous layout was restored.") : "Applied."
      try {
        var data = JSON.parse(root.applyOut || "{}")
        if (!failed && data.message) msg = data.message
        if (!failed && data.warning) msg += " " + data.warning
        if (failed && data.error) msg = data.error
      } catch (e) {}
      root.notice = msg
      root.noticeError = failed
      root.keepNotice = true
      root.dirty = false
      loadProc.running = false
      loadProc.running = true
    }
  }

  Process {
    id: brightProc
    stdout: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode === 0 && root.selected >= 0) {
        var mon = monitors.get(root.selected)
        monitors.setProperty(root.selected, "brightnessOriginal", mon.brightness)
      }
    }
  }

  Timer {
    id: tryTimer
    interval: 1000
    repeat: true
    onTriggered: {
      root.tryLeft = Math.max(0, root.tryLeft - 1)
      if (root.trying) root.notice = "Trying this for " + root.tryLeft + " seconds…"
    }
  }

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "monitor-play"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle { anchors.fill: parent; color: root.scrim }
    MouseArea { anchors.fill: parent; onClicked: root.dismiss() }

    BorderSurface {
      id: card
      width: Math.min(Style.space(1000), panel.width - Style.gapsOut * 2)
      height: Math.min(Style.space(860), panel.height - Style.gapsOut * 2)
      radius: root.cornerRadius
      anchors.centerIn: parent
      color: root.cardBg
      borderSpec: Border.surfaceSpec("menu", "border", Color.menu.border, Math.max(1, Style.space(2)))
      padding: Style.spacing.panelPadding

      MouseArea { anchors.fill: parent }

      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true
        Keys.priority: Keys.BeforeItem
        Keys.onEscapePressed: function(event) { root.dismiss(); event.accepted = true }
        Keys.onReturnPressed: function(event) { root.apply(); event.accepted = true }
        Keys.onEnterPressed: function(event) { root.apply(); event.accepted = true }
        Keys.onLeftPressed: function(event) { root.nudge(-32, 0); event.accepted = true }
        Keys.onRightPressed: function(event) { root.nudge(32, 0); event.accepted = true }
        Keys.onUpPressed: function(event) { root.nudge(0, -32); event.accepted = true }
        Keys.onDownPressed: function(event) { root.nudge(0, 32); event.accepted = true }
      }

      Item {
        anchors.fill: parent
        anchors.margins: Style.spacing.panelPadding

        Text {
          id: title
          text: "Monitor Play"
          color: root.fg
          font.family: root.fontFamily
          font.pixelSize: Style.font.heading
          font.bold: true
        }

        Text {
          id: hint
          anchors.top: title.bottom
          anchors.topMargin: Style.space(4)
          width: parent.width
          wrapMode: Text.WordWrap
          text: root.liveLine || "Drag a screen, then pick a resolution. Sharp fits the panel. Softer is the same shape with fewer pixels. Stretches does not match the panel."
          color: root.muted
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        Rectangle {
          id: canvas
          anchors.top: hint.bottom
          anchors.topMargin: Style.space(10)
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: controls.top
          anchors.bottomMargin: Style.space(8)
          radius: root.cornerRadius
          color: root.faint
          clip: true

          Repeater {
            model: monitors
            Rectangle {
              x: root.originX + model.lx * root.fit
              y: root.originY + model.ly * root.fit
              width: Math.max(Style.space(88), model.lw * root.fit)
              height: Math.max(Style.space(56), model.lh * root.fit)
              radius: Style.space(8)
              color: Util.alpha(root.accent, index === root.selected ? 0.34 : 0.16)
              border.width: index === root.selected ? 2 : 1
              border.color: index === root.selected ? root.accent : Util.alpha(root.fg, 0.35)

              Text {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: Style.space(8)
                text: model.label
                color: root.fg
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                font.bold: true
                elide: Text.ElideRight
              }

              Text {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                anchors.margins: Style.space(8)
                text: {
                  var mode = model.mode === "preferred"
                    ? Math.round(model.pxW) + "×" + Math.round(model.pxH)
                    : String(model.mode).replace("x", "×").replace("@", " @ ") + " Hz"
                  return mode
                }
                color: root.muted
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                elide: Text.ElideRight
              }

              MouseArea {
                anchors.fill: parent
                preventStealing: true
                property real anchorCanvasX: 0
                property real anchorCanvasY: 0
                property real anchorLx: 0
                property real anchorLy: 0
                onPressed: function(mouse) {
                  root.selected = index
                  root.dragging = true
                  var point = mapToItem(canvas, mouse.x, mouse.y)
                  anchorCanvasX = point.x
                  anchorCanvasY = point.y
                  anchorLx = model.lx
                  anchorLy = model.ly
                  root.syncChips()
                  keyCatcher.forceActiveFocus()
                }
                onPositionChanged: function(mouse) {
                  if (!pressed || root.fit < 0.0001) return
                  var point = mapToItem(canvas, mouse.x, mouse.y)
                  var nx = anchorLx + (point.x - anchorCanvasX) / root.fit
                  var ny = anchorLy + (point.y - anchorCanvasY) / root.fit
                  root.moveMonitor(index, nx, ny, model.lw, model.lh, (mouse.modifiers & Qt.ShiftModifier) !== 0)
                }
                onReleased: root.dragging = false
                onCanceled: root.dragging = false
              }
            }
          }
        }

        Column {
          id: controls
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          spacing: Style.space(6)

          Text {
            width: controls.width
            visible: root.modeNote() !== "" || root.notice !== "" || root.overlapHint !== ""
            wrapMode: Text.WordWrap
            text: root.notice !== "" ? root.notice : (root.modeNote() || root.overlapHint)
            color: root.noticeError ? Color.urgent : root.muted
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Text {
            text: {
              var mon = root.selectedMonitor()
              return mon ? mon.label + " resolution" : "Resolution"
            }
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          GridLayout {
            width: controls.width
            columns: 4
            columnSpacing: Style.space(6)
            rowSpacing: Style.space(6)
            Repeater {
              model: resolutionModel
              Chip {
                required property string key
                required property string label
                caption: label
                active: {
                  var mon = root.selectedMonitor()
                  return !!(mon && root.resolutionKey(mon) === key)
                }
                onClicked: key === "more" ? root.moreResolution() : root.selectResolution(key)
              }
            }
          }

          Text {
            text: "Refresh"
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          GridLayout {
            width: controls.width
            columns: 4
            columnSpacing: Style.space(6)
            rowSpacing: Style.space(6)
            Repeater {
              model: refreshModel
              Chip {
                required property string mode
                required property string label
                required property int advertised
                caption: label
                outlined: !advertised
                active: {
                  var mon = root.selectedMonitor()
                  return !!(mon && mon.mode === mode)
                }
                onClicked: root.setMode(mode)
              }
            }
          }

          Slider {
            width: controls.width
            label: {
              var mon = root.selectedMonitor()
              return mon ? "Scale " + root.scaleLabel(mon.scale) : "Scale"
            }
            from: 1
            to: 2
            step: 0.25
            value: {
              var mon = root.selectedMonitor()
              return mon ? mon.scale : 1
            }
            onReleased: function(next) {
              if (root.selected < 0) return
              monitors.setProperty(root.selected, "scale", next)
              root.resizeSelected()
              root.bump()
            }
          }

          GridLayout {
            width: controls.width
            columns: 4
            columnSpacing: Style.space(6)
            rowSpacing: Style.space(6)
            Chip {
              caption: {
                var mon = root.selectedMonitor()
                return mon ? "Rotate " + root.rotationLabel(mon.transform) : "Rotate"
              }
              onClicked: root.cycleTransform()
            }
            Chip {
              caption: "Adaptive"
              active: {
                var mon = root.selectedMonitor()
                return !!(mon && mon.vrr)
              }
              onClicked: root.toggleVrr()
            }
            Chip {
              caption: "8-bit"
              active: {
                var mon = root.selectedMonitor()
                return !mon || mon.bitdepth !== 10
              }
              onClicked: root.setBits(8)
            }
            Chip {
              caption: "10-bit"
              active: {
                var mon = root.selectedMonitor()
                return !!(mon && mon.bitdepth === 10)
              }
              onClicked: root.setBits(10)
            }
          }

          Slider {
            width: controls.width
            visible: {
              var mon = root.selectedMonitor()
              return !!(mon && mon.brightnessKnown)
            }
            label: {
              var mon = root.selectedMonitor()
              return mon && mon.brightnessKnown ? "Backlight " + mon.brightness : "Backlight"
            }
            from: 0
            to: 100
            step: 1
            value: {
              var mon = root.selectedMonitor()
              return mon && mon.brightnessKnown ? mon.brightness : 0
            }
            onReleased: function(next) { root.pushBrightness(next) }
          }

          GridLayout {
            width: controls.width
            columns: 3
            columnSpacing: Style.space(6)
            rowSpacing: Style.space(6)
            Chip { caption: "Stacked"; onClicked: root.arrange("stack") }
            Chip { caption: "Default"; onClicked: root.useDefault() }
            Chip { caption: "Save profile"; enabled: !root.applying; onClicked: root.saveProfile() }
            Chip {
              caption: root.trying ? ("Try " + root.tryLeft + "s") : "Try 10s"
              enabled: root.dirty && !root.applying
              onClicked: root.tryMode()
            }
            Chip { caption: "Reset"; onClicked: root.open("{}") }
            Chip {
              caption: "Apply"
              accented: true
              enabled: root.dirty && !root.applying
              onClicked: root.apply()
            }
          }
        }
      }
    }
  }
}
