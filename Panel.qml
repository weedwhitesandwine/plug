import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui
import "."

// Plug — one place to manage your community Omarchy plugins.
//
//   omarchy-shell shell toggle io.github.weedwhitesandwine.plug
//
// Three views. INSTALLED lists the third-party plugins you have, every row
// with the same four controls — update, restore, remove, on/off — and the
// update control lights green when the plugin's repository has moved past
// what you installed. Pressing it opens a REVIEW: the exact changes are read
// by the AI reviewer you chose in settings, structurally read-only, and
// reported back in plain English with a safe / be-careful / do-not traffic
// light. Restore undoes the last update Plug applied. STORE searches the
// marketplace catalog and installs. Omarchy's own plugins sit in a folded
// Official section with just the on/off switch — they are built into the
// shell, so there is nothing to update, restore or remove.
//
// The heavy lifting lives in plugd.py; this panel runs it and reads the small
// JSON files it writes, always through `head` so an oversized file is never
// pulled whole into the shell.
Item {
  id: root

  // A file this plugin reads but does not own can be anything by the time it
  // is opened: a link pointing elsewhere, a pipe that never produces anything,
  // or something far too large. `head` opens a path the ordinary way and would
  // follow the first and wait forever on the second, inside a shell process
  // that stays up for days. So the open refuses on its own terms and hands
  // back nothing at all rather than something over the ceiling. O_NOFOLLOW
  // covers the final name only — a link in a parent directory is still
  // followed, which is the same trust already placed in the home directory.
  readonly property string safeRead: [
    'import os, stat, sys',
    'path = sys.argv[1]; ceiling = int(sys.argv[2])',
    'try:',
    '    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)',
    'except FileNotFoundError:',
    '    raise SystemExit(2)',
    'except OSError:',
    '    raise SystemExit(1)',
    'try:',
    '    if not stat.S_ISREG(os.fstat(fd).st_mode):',
    '        raise SystemExit(1)',
    '    with os.fdopen(fd, "rb") as handle:',
    '        fd = None',
    '        raw = handle.read(ceiling + 1)',
    'except OSError:',
    '    raise SystemExit(1)',
    'finally:',
    '    if fd is not None:',
    '        os.close(fd)',
    'if len(raw) > ceiling:',
    '    raise SystemExit(1)',
    'sys.stdout.buffer.write(raw)'
  ].join("
")

  property bool opened: false
  readonly property string selfId: "io.github.weedwhitesandwine.plug"

  property var shell: null
  onShellChanged: {
    if (!root.opened && root.shell && root.shell.openPanelIds
        && root.shell.openPanelIds[root.selfId] === true)
      root.open("{}")
  }

  readonly property string pluginDir: {
    var u = String(Qt.resolvedUrl("."))
    return decodeURIComponent(u.replace(/^file:\/\//, "")).replace(/\/$/, "")
  }
  readonly property string home: Quickshell.env("HOME")
  readonly property string stateDir: {
    var b = Quickshell.env("XDG_STATE_HOME")
    return (b ? b : root.home + "/.local/state") + "/plug"
  }

  // ------------------------------------------------------------------ theme
  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property color scrim: Color.menu.scrim
  property color selBg: Color.menu.selectedBackground
  property color selText: Color.menu.selectedText
  property color accent: Color.accent
  property color urgent: Color.urgent
  readonly property int cornerRadius: Style.cornerRadius
  property string fontFamily: Style.font.menuFamily
  // Commands, and lines lifted out of a script, are shown at a fixed pitch so
  // what you read is shaped like what you will paste.
  property string monoFamily: "monospace"
  readonly property color dim: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.6)
  readonly property color fainter: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.35)
  readonly property color hairline: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.14)

  // Semantic colours for the verdict and trust marks — fixed, not theme, so a
  // green verdict is green on every theme. Picked for contrast on dark and
  // light alike.
  readonly property color okColor: "#3fb950"
  readonly property color warnColor: "#d29922"
  readonly property color dangerColor: "#f85149"
  // Three bands, decided by the engine from what it found, not by a number
  // computed from invented weights. Green is squeaky clean, red is code that
  // actually runs something with no innocent explanation, amber is the honest
  // middle — and `trustWhy` says which, so the colour is never the whole
  // answer.
  function trustColor(band) {
    if (band === "green") return root.okColor
    if (band === "red") return root.dangerColor
    if (band === "amber") return root.warnColor
    return root.fainter
  }
  function verdictColor(v) {
    if (v === "SAFE") return root.okColor
    if (v === "DANGER") return root.dangerColor
    return root.warnColor
  }

  // ------------------------------------------------------------------ state
  property string tab: "installed"         // installed | store | settings
  // The Store tab is the one view with a field to type into, so focus follows
  // the tab: into the search box on the way in, back to the panel on the way
  // out, where the arrow keys and shortcuts live.
  onTabChanged: Qt.callLater(function() {
    if (!root.opened) return
    if (root.tab === "store" && typeof searchInput !== "undefined") searchInput.forceActiveFocus()
    else keyCatcher.forceActiveFocus()
  })
  property var installedRows: []            // joined listPlugins + engine aux
  property var auxById: ({})                // engine state.json plugins map
  property var catalogRows: []
  property bool catalogLoaded: false
  property string storeQuery: ""
  property bool busy: false
  property string busyNote: ""
  property string noticeText: ""

  // Selection cursor into the visible list.
  property int selectedIndex: 0

  // Remove confirmation, one row at a time.
  property string confirmRemoveId: ""

  // The review overlay. reviewId is the plugin under review; reviewData is the
  // engine's review-<id>.json once it lands.
  property string reviewId: ""
  property var reviewData: null
  property bool reviewRunning: false
  // The same overlay serves two questions: "should I apply this update?" and
  // "should I install this at all?". A plugin runs as you with no sandbox, so
  // the first time its code arrives deserves the same read as every change to
  // it afterwards.
  property string reviewMode: "update"      // update | install
  property var installCandidate: null
  // Set when an install stopped because the plugin's code changed between the
  // review and the click. Nothing was installed; this drives the choice.
  property string movedName: ""
  property string movedSha: ""
  property var lastApproved: null

  // Read the newer code instead — the same review, on what is there now.
  function reviewMoved() {
    var a = root.lastApproved
    root.movedName = ""; root.movedSha = ""
    if (a && a.candidate) root.installFromStore(a.candidate)
  }
  // Take the version that was actually reviewed and approved. It is pinned to
  // that commit and switched on only once it is confirmed to be that commit,
  // so the newer code never runs.
  function installApproved() {
    var a = root.lastApproved
    root.movedName = ""; root.movedSha = ""
    if (!a || !a.repo) return
    // Stripped before it is appended, exactly as the first install does. A
    // catalog address never carries the suffix and a hand-typed one often
    // does; this is the same address arriving back through the moved-version
    // path, so without the strip an address typed with `.git` became
    // `.git.git` and resolved nowhere — the bug its sibling call already
    // documents, one line away.
    root.runJob(["install", String(a.repo).replace(/\.git$/, "") + ".git",
                 a.name, a.sha, a.id,
                 "--approved-version"], "Installing the version you approved…", a.id)
  }

  // Settings, loaded from the engine's settings.json.
  property var settings: ({ reviewAgent: "claude", reviewModel: "sonnet", autoCheck: true,
                            autoCatalog: true })
  property var availableAgents: []
  property bool settingsLoaded: false

  // A review belongs to the tab it was started from, and Settings is a
  // legitimate place to go while one is waiting — checking which reviewer is
  // configured before approving is exactly the kind of thing you want to be
  // able to do. So on Settings the overlay steps aside and comes back when you
  // leave, rather than painting on top of the settings and leaving Enter bound
  // to an install nobody can see.
  readonly property bool reviewOnScreen: root.reviewId !== "" && root.tab !== "settings"

  // Update count drives the header badge and the bar widget badge.
  readonly property int updateCount: {
    var n = 0
    for (var i = 0; i < root.installedRows.length; i++)
      if (root.installedRows[i].updateAvailable) n++
    return n
  }
  onUpdateCountChanged: PlugState.updateCount = root.updateCount

  // --------------------------------------------------------------- lifecycle
  // A job that had to run outside the panel summons Plug back when it is done
  // and hands over what happened: the row it acted on, and either a notice or
  // the error the command printed. So the panel reappears on the plugin you
  // touched with the result on screen, instead of just vanishing mid-action.
  property string pendingHighlight: ""
  function open(payloadJson) {
    root.opened = true
    root.tab = "installed"
    root.selectedIndex = 0
    root.confirmRemoveId = ""
    // A detached job ends by summoning Plug, which lands here. If a Store
    // install-review was on screen the overlay went away but the MODE did
    // not, so the next press of update on an installed row ran an install of
    // the old store plugin instead. Clear the whole review, not its surface.
    root.cancelReview()
    root.noticeText = ""
    root.pendingHighlight = ""
    root.clearJob()
    if (!payloadJson || String(payloadJson) === "{}") {
      root.movedName = ""; root.movedSha = ""
    }
    jobWatchdog.stop()
    jobPoll.stop(); root.jobPollsLeft = 0
    var payload = null
    try { payload = JSON.parse(String(payloadJson || "")) } catch (e) { payload = null }
    if (payload && typeof payload === "object") {
      // A payload carrying anything means a job just reported back. The shell
      // updates its own registry a moment after the change lands, so a single
      // read here can arrive before the answer has changed — and with nothing
      // asking again, a switch kept its old position until the panel was
      // closed and reopened. Ask a few more times, whoever started the job. A
      // plain open carries nothing and is left alone: each of these re-scans
      // every installed plugin.
      if (payload.notice || payload.error || payload.highlight) {
        root.jobPollsLeft = 6
        jobPoll.restart()
      }
      if (payload.highlight) root.pendingHighlight = String(payload.highlight)
      // A job says where it was started from, and the panel comes back there.
      // Everything that reports through this door landed on the Installed tab
      // regardless, so showing or hiding the bar icon — which can only be
      // pressed in Settings — threw the user out of Settings on success. The
      // panel reopening somewhere the user did not go is a small thing that
      // reads as a bug every time.
      if (payload.tab === "settings" || payload.tab === "store"
          || payload.tab === "installed")
        root.tab = String(payload.tab)
      if (payload.error && String(payload.error).indexOf("MOVED\t") === 0) {
        // Nothing was installed. The author pushed since the review, so the
        // choice is the user's: read the new version, or take the one they
        // already approved.
        var bits = String(payload.error).split("\t")
        root.movedName = bits.length > 1 && bits[1] !== "" ? bits[1] : "That plugin"
        root.movedSha = bits.length > 2 ? bits[2] : ""
        root.noticeText = ""
      } else if (payload.error) {
        root.noticeText = String(payload.error).trim().split("\n").pop()
      }
      else if (payload.notice) root.noticeText = String(payload.notice)
    }
    // refreshAll() is driven by `opened` changing, which the line above has
    // just done. Calling it here as well ran the whole scan of every
    // installed plugin two and three times over on a single summon.
    // Freshen the update flags in the background so they are current without
    // pressing the button — offline flags show immediately, the network check
    // updates them a moment later.
    if (root.settings.autoCheck !== false) autoCheckTimer.restart()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  Timer { id: autoCheckTimer; interval: 500; onTriggered: if (root.opened) root.checkUpdates() }

  // The host's hide() calls close() back before it clears its own record of
  // the panel being open, so an unguarded close() recurses — close, hide,
  // close — until the JS stack gives out, inside a shell that stays up for
  // days. Pressing Escape was enough. Being closed already is the exit.
  function close() {
    if (!root.opened) return
    root.opened = false
    root.confirmRemoveId = ""
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide(root.selfId)
  }

  function toggle() { if (root.opened) root.close(); else root.open("{}") }

  Component.onCompleted: {
    PlugState.overlay = root
    root.loadSettings()
    root.loadCatalog()
    root.loadBinds()
  }

  onOpenedChanged: if (root.opened) root.refreshAll()

  // -------------------------------------------------------------- data flow
  // The live installed list comes from the shell; the git/update/trust layer
  // comes from the engine's state.json. They are joined by id. First-party
  // plugins are dropped here and never appear again.
  // A scan of a full plugin folder takes well over a second; the poll behind a
  // finished job asks every 700ms. Restarting the process on each ask killed
  // every scan before it could write its answer, so a job could poll for four
  // seconds and re-read precisely nothing — the list went on showing the update
  // it had just applied until the next upstream check rewrote the file some
  // seconds later, with the button green for all of it.
  //
  // Skipping the ask instead is no better, only quieter: turning a plugin on or
  // off asks exactly once, from a runner that carries no poll and no watchdog
  // behind it, so the one ask that mattered could land inside a scan that had
  // started BEFORE the toggle and be dropped — leaving the switch showing the
  // position the user had just changed away from, with nothing due to ask
  // again.
  //
  // So neither kill it nor drop it: remember it. A request arriving during a
  // scan is served the moment that scan finishes, which is also the earliest
  // moment it could have produced a fresh answer anyway.
  //
  // Both readers work this way, for the same reason and with different stakes.
  // The plugin list is the shorter of the two, but it is where the on/off
  // switch gets its position — so restarting it on every ask meant each poll
  // killed the previous read and handed a truncated line to JSON.parse, which
  // threw into an empty catch. Only the last read of a burst ever landed, and
  // until it did, the switch showed the position the user had just changed
  // away from. The symptom the scan comment describes, on the other reader.
  property bool snapshotPending: false
  property bool listPending: false

  function refreshAll() {
    // Read the state file we already have before scanning for a new one.
    //
    // A row's on/off position is a join of two sources: the shell's own list,
    // which answers in milliseconds, and this file, which the scan rewrites a
    // second and a half later. The shell reports a plugin whose bar icon is
    // hidden as disabled — it is enabled, it simply has no place in the bar —
    // and the correction to that lives here, in `iconHidden`. Nothing read
    // this file until the scan finished, so for the first second and a half
    // of every open, the join ran with one half missing and every
    // icon-hidden plugin was drawn as OFF, then flipped ON when the scan
    // landed. This costs a file read of something already on disk, and it is
    // the difference between the panel opening correct and opening wrong.
    root.readState()
    if (listProc.running) root.listPending = true
    else { root.listPending = false; listProc.running = true }
    if (snapshotProc.running) root.snapshotPending = true
    else root.startSnapshot()
  }

  // Core shell infrastructure that is always on and has no meaningful switch,
  // so it is hidden from the Official section entirely.
  readonly property var hiddenFirstParty: ({
    "omarchy.bar": true, "omarchy.polkit": true, "omarchy.lock": true,
    "omarchy.idle": true, "omarchy.notifications": true, "omarchy.osd": true,
    "omarchy.launcher": true, "omarchy.menu": true, "omarchy.background": true,
    "omarchy.clipboard": true, "omarchy.image-picker": true, "omarchy.spacer": true
  })

  function rebuildInstalled() {
    var live = root.livePlugins || []
    var aux = root.auxById || {}
    var out = []
    var official = []
    for (var i = 0; i < live.length; i++) {
      var p = live[i]
      if (p.id === root.selfId) continue            // Plug does not manage itself
      if (p.firstParty === true) {
        // Omarchy's own. Show only the optional bar widgets that can actually
        // be toggled — never the core infrastructure — and never removable.
        if (root.hiddenFirstParty[p.id]) continue
        if (p.canDisable === false) continue
        if (!(p.kinds && p.kinds.indexOf("bar-widget") >= 0)) continue
        official.push({
          id: p.id, name: p.name || p.id, official: true,
          kinds: (p.kinds || []).join(", "),
          enabled: p.enabled === true, canDisable: true,
          // Explicit falses: a QML `visible:` binding that evaluates to
          // undefined falls back to its default (true), which would wrongly
          // light up these badges on built-in plugins.
          updateAvailable: false, canRevert: false, iconHidden: false,
          hasInstallScript: false,
          trustBand: "", trustWhy: "", capabilities: [], commitsBehind: 0
        })
        continue
      }
      var a = aux[p.id] || {}
      out.push({
        id: p.id,
        name: p.name || a.name || p.id,
        author: a.author || "",
        kinds: (p.kinds || []).join(", "),
        official: false,
        enabled: p.enabled === true || a.iconHidden === true,
        canDisable: p.canDisable !== false,
        // The shell calls a bar widget enabled only when it has a place in
        // the bar, so a plugin whose icon its owner switched off reports as
        // disabled while running perfectly well. It is on; its icon is not.
        iconHidden: a.iconHidden === true,
        hasInstallScript: a.hasInstallScript === true,
        updateAvailable: a.updateAvailable === true,
        commitsBehind: a.commitsBehind || 0,
        trustBand: a.trustBand || "",
        trustWhy: a.trustWhy || "",
        capabilities: a.capabilities || [],
        isGit: a.isGit === true,
        remote: a.remote || "",
        canRevert: (a.previousSha || "") !== ""
      })
    }
    out.sort(function(x, y) {
      if (x.updateAvailable !== y.updateAvailable) return x.updateAvailable ? -1 : 1
      return x.name.toLowerCase() < y.name.toLowerCase() ? -1 : 1
    })
    official.sort(function(x, y) { return x.name.toLowerCase() < y.name.toLowerCase() ? -1 : 1 })
    root.installedRows = out
    root.officialRows = official
    if (root.pendingHighlight !== "") {
      for (var h = 0; h < out.length; h++) {
        if (out[h].id === root.pendingHighlight) { root.selectedIndex = h; break }
      }
      root.pendingHighlight = ""
    }
    if (root.selectedIndex >= out.length) root.selectedIndex = Math.max(0, out.length - 1)
  }

  property var livePlugins: []
  property var officialRows: []
  // Both sections fold. Community is open by default (it is what you came for);
  // official is folded by default — it is long, rarely touched, and would
  // otherwise push the community plugins off the top.
  property bool communityExpanded: true
  property bool officialExpanded: false

  Process {
    id: listProc
    // Capped at the read like everything else. The shell is first-party and
    // this has never been the risk, but a StdioCollector has no ceiling of its
    // own, so an answer that grew unexpectedly would arrive whole inside a
    // process that stays up for days. The house rule is that reads have a
    // ceiling at the read, and a rule with an exception in it is a habit.
    command: ["bash", "-c",
              "omarchy-shell shell listPlugins | head -c " + root.stateCeiling]
    onExited: if (root.listPending) { root.listPending = false; listProc.running = true }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var arr = JSON.parse(text)
          if (Array.isArray(arr)) { root.livePlugins = arr; root.rebuildInstalled() }
        } catch (e) {}
      }
    }
  }

  // snapshot writes state.json; we read it back through head. It is offline,
  // but it is not fast — well over a second across a full plugin folder.
  Process {
    id: snapshotProc
    command: ["python3", root.pluginDir + "/plugd.py", "snapshot"]
    onExited: {
      snapshotStall.stop()
      root.snapshotKills = 0
      root.readState()
      // Somebody asked while this one was running. Serve it now.
      if (root.snapshotPending) { root.snapshotPending = false; root.startSnapshot() }
    }
    stdout: StdioCollector { waitForEnd: true }
  }

  // Starting the scan and starting the clock on it are one action, so they are
  // written as one. Arming the timer from `runningChanged` looked equivalent
  // and was not: that signal is emitted when the child has actually started, so
  // a python3 that hung on the way to exec — the stalled-mount case this timer
  // exists for — never armed it at all, and the wait it was meant to bound had
  // no end after all.
  property int snapshotKills: 0
  function startSnapshot() {
    root.snapshotPending = false
    // Each scan starts with a clean count. A process that fails to start emits
    // no `exited` at all, so a count left over from one would have had the next
    // genuinely-stuck scan killed outright on its first tick, with none of the
    // grace this is supposed to begin with.
    root.snapshotKills = 0
    snapshotProc.running = true
    snapshotStall.restart()
  }

  // Waiting on a scan is only safe if the wait can end. The engine allows each
  // git call 25 seconds, and makes several per plugin, so a plugin folder on a
  // stalled mount can hold this process for minutes — and a process that never
  // exits would hold it for the life of the shell, with every later refresh
  // waiting behind a scan that is never coming back. Nothing else in the panel
  // would recover it: not closing and reopening, not the job watchdog. So the
  // wait has its own end.
  //
  // The interval is set against the engine's own worst case rather than against
  // a healthy scan. A scan makes up to six git calls per plugin, each allowed
  // 25 seconds plus a 5 second wait, so one plugin on an unresponsive mount can
  // legitimately occupy about three minutes. An interval below that kills scans
  // that were merely slow — and a killed scan never reaches its write, so the
  // panel goes on reading the old file believing it is current, which is the
  // exact failure this whole area exists to prevent. Late is recoverable;
  // wrong is not. It cannot tell slow from wedged, and when it cannot tell it
  // waits.
  //
  // Sized for one such plugin, not for several. Two checkouts on the same dead
  // mount legitimately need longer than this and would be cut off — accepted,
  // because the alternative is an interval long enough that a genuinely wedged
  // scan blocks every refresh for the better part of a quarter of an hour. A
  // desktop with two plugins on a dead mount has a bigger problem than a stale
  // switch position.
  //
  // It repeats because asking a process to stop is a request, not an outcome.
  // The first ask is a SIGTERM; a process still there at the next tick is
  // sent SIGKILL, which it cannot decline — except in uninterruptible I/O,
  // where nothing would have helped and no signal is the answer.
  //
  // A refresh that arrived while the scan was running is deliberately NOT
  // dropped here: it is newer than the scan being abandoned, so it is left
  // standing for whichever exit finally lands.
  Timer {
    id: snapshotStall
    interval: 240000
    repeat: true
    onTriggered: {
      // A process that never started emits no exit, so nothing would ever stop
      // this timer: it would tick against a null process for the life of the
      // shell. Nothing running means nothing to wait for.
      if (!snapshotProc.running) { snapshotStall.stop(); root.snapshotKills = 0; return }
      root.snapshotKills += 1
      if (root.snapshotKills <= 1) snapshotProc.running = false
      else if (typeof snapshotProc.signal === "function") snapshotProc.signal(9)
      else snapshotProc.running = false
    }
  }

  readonly property int stateCeiling: 4 * 1024 * 1024
  // The third reader, coalesced like the other two. This one self-corrected —
  // a killed read delivers its truncated buffer, JSON.parse throws, the catch
  // swallows it and the restart brings the real answer — so it was left alone
  // once. That is an argument for it being survivable, not for it being right:
  // it still spends a process and swallows an exception every time two callers
  // land together, and both `snapshotProc` and `checkProc` call it on exit.
  // Three readers, one shape.
  property bool statePending: false
  function readState() {
    if (stateReader.running) root.statePending = true
    else { root.statePending = false; stateReader.running = true }
  }
  Process {
    id: stateReader
    command: ["python3", "-c", root.safeRead,
              root.stateDir + "/state.json", String(root.stateCeiling)]
    onExited: if (root.statePending) { root.statePending = false; stateReader.running = true }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var s = JSON.parse(text)
          if (s && typeof s === "object" && s.plugins) {
            root.auxById = s.plugins
            root.rebuildInstalled()
          }
        } catch (e) {}
      }
    }
  }

  // The one network step behind the update flag.
  // The footer line has more than one writer, and they finish in whatever
  // order their processes do. A check started on open runs for as long as the
  // network takes, so it routinely finishes in the middle of whatever the user
  // did next — and both ends of it used to write the shared line
  // unconditionally, so it announced itself over a job already in progress and
  // then blanked that job's note on the way out. A job is the more important
  // thing to be reporting and it is the one with an end the user is waiting
  // for, so the check defers to it at both ends rather than fighting it.
  function checkUpdates() {
    if (!root.jobRunning) { root.busy = true; root.busyNote = "Checking for updates…" }
    checkProc.running = false; checkProc.running = true
  }
  // Set once a network check has actually completed, so "no updates" is only
  // shown after we have looked — not before the first check on open.
  property bool updatesChecked: false
  Process {
    id: checkProc
    command: ["python3", root.pluginDir + "/plugd.py", "check-updates"]
    onExited: {
      if (!root.jobRunning) { root.busy = false; root.busyNote = "" }
      root.updatesChecked = true; root.readState()
    }
    stdout: StdioCollector { waitForEnd: true }
  }

  // --------------------------------------------------------- enable/disable
  // ------------------------------------------------------------- the jobs
  //
  // Installing, removing, updating, restoring and toggling all end with the
  // shell reloading its plugins, and a reload unloads every open panel — this
  // one included. Anything run from inside the panel is therefore killed at
  // the exact moment its work lands, which is how a removal could delete a
  // plugin and still report nothing at all. So every one of them is handed to
  // plug-ctl.sh, detached: it outlives this window, finishes the job, and
  // summons Plug back with the result. That also covers Plug updating itself.
  // Which row a job is running on, and nothing else. It exists to take the
  // press away while work is already in flight — the controls are reading a
  // state file written before the job started, so acting on them acts on an
  // answer that is already out of date. It deliberately carries no label,
  // colour or wording: an earlier version of this described the job as well as
  // guarding it, and the description was wrong in every case the guard was
  // right about — "done" on a restore that had correctly become updatable
  // again, a reload notice on the one job that does not reload. Guarding and
  // narrating are separate problems; this is the guard.
  property string jobId: ""

  // And it guards every row, not the one it names.
  //
  // Guarding only the row a job was running on looked obviously right and was
  // wrong, because the things being guarded are shared. There is one
  // `toggleProc` for the whole list, one `busyNote`, one `jobId`. Pressing a
  // second row's switch while the first was still working did not start a
  // second job — it swapped the command out from under the running one and
  // overwrote the id, so the first run's failure was reported against the
  // second plugin's name, and the second command then started with no guard,
  // no watchdog and nothing left to report it against.
  //
  // A job is a whole-panel condition. The panel says so.
  //
  // And where the work is a process this panel actually holds, the process
  // itself is the authority — not a flag a timer can clear. Every previous
  // version of this guard was released by something other than the work
  // finishing: a poll running out of asks, a watchdog set below the job's own
  // worst case, a summon arriving from an unrelated job and resetting the
  // panel. Each of those released a guard while the runner was still moving
  // state, and each reopened the same corridor — a second press swapping the
  // command out from under a live run, so the first run's failure is reported
  // against the second plugin's name and the second command runs unguarded.
  // A running process cannot be argued with, so it is asked directly.
  readonly property bool jobRunning: root.jobId !== "" || toggleProc.running

  function clearJob() {
    root.busy = false; root.busyNote = ""
    root.jobId = ""
    // The backstop exists to release the guard; releasing it here leaves the
    // backstop with nothing to do but fire later and scan for no reason.
    jobWatchdog.stop()
  }

  // Refused here rather than at each button, because the buttons were never
  // the whole set. The row controls were guarded and the Store's install, the
  // review's apply, the restore and the moved-version reinstall were not — so
  // an install running from the Store could be joined by an apply from a
  // review, each overwriting the other's id and re-arming the shared watchdog,
  // and the first to report cleared the guard belonging to the second. This is
  // the one door all of them go through. Anything added later gets the guard
  // whether or not its author remembered to ask for one.
  function runJob(args, note, id) {
    if (root.jobRunning) {
      root.noticeText = "Something is already running — wait for it to finish."
      return
    }
    root.busy = true; root.busyNote = note
    root.jobId = id ? String(id) : ""
    jobWatchdog.restart()
    root.jobPollsLeft = 8
    jobPoll.restart()
    Quickshell.execDetached(["bash", root.pluginDir + "/plug-ctl.sh"].concat(args))
  }

  // A job that unloads the panel is followed by a summon, which reopens it and
  // re-reads everything. A job that does NOT — switching a plugin on or off —
  // leaves the panel standing, and summoning something already on screen does
  // nothing, so nothing was re-read: the switch kept its old position until the
  // panel was closed and opened again. The work happens in another process, so
  // the answer is not ready the moment the click lands; ask a few times.
  property int jobPollsLeft: 0
  Timer {
    id: jobPoll
    interval: 700
    repeat: true
    onTriggered: {
      root.refreshAll()
      root.jobPollsLeft -= 1
      if (root.jobPollsLeft <= 0) {
        stop()
        // The polling is over; the job is not necessarily. Running out of
        // asks means the answer has not arrived yet, which is the worst
        // possible moment to re-arm the row — the data behind those controls
        // is still the data from before the job started. So the spinner goes
        // and the guard stays, until the watchdog decides the runner is never
        // reporting, or the summon that ends the job clears it properly.
        root.busy = false; root.busyNote = ""
      }
    }
  }
  // A job that unloads the panel takes this state with it, and the summon that
  // follows clears it. A job that does not — toggling a plugin with no window
  // of its own — leaves the panel standing, so the wait cannot be left to hang
  // on a runner that died without reporting.
  //
  // Sized above the slowest job rather than above a typical one. Twenty
  // seconds was under the worst case of nearly everything here: an install
  // clones a repository over the network with no timeout of its own, and the
  // still-at check alone can spend twenty-five. So the guard was routinely
  // released while the job was still moving state — every row re-arming
  // against pre-job data, and a second job free to start while the first was
  // still writing shell.json and the plugins directory. That is the corridor
  // the guard exists to close, opened by the guard's own backstop.
  //
  // Being generous costs little, because this is not the only way out: a job
  // that finishes summons the panel and `open()` clears the guard, and a user
  // who closes and reopens the panel clears it too. The timer is the last
  // resort for a runner that dies silently, and a last resort should not fire
  // while the thing it is watching is still working.
  Timer {
    id: jobWatchdog
    interval: 180000
    onTriggered: {
      // The attached runner is bounded by this too. `jobRunning` reads that
      // process precisely so a timer cannot release the guard out from under
      // live work — which means a runner that hangs would hold every control
      // in the panel refused for the life of the shell, with `open()` unable
      // to help because it clears the flag and not the process. Whatever this
      // timer is willing to stop believing in, it has to be willing to stop.
      toggleProc.running = false
      root.clearJob(); root.refreshAll()
    }
  }

  // Switching a plugin on or off tears nothing down — unlike installing,
  // removing, updating or restoring, each of which ends with the shell
  // reloading and this panel with it. So this one is run attached and waited
  // for, and the state is re-read when the command has actually returned.
  // Detaching it meant reading once on a timer and hoping the shell had caught
  // up, which it often had not: the switch kept its old position until the
  // panel was closed and reopened.
  //
  // The exception is a plugin that owns a panel of its own: toggling one of
  // those rebuilds every panel delegate and takes this window with it, so
  // there is nothing left to receive the answer. Those keep the detached
  // runner, which summons Plug back when it is done.
  function ownsAPanel(id) {
    for (var i = 0; i < root.livePlugins.length; i++) {
      var p = root.livePlugins[i]
      if (p.id !== id) continue
      var k = p.kinds || []
      return k.indexOf("panel") >= 0 || k.indexOf("overlay") >= 0 || k.indexOf("menu") >= 0
    }
    return false
  }

  function setEnabled(id, on) {
    // Refuse while any job is running, not just one on this row. `toggleProc`
    // is a single process shared by every row: a second call swaps its command
    // and its id, so the run in flight finishes and reports itself under the
    // new row's name, and the new command then starts unguarded. A control is
    // not where a guard belongs anyway — the keyboard arrives here too, and so
    // will anything added later.
    if (root.jobRunning) return
    if (root.ownsAPanel(id)) {
      root.runJob([on ? "enable" : "disable", id], (on ? "Enabling" : "Disabling") + "…", id)
      return
    }
    root.busy = true
    root.busyNote = (on ? "Enabling" : "Disabling") + "…"
    root.togglingId = id
    // The same flag the detached jobs raise. This runner is attached and keeps
    // the panel standing, so its row is on screen for the whole run and needs
    // the guard more than they do, not less.
    //
    // The watchdog is a backstop for the note and the id, not for the guard:
    // this job's own worst case is a shell answering slowly through up to
    // seventeen bounded IPC calls, which outlasts twenty seconds, so the
    // watchdog can and does fire mid-run. All it costs is the footer note —
    // `jobRunning` reads the process, which is still there.
    root.jobId = id
    jobWatchdog.restart()
    toggleProc.command = ["bash", root.pluginDir + "/plug-ctl.sh",
                          on ? "enable" : "disable", id, "--attached"]
    toggleProc.running = true
  }

  property string togglingId: ""
  Process {
    id: toggleProc
    stderr: StdioCollector { id: toggleErr; waitForEnd: true }
    onExited: function(code) {
      root.clearJob()
      var err = (toggleErr.text || "").trim().split("\n").pop()
      root.noticeText = code === 0
        ? "" : ("Could not switch " + root.togglingId + (err ? " — " + err : ""))
      root.pendingHighlight = root.togglingId
      root.togglingId = ""
      // Read what actually happened, now that it has finished happening — and
      // then ask again a few times. Disabling verifies through the shell's
      // config, which is not the same thing the switch reads: the switch reads
      // `listPlugins`, whose enabled flag can lag the config it was derived
      // from. This path used to get the summon's six retries for free and now
      // does not, so it asks for its own; each is cheap and they stop on their
      // own. Enabling needs it less — plug-ctl confirms that one through
      // `listPlugins` itself — but the cost of asking twice more is nothing
      // against a switch left showing the position the user just left.
      root.jobPollsLeft = 4
      jobPoll.restart()
      root.refreshAll()
    }
  }

  // ------------------------------------------------------------------ remove
  function askRemove(id) { root.confirmRemoveId = id }
  function removeConfirmed(id) {
    root.confirmRemoveId = ""
    root.runJob(["remove", id], "Removing…", id)
  }

  // ------------------------------------------------------------------ update
  // The review gate. Running review invokes the chosen AI agent read-only on
  // the diff; when it lands we read review-<id>.json and show the verdict.
  function startReview(id) {
    // A new read starts with no cancellation outstanding. The flag says "the
    // answer about to arrive is the wreckage of something you stopped"; left
    // set, it made the NEXT unreadable answer disappear silently instead.
    root.reviewCancelled = 0
    root.reviewMode = "update"
    root.installCandidate = null
    root.reviewId = id
    root.reviewData = null
    root.reviewRunning = true
    reviewProc.command = ["python3", root.pluginDir + "/plugd.py", "review", id]
    reviewProc.running = false; reviewProc.running = true
  }
  // The review command prints the whole review record on stdout, so we read
  // it straight from there — no filename to keep in sync with the engine.
  Process {
    id: reviewProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var d = JSON.parse(text)
          if (d && d.review) root.reviewData = d
          else if (d && d.error) {
            root.noticeText = "Review failed: " + d.error
            root.cancelReview()
          }
        } catch (e) {
          // Same rule as the other reader: a read the user stopped is not a
          // read that failed, and the flag is consumed here either way rather
          // than left standing to swallow the next real one.
          if (root.reviewCancelled > 0) root.reviewCancelled -= 1
          else root.noticeText = "Could not read the review result"
        }
      }
    }
    stderr: StdioCollector { waitForEnd: true }
    onExited: root.reviewRunning = false
  }

  // The install carries the commit that was actually read, not just the
  // address it was read from — an address points at whatever is there when
  // something looks, a commit is the code the reviewer judged.
  function approveUpdate(approvedVersion) {
    if (!root.reviewId) return
    if (root.reviewMode === "install") {
      var c = root.installCandidate
      var d = root.reviewData
      var sha = d && d.sha ? String(d.sha) : ""
      var pid = d && d.id ? String(d.id) : (c && c.id ? String(c.id) : "")
      var nm = c && c.name ? c.name : (d && d.name ? d.name : "plugin")
      var repo = c && c.repo ? c.repo : (d && d.url ? d.url : "")
      root.cancelReview()
      if (repo) {
        root.lastApproved = { repo: repo, name: nm, sha: sha, id: pid,
                              candidate: c }
        // A catalog address never carries the suffix; one typed in by hand
        // often does, and appending a second made an address that resolves
        // nowhere.
        var args = ["install", String(repo).replace(/\.git$/, "") + ".git",
                    nm, sha, pid]
        if (approvedVersion === true) args.push("--approved-version")
        root.runJob(args, "Installing " + nm + "…", pid)
      }
      return
    }
    var id = root.reviewId
    root.reviewId = ""; root.reviewData = null
    root.runJob(["apply", id], "Applying update…", id)
  }

  function cancelReview() {
    root.reviewId = ""; root.reviewData = null; root.reviewRunning = false
    root.reviewMode = "update"; root.installCandidate = null
    // Stop the work, not just the screen showing it. Backing out of a review
    // cleared the panel's state and left the engine running: a clone bounded
    // at 64 MB on disk is still 64 MB of text to walk character by character,
    // and a repository built to be slow to scan could hold a core busy behind
    // a panel the user had already closed, with nothing able to end it. Escape
    // should mean escape.
    //
    // The engine takes the stop as an ordinary exit and deletes its clone on
    // the way out. What it cannot do is finish the sentence it was writing, so
    // the collector delivers a partial answer a moment later — expected here,
    // and not an error to report.
    // Counted, not flagged. Cancelling while both an inspect and a review were
    // running set one boolean, the first collector to report consumed it, and
    // the second then announced a failure for something the user had stopped.
    if (inspectProc.running) root.reviewCancelled += 1
    if (reviewProc.running) root.reviewCancelled += 1
    inspectProc.running = false
    reviewProc.running = false
  }
  // How many stopped engine processes are still owed an unreadable answer.
  property int reviewCancelled: 0

  // Undo the last applied update — the version to return to was recorded when
  // the update was applied.
  function revert(id) {
    root.runJob(["rollback", id], "Restoring…", id)
  }

  // ------------------------------------------------------------------ store
  //
  // Reading the saved catalog and fetching a new one are deliberately two
  // different things. Startup reads what is on disk and touches the network
  // not at all — Plug must not reach out because the shell started. A fetch
  // happens only when you open the Store, which is the trigger that already
  // fetched, and only if what is saved has aged out; or when you ask for one
  // by hand. There is no timer: nothing here fetches while you are not
  // looking at it.
  readonly property int catalogMaxAgeMs: 6 * 60 * 60 * 1000
  property string catalogFetchedAt: ""
  property bool catalogRefreshing: false
  property bool catalogQuiet: false
  // A function rather than a binding: this answer depends on the clock, and a
  // binding would cache the first answer for as long as the panel stayed open.
  function catalogIsStale() {
    if (!root.catalogLoaded) return true
    var t = Date.parse(root.catalogFetchedAt)
    if (isNaN(t)) return true
    return (Date.now() - t) > root.catalogMaxAgeMs
  }
  function loadCatalog() {
    catalogReader.running = false; catalogReader.running = true
  }
  function refreshCatalog(quiet) {
    if (root.catalogRefreshing) return
    root.catalogRefreshing = true
    root.catalogQuiet = (quiet === true)
    // The shared busy flag drives the footer for things you pressed. A
    // refresh happening behind the rows you are already reading must not
    // borrow it, or Plug looks like it has hung on something you asked for.
    // A job in flight owns the line for the same reason a quiet refresh does
    // not take it: it is the thing the user is waiting on.
    if (!root.catalogQuiet && !root.jobRunning) { root.busy = true; root.busyNote = "Fetching catalog…" }
    catalogFetch.running = false; catalogFetch.running = true
  }
  // Opening the Store: fetch if there is nothing to show, otherwise refresh
  // quietly underneath the rows already on screen.
  function openStore() {
    root.tab = "store"
    if (!root.catalogLoaded) root.refreshCatalog(false)
    else if (root.catalogIsStale() && root.settings.autoCatalog !== false) root.refreshCatalog(true)
  }
  Process {
    id: catalogFetch
    command: ["python3", root.pluginDir + "/plugd.py", "catalog"]
    onExited: {
      root.catalogRefreshing = false
      if (!root.jobRunning) { root.busy = false; root.busyNote = "" }
      // The engine writes the saved copy only on success, so a failed fetch
      // leaves the Store working on what it already had. Say that, rather
      // than leaving a stale list looking current.
      // Unreachable, too large and unreadable are three different problems
      // with three different answers, and the engine already knows which one
      // it hit. Flattening them into one line about the network sends you
      // looking in the wrong place.
      var ok = false, why = "", trimmed = false
      try {
        var d = JSON.parse(catalogFetchOut.text)
        ok = d.ok === true
        // From THIS fetch's own answer, not from the flag left by the last
        // file that was read back.
        trimmed = d.truncated === true
        if (!ok && typeof d.error === "string")
          why = d.error.replace(/\s+/g, " ").trim().slice(0, 160)
      } catch (e) {}
      if (!ok)
        // "showing the saved copy" is only true when there is one. On a first
        // run there is nothing to fall back to, and the Store says so itself.
        root.noticeText = "Catalog not updated: "
          + (why === "" ? "no reason given" : why)
          + (root.catalogLoaded ? " — showing the saved copy" : "")
      // A trimmed list is a fact about what you are looking at, not a progress
      // message, so it is said even on a background refresh that otherwise
      // keeps quiet — the whole point of `catalogQuiet` is to avoid announcing
      // work nobody asked for, and "some of this list is missing" is not that.
      else if (trimmed)
        root.noticeText = "Catalog updated — too large to show in full, so the end of the list was left out"
      else if (!root.catalogQuiet) root.noticeText = "Catalog updated"
      root.loadCatalog()
    }
    stdout: StdioCollector { id: catalogFetchOut; waitForEnd: true }
  }
  readonly property int catalogCeiling: 8 * 1024 * 1024
  Process {
    id: catalogReader
    command: ["python3", "-c", root.safeRead,
              root.stateDir + "/catalog.json", String(root.catalogCeiling)]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var d = JSON.parse(text)
          if (d && Array.isArray(d.plugins)) {
            root.catalogRows = d.plugins
            root.catalogFetchedAt = (typeof d.fetchedAt === "string") ? d.fetchedAt : ""
            root.catalogLoaded = true
          }
        } catch (e) {}
      }
    }
  }

  readonly property var installedIdSet: {
    var s = ({})
    for (var i = 0; i < root.installedRows.length; i++) s[root.installedRows[i].id] = true
    return s
  }
  // Community plugins first, then Omarchy's own built-ins (marked OFFICIAL),
  // so the two are visibly separated the way the list reads.
  readonly property var storeFiltered: {
    var q = root.storeQuery.trim().toLowerCase()
    var comm = []
    var off = []
    for (var i = 0; i < root.catalogRows.length; i++) {
      var c = root.catalogRows[i]
      if (q !== "") {
        var hay = (c.name + " " + c.author + " " + c.description + " "
                   + (c.tags || []).join(" ")).toLowerCase()
        if (hay.indexOf(q) < 0) continue
      }
      if (c.official) off.push(c)
      else comm.push(c)
    }
    return comm.concat(off)
  }
  // Open a catalog entry's own repository page. The catalog is fetched from
  // the internet, so its addresses are data: each one is checked against a
  // plain https shape before it is handed over, and it is passed as an
  // argument rather than through a shell, so nothing else can be opened.
  readonly property var repoUrlPattern:
    /^https:\/\/[A-Za-z0-9._~-]+(\.[A-Za-z0-9._~-]+)+(\/[A-Za-z0-9._~%\/-]*)?$/
  function openRepo(c) {
    if (!c || !c.repo) return
    var u = String(c.repo)
    if (u.length > 300 || !root.repoUrlPattern.test(u)) {
      root.noticeText = "No usable repository address for " + (c.name || "that plugin")
      return
    }
    Quickshell.execDetached(["xdg-open", u])
    root.noticeText = "Opened " + (c.name || u) + " in your browser"
  }

  // A repository that is not in the catalog, pasted in by hand. Plenty of
  // plugins are never listed — a prize on omarchy.org, a link in a forum, a
  // friend's repo — and those were the ones Plug could not read, which is
  // backwards: an unlisted plugin has had less scrutiny, not more. The engine
  // never needed the catalog for this (`inspect` has always taken an address
  // and cloned it to a throwaway directory); what was missing was a way to
  // reach it.
  readonly property bool queryIsUrl: {
    var q = root.storeQuery.trim()
    return q.length > 0 && q.length <= 300 && root.repoUrlPattern.test(q)
  }
  function checkUrl(u) {
    root.reviewCancelled = 0
    var url = String(u || "").trim().replace(/\/+$/, "")
    if (url.length > 300 || !root.repoUrlPattern.test(url)) {
      root.noticeText = "That is not a repository address Plug can read"
      return
    }
    root.reviewMode = "install"
    // Named from the address until the manifest says otherwise — the engine
    // reads the real name out of the clone.
    root.installCandidate = { repo: url, name: url.split("/").pop(),
                              id: "", typed: true }
    root.reviewId = root.installCandidate.name
    root.reviewData = null
    root.reviewRunning = true
    inspectProc.command = ["python3", root.pluginDir + "/plugd.py", "inspect", url]
    inspectProc.running = false; inspectProc.running = true
  }
  // The commands that finish a manual install, for the clipboard. Built from
  // the plugin's own id and the script the scan actually found, so it is the
  // real path rather than a worked example.
  // The commands are pinned to the commit that was reviewed, and they do not
  // switch the plugin on.
  //
  // What this card used to hand over was `omarchy plugin add <url> --enable`,
  // immediately below a review of one exact commit — an address, not a
  // version, installed and switched on at whatever HEAD happened to be when
  // the user got round to pasting it. Every other install path here spends
  // real effort on that binding: it checks the repository is still at the
  // reviewed commit, adds it disabled, moves the checkout to that exact sha,
  // confirms it landed, and only then switches it on. This path skipped all of
  // it — so the installs that also run a setup script, the riskiest ones,
  // carried the weakest guarantee in the plugin. It is the same class of gap
  // that blocked Plug at the marketplace before.
  //
  // Plug will not run the script for you, and that does not stop it handing
  // over commands that keep the promise the review made.
  function manualCommands(d) {
    if (!d) return ""
    var repo = String(d.url || "")
    var id = String(d.id || "<plugin-id>")
    var sha = d && d.sha ? String(d.sha) : ""
    var dir = "~/.config/omarchy/plugins/" + id
    var lines = ["omarchy plugin add " + repo]
    if (sha !== "")
      lines.push("git -C " + dir + " checkout --quiet " + sha)
    var notes = []
    var scripts = (d.manualInstall && d.manualInstall.scripts) || []
    for (var i = 0; i < scripts.length; i++) {
      // A name Plug will not put on a command line still gets said out loud.
      // Dropping it would let the plugin choose whether its own install step
      // was mentioned; printing it would hand over a command substitution.
      // Neither — so it is described instead, and the user opens the folder.
      if (scripts[i].safeName === false)
        notes.push("# one script cannot be named safely on a command line — "
                   + "open " + dir + " and run it yourself after reading it")
      else
        lines.push(dir + "/" + String(scripts[i].file))
    }
    // Last, and separate: switching it on is what starts the plugin running,
    // and that belongs after the script the plugin said it needed, not before.
    lines.push("omarchy plugin enable " + id)
    // One command, not a list of them — which is what makes the pin binding.
    //
    // Joined with newlines, these were four independent commands: a terminal
    // runs each one whatever the one above it did, so a `git checkout` that
    // failed — the repository force-pushed past the reviewed commit, the add
    // itself failed — printed its error and the paste carried on, running the
    // install script and enabling the plugin at a version nobody reviewed.
    // The `&&` was there and bound only to an `echo`. Chained, the first
    // failure stops everything after it, which is the behaviour the comment
    // claimed all along.
    return lines.join(" &&\n") + (notes.length ? "\n" + notes.join("\n") : "")
  }
  function copyText(s) {
    if (!s) return
    Quickshell.execDetached(["wl-copy", "--", String(s)])
    root.noticeText = "Copied"
  }

  // Read it before it lands. plugd clones the plugin to a throwaway
  // directory, scans it, has the reviewer read the whole source, and deletes
  // the clone — nothing is installed and nothing in it is ever run.
  function installFromStore(c) {
    if (!c || !c.repo) return
    root.reviewCancelled = 0
    root.reviewMode = "install"
    root.installCandidate = c
    root.reviewId = c.id || c.name || "plugin"
    root.reviewData = null
    root.reviewRunning = true
    inspectProc.command = ["python3", root.pluginDir + "/plugd.py", "inspect", c.repo]
    inspectProc.running = false; inspectProc.running = true
  }
  Process {
    id: inspectProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var d = JSON.parse(text)
          if (d && d.review) root.reviewData = d
          else if (d && d.error) {
            root.noticeText = "Could not check it: " + d.error
            root.cancelReview()
          }
        } catch (e) {
          // A check the user backed out of is not a check that failed. Killing
          // the engine makes its collector deliver whatever had arrived, which
          // does not parse — so cancelling put "could not read the result" in
          // the footer every time, blaming the tool for obeying.
          if (root.reviewCancelled > 0) root.reviewCancelled -= 1
          else root.noticeText = "Could not read the check result"
          root.cancelReview()
        }
      }
    }
    stderr: StdioCollector { waitForEnd: true }
    onExited: root.reviewRunning = false
  }

  // ------------------------------------------------------------------ settings
  readonly property string settingsFile: root.stateDir + "/settings.json"
  function loadSettings() { settingsReader.running = false; settingsReader.running = true }
  Process {
    id: settingsReader
    command: ["python3", "-c", root.safeRead,
              root.stateDir + "/settings.json", "65536"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var s = JSON.parse(text)
          if (s && typeof s === "object" && !Array.isArray(s)) root.settings = s
        } catch (e) {}
        root.settingsLoaded = true
        agentsProc.running = false; agentsProc.running = true
      }
    }
  }
  // Ask the engine which reviewers are actually installed.
  Process {
    id: agentsProc
    command: ["python3", root.pluginDir + "/plugd.py", "agents"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var a = JSON.parse(text)
          if (Array.isArray(a)) root.availableAgents = a
        } catch (e) {}
      }
    }
  }
  // Every hotkey active in Hyprland right now, whatever config assigned it —
  // `hyprctl binds` is the authoritative list, including Omarchy's own binds
  // that never appear in bindings.lua. Plug uses it to warn before you pick a
  // combination that is already taken.
  property var takenBinds: ({})
  function loadBinds() { bindsProc.running = false; bindsProc.running = true }
  Process {
    id: bindsProc
    command: ["hyprctl", "binds", "-j"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var arr = JSON.parse(text)
          if (!Array.isArray(arr)) return
          var names = { 1: "SHIFT", 4: "CTRL", 8: "ALT", 64: "SUPER" }
          var order = [64, 4, 8, 1]
          var taken = ({})
          for (var i = 0; i < arr.length; i++) {
            var m = arr[i].modmask
            var mods = []
            for (var j = 0; j < order.length; j++) if (m & order[j]) mods.push(names[order[j]])
            var key = String(arr[i].key || "").toUpperCase()
            if (!key) continue
            if (key === " ") key = "SPACE"
            if (mods.length) taken[mods.join(" + ") + " + " + key] = true
          }
          root.takenBinds = taken
        } catch (e) {}
      }
    }
  }
  function saveSettings() {
    if (!root.settingsLoaded) return
    Quickshell.execDetached(["bash", "-c",
      'd=$(dirname "$2") && mkdir -p "$d" && [ -O "$d" ] && t=$(mktemp "$2.XXXXXXXX") && printf "%s\\n" "$1" > "$t" && mv -f "$t" "$2"',
      "--", JSON.stringify(root.settings), root.settingsFile])
  }
  function setAgent(key) {
    var s = JSON.parse(JSON.stringify(root.settings))
    s.reviewAgent = key
    // Default the model to the agent's first, if we know it.
    for (var i = 0; i < root.availableAgents.length; i++)
      if (root.availableAgents[i].key === key) s.reviewModel = root.availableAgents[i].defaultModel
    root.settings = s
    root.saveSettings()
  }
  function setModel(m) {
    var s = JSON.parse(JSON.stringify(root.settings)); s.reviewModel = m
    root.settings = s; root.saveSettings()
  }

  // --------------------------------------------------------- hotkey capture
  property bool capturing: false
  property string captureNote: ""
  readonly property var shortcutPattern:
    /^(SUPER|CTRL|ALT|SHIFT)( \+ (SUPER|CTRL|ALT|SHIFT))* \+ ([A-Z0-9]|F([1-9]|1[0-2])|SPACE|RETURN|ENTER|TAB|ESCAPE|BACKSPACE|DELETE|INSERT|HOME|END|PAGE_UP|PAGE_DOWN|UP|DOWN|LEFT|RIGHT|COMMA|PERIOD|SLASH|MINUS|EQUAL|SEMICOLON|APOSTROPHE|GRAVE|BRACKETLEFT|BRACKETRIGHT|BACKSLASH)$/
  function validShortcut(s) {
    return typeof s === "string" && s.length <= 40 && root.shortcutPattern.test(s)
  }
  function captureKey(event) {
    if (event.key === Qt.Key_Escape) { root.capturing = false; root.captureNote = ""; return }
    var mods = []
    if (event.modifiers & Qt.MetaModifier) mods.push("SUPER")
    if (event.modifiers & Qt.ControlModifier) mods.push("CTRL")
    if (event.modifiers & Qt.AltModifier) mods.push("ALT")
    if (event.modifiers & Qt.ShiftModifier) mods.push("SHIFT")
    var name = ""
    if (event.key >= Qt.Key_A && event.key <= Qt.Key_Z) name = String.fromCharCode(65 + (event.key - Qt.Key_A))
    else if (event.key >= Qt.Key_0 && event.key <= Qt.Key_9) name = String.fromCharCode(48 + (event.key - Qt.Key_0))
    else if (event.key >= Qt.Key_F1 && event.key <= Qt.Key_F12) name = "F" + (event.key - Qt.Key_F1 + 1)
    if (name === "") return
    if (mods.length === 0) { root.captureNote = "Add a modifier — SUPER, CTRL or ALT"; return }
    var combo = mods.join(" + ") + " + " + name
    // Refuse a combination Hyprland already uses for something else, so Plug
    // never quietly steals a shortcut. The user picks another.
    if (root.takenBinds[combo] === true) {
      root.captureNote = combo + " is already used by something else — try another."
      return
    }
    // The shape check, actually run. `validShortcut` existed and was called
    // from nowhere, so the two independent checks this value is supposed to
    // pass through were one: the panel built a combination out of fixed parts
    // and trusted itself, and only the control script ever tested the result.
    // A guard defined and not called is worse than no guard, because the next
    // person reads the definition and believes it.
    if (!root.validShortcut(combo)) {
      root.captureNote = "That is not a combination Plug can bind — try another."
      return
    }
    var s = JSON.parse(JSON.stringify(root.settings)); s.shortcut = combo
    root.settings = s; root.saveSettings()
    root.capturing = false; root.captureNote = ""
    Quickshell.execDetached(["bash", root.pluginDir + "/plug-ctl.sh", "bind", combo])
  }
  function clearHotkey() {
    var s = JSON.parse(JSON.stringify(root.settings)); s.shortcut = ""
    root.settings = s; root.saveSettings()
    Quickshell.execDetached(["bash", root.pluginDir + "/plug-ctl.sh", "unbind"])
  }

  // ================================================================= UI
  PanelWindow {
    id: panel
    visible: root.opened
    color: "transparent"
    anchors { top: true; bottom: true; left: true; right: true }
    WlrLayershell.namespace: "plug"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: root.opened ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

    Rectangle {
      anchors.fill: parent
      color: root.scrim
      MouseArea { anchors.fill: parent; onClicked: root.close() }
    }

    Item {
      id: keyCatcher
      anchors.fill: parent
      focus: true
      Keys.onPressed: function(e) {
        if (root.capturing) { root.captureKey(e); e.accepted = true; return }
        // The "changed while you were reading it" question owns the keyboard
        // while it is up; Escape dismisses it.
        if (root.movedName !== "" && root.reviewId === "") {
          if (e.key === Qt.Key_Escape) { root.movedName = ""; root.movedSha = "" }
          e.accepted = true
          return
        }
        // Review overlay: Enter approves, Esc backs out. Gated on the overlay
        // being visible, so Enter on the Settings tab cannot approve an
        // install that is not on screen.
        if (root.reviewOnScreen) {
          if (e.key === Qt.Key_Escape) { root.cancelReview(); e.accepted = true }
          // Enter approves what there is to approve. Where the install needs
          // a script Plug will not run, there is no approving it from here —
          // and an Enter that silently half-installed it would be worse than
          // one that does nothing.
          else if ((e.key === Qt.Key_Return || e.key === Qt.Key_Enter)
                   && root.reviewData && !root.reviewRunning
                   && !(root.reviewData.manualInstall
                        && root.reviewData.manualInstall.required === true)
                   && root.reviewData.isPlugin !== false) { root.approveUpdate(); e.accepted = true }
          return
        }
        // Escape unwinds one layer at a time, then closes.
        if (e.key === Qt.Key_Escape) {
          // A review waiting on another tab is a layer too. Going to Settings
          // to check the reviewer and pressing Escape should return to the
          // verdict, not close the panel and discard it on the way back in.
          if (root.reviewId !== "" && root.tab === "settings")
            root.tab = (root.reviewMode === "install" ? "store" : "installed")
          else if (root.confirmRemoveId !== "") root.confirmRemoveId = ""
          else if (root.tab === "store" && root.storeQuery !== "") root.storeQuery = ""
          else root.close()
          e.accepted = true; return
        }
        if (e.key === Qt.Key_Tab) {
          if (root.tab === "installed") root.openStore()
          else root.tab = (root.tab === "store" ? "settings" : "installed")
          root.selectedIndex = 0; e.accepted = true; return
        }

        // Typing on the Store tab searches even when the field was never
        // clicked — the panel takes the keystroke and feeds the same buffer.
        // Once the field has focus it handles its own keys and this never
        // runs.
        if (root.tab === "store") {
          if (e.key === Qt.Key_Backspace) {
            root.storeQuery = root.storeQuery.slice(0, -1); e.accepted = true; return
          }
          if (e.text && e.text.length === 1 && e.text.charCodeAt(0) >= 0x20
              && !(e.modifiers & (Qt.ControlModifier | Qt.MetaModifier | Qt.AltModifier))) {
            root.storeQuery += e.text; e.accepted = true; return
          }
        }

        // Installed tab: arrow keys move a visible cursor, Enter acts on it
        // (review a waiting update, otherwise toggle enabled), and x removes.
        if (root.tab === "installed") {
          var n = root.installedRows.length
          if (e.key === Qt.Key_Down) {
            root.selectedIndex = Math.min(n - 1, root.selectedIndex + 1); e.accepted = true; return
          }
          if (e.key === Qt.Key_Up) {
            root.selectedIndex = Math.max(0, root.selectedIndex - 1); e.accepted = true; return
          }
          if (root.selectedIndex >= 0 && root.selectedIndex < n) {
            var row = root.installedRows[root.selectedIndex]
            // The same guard the controls carry, for a job started in this
            // session and still running.
            //
            // It does NOT cover the press this comment used to claim it did.
            // A job that reloads the shell summons Plug back into a fresh
            // panel with the row it acted on highlighted, so the cursor is
            // parked on exactly the row whose data is still pre-job — and
            // `open()` has cleared the job state on the way in, so nothing
            // here knows. That press is stopped in the engine instead, where
            // `apply_update` refuses a commit it is already on; no panel state
            // survives the reload, so no panel guard can.
            var rowBusy = root.jobRunning
            if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) {
              if (rowBusy) { e.accepted = true; return }
              if (row.updateAvailable) root.startReview(row.id)
              else root.setEnabled(row.id, !row.enabled)
              e.accepted = true; return
            }
            if (e.key === Qt.Key_X || e.key === Qt.Key_Delete) {
              if (rowBusy) { e.accepted = true; return }
              if (root.confirmRemoveId === row.id) root.removeConfirmed(row.id)
              else root.askRemove(row.id)
              e.accepted = true; return
            }
          }
        }
      }
    }

    Rectangle {
      id: card
      width: Math.min(Style.space(960), panel.width - Style.space(40))
      height: Math.min(Style.space(620), panel.height - Style.space(40))
      anchors.centerIn: parent
      color: root.background
      radius: root.cornerRadius
      border.color: root.border
      border.width: Math.max(1, Style.space(1))

      // The scrim behind this card closes the panel when it is clicked, which
      // is what a click outside the card should do. But a Rectangle does not
      // accept mouse events, so every click that landed on the card and missed
      // a control fell straight through to the scrim and closed the panel —
      // reading a review meant not touching it. This accepts those clicks and
      // does nothing with them. It is declared first, so everything else in
      // the card is above it and still gets its own clicks; it takes no wheel
      // events, so the lists and the review still scroll.
      MouseArea { anchors.fill: parent }

      Column {
        anchors.fill: parent
        anchors.margins: Style.space(18)
        spacing: Style.space(12)

        // -------- header: title, tabs, update badge, refresh
        Item {
          width: parent.width
          height: Style.space(30)
          Row {
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(10)
            Text {
              text: "  Plug"
              textFormat: Text.PlainText
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              anchors.verticalCenter: parent.verticalCenter
            }
            Rectangle {
              visible: root.updateCount > 0
              anchors.verticalCenter: parent.verticalCenter
              width: badgeText.implicitWidth + Style.space(14)
              height: Style.space(20)
              radius: height / 2
              color: root.okColor
              Text {
                id: badgeText
                anchors.centerIn: parent
                text: root.updateCount + (root.updateCount === 1 ? " update" : " updates")
                textFormat: Text.PlainText
                color: "#0a1a0e"
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }
            }
          }
          Row {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(4)
            TabButton { label: "Installed"; active: root.tab === "installed"; onPickedT: root.tab = "installed" }
            TabButton { label: "Store"; active: root.tab === "store"; onPickedT: root.openStore() }
            TabButton { label: "Settings"; active: root.tab === "settings"; onPickedT: root.tab = "settings" }
          }
        }

        Rectangle { width: parent.width; height: 1; color: root.hairline }

        // -------- body
        Item {
          width: parent.width
          height: parent.height - Style.space(30) - Style.space(12) - 1 - Style.space(12) - footer.height - Style.space(12)

          // ===== INSTALLED =====
          Column {
            visible: root.tab === "installed" && root.reviewId === ""
            anchors.fill: parent
            spacing: Style.space(8)

            Row {
              width: parent.width
              spacing: Style.space(10)
              Text {
                text: root.installedRows.length + " community plugin" + (root.installedRows.length === 1 ? "" : "s")
                textFormat: Text.PlainText
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                anchors.verticalCenter: parent.verticalCenter
              }
              // A plain-language status once a check has run: either the count
              // (also badged in the header) or an explicit all-clear.
              Text {
                anchors.verticalCenter: parent.verticalCenter
                visible: root.updatesChecked && !checkProc.running
                text: root.updateCount > 0
                    ? (root.updateCount + " update" + (root.updateCount === 1 ? "" : "s") + " available")
                    : "✓ No updates available"
                textFormat: Text.PlainText
                color: root.okColor
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }
              Item { width: Style.space(1); height: 1 }
              PlugButton {
                // Also the process itself rather than the footer text. Matching
                // on a substring of a human-readable note is a binding that
                // breaks when someone rewords the note, and it broke here for
                // a different reason first: the note is not raised at all while
                // a job owns the footer.
                label: checkProc.running ? "Checking…" : "Check for updates"
                onPicked: root.checkUpdates()
              }
            }

            Flickable {
              width: parent.width
              height: parent.height - Style.space(30)
              contentHeight: instCol.height
              clip: true
              Column {
                id: instCol
                width: parent.width
                spacing: Style.space(6)

                // ---- Community: your third-party plugins. Toggle + remove.
                SectionHeader {
                  label: "Community"
                  count: root.installedRows.length
                  expanded: root.communityExpanded
                  onToggled: root.communityExpanded = !root.communityExpanded
                }
                Grid {
                  width: parent.width
                  columns: 2
                  columnSpacing: Style.space(8)
                  rowSpacing: Style.space(6)
                  readonly property real cellW: (width - columnSpacing) / 2
                  Repeater {
                    model: root.communityExpanded ? root.installedRows : []
                    delegate: InstalledRow {
                      width: parent.cellW
                      rowData: modelData
                      confirming: root.confirmRemoveId === modelData.id
                      selected: index === root.selectedIndex
                      selectable: true
                      onRowClicked: {
                        root.selectedIndex = index
                        root.confirmRemoveId = ""
                        keyCatcher.forceActiveFocus()
                      }
                    }
                  }
                }
                Item {
                  visible: root.communityExpanded && root.installedRows.length === 0
                  width: parent.width; height: Style.space(60)
                  Text {
                    anchors.centerIn: parent
                    text: "No community plugins installed yet.\nBrowse the Store to add some."
                    textFormat: Text.PlainText
                    horizontalAlignment: Text.AlignHCenter
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                  }
                }

                // ---- Official (Omarchy's own bar widgets). Toggleable here,
                // never removable — the shell owns them; Plug just offers the
                // switch. Folded by default.
                SectionHeader {
                  visible: root.officialRows.length > 0
                  label: "Official — Omarchy's own"
                  count: root.officialRows.length
                  expanded: root.officialExpanded
                  onToggled: root.officialExpanded = !root.officialExpanded
                }
                Grid {
                  width: parent.width
                  columns: 2
                  columnSpacing: Style.space(8)
                  rowSpacing: Style.space(6)
                  readonly property real cellW: (width - columnSpacing) / 2
                  Repeater {
                    model: root.officialExpanded ? root.officialRows : []
                    delegate: InstalledRow {
                      width: parent.cellW
                      rowData: modelData
                    }
                  }
                }
              }
            }
          }

          // ===== REVIEW OVERLAY =====
          ReviewView {
            visible: root.reviewOnScreen
            anchors.fill: parent
          }

          // The author pushed while the review was on screen, so nothing was
          // installed. Both ways forward are offered plainly, because either
          // is reasonable and only the user can choose.
          Rectangle {
            id: movedScreen
            visible: root.movedName !== "" && root.reviewId === ""
            anchors.fill: parent
            color: root.background
            // Opaque is not the same as blocking: without this the list
            // underneath still took the clicks and the keys, so Enter toggled
            // a plugin and x twice removed one while the user believed they
            // were answering the question on screen.
            MouseArea { anchors.fill: parent; hoverEnabled: true }
            Column {
              anchors.centerIn: parent
              width: parent.width - Style.space(60)
              spacing: Style.space(12)
              Text {
                width: parent.width
                text: root.movedName + " changed while you were reading it"
                textFormat: Text.PlainText
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                font.bold: true
                wrapMode: Text.WordWrap
              }
              Text {
                width: parent.width
                text: "Its author published new code after the check finished, so nothing has been installed. The version that was checked is still available."
                textFormat: Text.PlainText
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }
              Row {
                spacing: Style.space(8)
                PlugButton { label: "Check the new version"; onPicked: root.reviewMoved() }
                PlugButton { label: "Install the version you checked"; onPicked: root.installApproved() }
                PlugButton { label: "Cancel"; onPicked: { root.movedName = ""; root.movedSha = "" } }
              }
            }
          }

          // ===== STORE =====
          Column {
            visible: root.tab === "store" && root.reviewId === ""
            anchors.fill: parent
            spacing: Style.space(8)

            // A real field, not a picture of one. Typing on the Store tab
            // still works without touching it, but it takes a click, shows a
            // caret, and accepts a paste — which is what a box with a
            // magnifying glass in it promises.
            Rectangle {
              id: searchBox
              width: parent.width
              height: Style.space(32)
              radius: root.cornerRadius
              color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b,
                             searchInput.activeFocus ? 0.10 : 0.06)
              border.color: searchInput.activeFocus ? root.accent : root.hairline
              border.width: 1

              // Anywhere in the box puts the caret in the text, including the
              // empty space to the right of it.
              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.IBeamCursor
                onClicked: searchInput.forceActiveFocus()
              }

              Row {
                anchors.fill: parent
                anchors.leftMargin: Style.space(10)
                anchors.rightMargin: Style.space(10)
                spacing: Style.space(8)
                Text {
                  text: "🔍"
                  textFormat: Text.PlainText
                  anchors.verticalCenter: parent.verticalCenter
                  font.pixelSize: Style.font.body
                }
                Item {
                  width: parent.width - Style.space(40) - refreshBtn.width
                         - (clearBtn.visible ? Style.space(24) : 0)
                  height: parent.height
                  TextInput {
                    id: searchInput
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width
                    text: root.storeQuery
                    onTextChanged: if (text !== root.storeQuery) root.storeQuery = text
                    color: root.foreground
                    selectionColor: root.selBg
                    selectedTextColor: root.selText
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    clip: true
                    selectByMouse: true
                    activeFocusOnPress: true
                    // A filter box, so a pasted wall of text is capped rather
                    // than carried into every search comparison.
                    maximumLength: 128
                    cursorVisible: activeFocus
                    // Escape and Tab still belong to the panel, so they are
                    // handed back rather than swallowed by the field.
                    Keys.onPressed: function(e) {
                      if (e.key === Qt.Key_Escape) {
                        if (root.storeQuery !== "") root.storeQuery = ""
                        else root.close()
                        e.accepted = true
                      } else if (e.key === Qt.Key_Tab) {
                        root.tab = "settings"
                        root.selectedIndex = 0
                        keyCatcher.forceActiveFocus()
                        e.accepted = true
                      }
                    }
                  }
                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width
                    visible: root.storeQuery === ""
                    text: "Search community plugins, or paste a repository URL…"
                    textFormat: Text.PlainText
                    color: root.fainter
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    elide: Text.ElideRight
                  }
                }
                // Fetch the catalog now. The Store already refreshes itself
                // when what is saved has aged out; this is for when you know
                // something was listed a minute ago.
                Item {
                  id: refreshBtn
                  // The word, not a symbol: a circular arrow is a guess until
                  // you have pressed it once. The label never changes width
                  // while it works, so the box does not shift under the
                  // pointer — the footer carries the progress instead.
                  width: refreshLabel.implicitWidth + Style.space(6)
                  height: parent.height
                  Text {
                    id: refreshLabel
                    anchors.centerIn: parent
                    text: "Refresh"
                    textFormat: Text.PlainText
                    color: root.catalogRefreshing ? root.accent
                         : refreshHover.containsMouse ? root.foreground : root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                  }
                  MouseArea {
                    id: refreshHover
                    anchors.fill: parent
                    hoverEnabled: true
                    enabled: !root.catalogRefreshing
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.refreshCatalog(false)
                  }
                }
                // Clear, for people who reach for the mouse rather than Escape.
                Item {
                  id: clearBtn
                  visible: root.storeQuery !== ""
                  width: Style.space(20); height: parent.height
                  Text {
                    anchors.centerIn: parent
                    text: "✕"
                    textFormat: Text.PlainText
                    color: clearHover.containsMouse ? root.foreground : root.fainter
                    font.pixelSize: Style.font.caption
                  }
                  MouseArea {
                    id: clearHover
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: { root.storeQuery = ""; searchInput.forceActiveFocus() }
                  }
                }
              }
            }

            // A pasted address searches nothing — no catalog entry has a URL
            // in its name — so the field would otherwise go empty and read as
            // "no such plugin". This is the one row that address does match.
            Rectangle {
              id: urlBanner
              width: parent.width
              visible: root.queryIsUrl
              height: visible ? urlRow.implicitHeight + Style.space(20) : 0
              radius: root.cornerRadius
              color: root.selBg
              border.color: root.accent
              border.width: 1
              Row {
                id: urlRow
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.leftMargin: Style.space(12)
                anchors.rightMargin: Style.space(12)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(10)
                Column {
                  width: parent.width - checkBtn.width - Style.space(10)
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(2)
                  Text {
                    width: parent.width
                    text: "Not in the catalog"
                    textFormat: Text.PlainText
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    font.bold: true
                  }
                  Text {
                    width: parent.width
                    text: "Read this repository before you install it — same "
                        + "check the Store does, on an address you typed."
                    textFormat: Text.PlainText
                    wrapMode: Text.WordWrap
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }
                PlugButton {
                  id: checkBtn
                  anchors.verticalCenter: parent.verticalCenter
                  label: "Check it"
                  onPicked: root.checkUrl(root.storeQuery)
                }
              }
            }

            // A list that builds the rows it is showing, not the whole
            // catalog. The old column made every row a live object up front,
            // which is why it had to stop at 300 — a bound on what could be
            // drawn, sitting on data that was already bounded when it was
            // fetched and read. Building on demand is the stricter bound of
            // the two: what exists is what fits on screen, whether the
            // catalog holds a thousand plugins or ten thousand. Rows are a
            // fixed height, so the scrollbar needs no guesswork.
            Item {
              width: parent.width
              // The search box and its spacing, plus the pasted-address row
              // when it is showing — a Column does not take height back from
              // a sibling on its own.
              height: parent.height - Style.space(40)
                      - (urlBanner.visible ? urlBanner.height + Style.space(8) : 0)
              ListView {
                id: storeList
                anchors.fill: parent
                clip: true
                model: root.storeFiltered
                spacing: Style.space(6)
                boundsBehavior: Flickable.StopAtBounds
                delegate: StoreRow { width: storeList.width; cData: modelData }
              }
              Text {
                anchors.centerIn: parent
                visible: !root.catalogLoaded
                // Ask the fetch whether it is running, not the shared footer
                // flag. The footer belongs to whatever the user is waiting on
                // and is deliberately not raised while a job holds it, so
                // reading it here made the Store announce "Catalog not loaded"
                // over a fetch that was in progress — a flatly false statement
                // produced by asking the wrong object a question it was never
                // answering.
                text: root.catalogRefreshing ? "Fetching catalog…" : "Catalog not loaded."
                textFormat: Text.PlainText
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
            }
          }

          // ===== SETTINGS =====
          SettingsView {
            visible: root.tab === "settings"
            anchors.fill: parent
          }
        }

        Rectangle { width: parent.width; height: 1; color: root.hairline }

        // -------- footer
        Item {
          id: footer
          width: parent.width
          height: Style.space(16)
          Text {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: root.noticeText !== "" ? root.noticeText
                : root.reviewOnScreen ? (
                    (root.reviewData && root.reviewData.manualInstall
                     && root.reviewData.manualInstall.required === true)
                      ? "Esc cancel — this one you install yourself"
                    : root.reviewMode === "install"
                      ? "Enter install · Esc cancel" : "Enter apply · Esc back")
                : root.tab === "installed" ? "↑↓ move · Enter review/toggle · x remove · Tab switch view · Esc close"
                : root.tab === "store" ? "type to search · double-click a plugin to open its repo · Tab switch view · Esc clear/close"
                : "Tab switch view · Esc close"
            textFormat: Text.PlainText
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
            width: parent.width - Style.space(120)
          }
          Text {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            visible: root.busy
            text: root.busyNote
            textFormat: Text.PlainText
            color: root.accent
            font.family: root.fontFamily
            // The one thing on screen saying work is in flight should not be
            // the smallest text in the panel.
            font.pixelSize: Style.font.body
            font.bold: true
          }
        }
      }
    }
  }

  // ================================================================= components
  component SectionHeader: Item {
    property string label: ""
    property int count: 0
    property bool expanded: true
    signal toggled()
    width: parent ? parent.width : 0
    height: Style.space(28)
    Row {
      anchors.left: parent.left
      anchors.leftMargin: Style.space(4)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(8)
      Text {
        text: parent.parent.expanded ? "▾" : "▸"
        textFormat: Text.PlainText
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        anchors.verticalCenter: parent.verticalCenter
      }
      Text {
        text: parent.parent.label + " (" + parent.parent.count + ")"
        textFormat: Text.PlainText
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
        anchors.verticalCenter: parent.verticalCenter
      }
    }
    Rectangle {
      anchors.left: parent.left; anchors.right: parent.right
      anchors.bottom: parent.bottom
      height: 1; color: root.hairline
    }
    MouseArea {
      anchors.fill: parent
      cursorShape: Qt.PointingHandCursor
      onClicked: parent.toggled()
    }
  }

  component TabButton: Rectangle {
    property string label: ""
    property bool active: false
    signal pickedT()
    width: tbl.implicitWidth + Style.space(20)
    height: Style.space(24)
    radius: root.cornerRadius
    color: active ? root.selBg : "transparent"
    Text {
      id: tbl
      anchors.centerIn: parent
      text: parent.label
      textFormat: Text.PlainText
      color: parent.active ? root.selText : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      font.bold: parent.active
    }
    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: parent.pickedT() }
  }

  component PlugButton: Rectangle {
    property string label: ""
    property bool danger: false
    signal picked()
    width: pbl.implicitWidth + Style.space(20)
    height: Style.space(26)
    radius: root.cornerRadius
    color: hov.containsMouse
      ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.10)
      : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.05)
    border.color: danger ? root.dangerColor : root.hairline
    border.width: 1
    Text {
      id: pbl
      anchors.centerIn: parent
      text: parent.label
      textFormat: Text.PlainText
      color: parent.danger ? root.dangerColor : root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
    MouseArea { id: hov; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: parent.picked() }
  }

  // Compact row, sized for two-up. Every community row carries the same four
  // controls in the same order — update · restore · remove · on/off — so the
  // eye finds each action in the same place on every row. A control that has
  // nothing to do right now stays put but dims; update lights green the
  // moment new changes are waiting. Official rows show only the on/off
  // switch, anchored at the same right edge so the switches line up down the
  // whole list.
  component InstalledRow: Rectangle {
    property var rowData: null
    property bool confirming: false
    property bool selected: false
    // Community rows are the ones the cursor moves over, so they answer to a
    // click as well as to the arrow keys — clicking a row's name puts the
    // highlight on it, and Enter then acts on it. Official rows have no
    // cursor to move, so they do not pretend to be clickable.
    property bool selectable: false
    // A job is running somewhere in the panel. Every control on every row is
    // reading the state file as it was before that job started, and the runners
    // behind them are shared, so none of them is safe to press until it lands —
    // not just the ones on the row being worked on.
    readonly property bool working: root.jobRunning
    signal rowClicked()
    height: Style.space(48)
    radius: root.cornerRadius
    color: selected ? root.selBg
      : rowHover.containsMouse
        ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.06)
        : "transparent"
    border.color: selected ? root.accent
      : rowData && rowData.updateAvailable ? Qt.rgba(root.okColor.r, root.okColor.g, root.okColor.b, 0.5)
      : root.hairline
    border.width: selected ? Math.max(1, Style.space(1)) : 1
    MouseArea {
      id: rowHover
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: parent.selectable ? Qt.PointingHandCursor : Qt.ArrowCursor
      onClicked: if (parent.selectable) parent.rowClicked()
    }

    // controls on the right; text fills the space that is left. The on/off
    // switch is last so it sits at the same position on every row — official
    // rows hide the other three and stay aligned for free.
    Row {
      id: controls
      anchors.right: parent.right
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(5)

      // update — THE indicator: green and pressable when changes are waiting,
      // dim when the plugin is current. Pressing it opens the review.
      Rectangle {
        visible: !(rowData && rowData.official)
        readonly property bool armed: !!(rowData && rowData.updateAvailable === true && !working)
        anchors.verticalCenter: parent.verticalCenter
        width: upLbl.implicitWidth + Style.space(14); height: Style.space(22)
        radius: height / 2
        color: armed ? root.okColor
          : (upHover.containsMouse ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.06) : "transparent")
        border.color: armed ? root.okColor : root.hairline; border.width: 1
        Text { id: upLbl; anchors.centerIn: parent; text: "update"; textFormat: Text.PlainText; color: parent.armed ? "#0a1a0e" : root.fainter; font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: parent.armed }
        MouseArea { id: upHover; anchors.fill: parent; hoverEnabled: true; cursorShape: parent.armed ? Qt.PointingHandCursor : Qt.ArrowCursor; onClicked: if (parent.armed) root.startReview(rowData.id) }
      }
      // restore — undo the last applied update; lit only once there is a
      // previous version recorded to go back to.
      Rectangle {
        visible: !(rowData && rowData.official)
        readonly property bool armed: !!(rowData && rowData.canRevert === true && !working)
        anchors.verticalCenter: parent.verticalCenter
        width: rsLbl.implicitWidth + Style.space(14); height: Style.space(22)
        radius: height / 2
        color: armed && rsHover.containsMouse ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.10) : "transparent"
        border.color: root.hairline; border.width: 1
        Text { id: rsLbl; anchors.centerIn: parent; text: "restore"; textFormat: Text.PlainText; color: parent.armed ? root.foreground : root.fainter; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
        MouseArea { id: rsHover; anchors.fill: parent; hoverEnabled: true; cursorShape: parent.armed ? Qt.PointingHandCursor : Qt.ArrowCursor; onClicked: if (parent.armed) root.revert(rowData.id) }
      }
      // remove — arms to a red confirm on the first press.
      Rectangle {
        visible: !(rowData && rowData.official)
        anchors.verticalCenter: parent.verticalCenter
        width: rmLbl.implicitWidth + Style.space(14); height: Style.space(22)
        radius: height / 2
        color: confirming ? root.dangerColor : (rmHover.containsMouse ? Qt.rgba(root.dangerColor.r, root.dangerColor.g, root.dangerColor.b, 0.15) : "transparent")
        border.color: root.dangerColor; border.width: 1
        Text { id: rmLbl; anchors.centerIn: parent; text: confirming ? "sure?" : "remove"; textFormat: Text.PlainText; color: confirming ? "#1a1005" : root.dangerColor; font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: confirming }
        MouseArea {
          id: rmHover; anchors.fill: parent; hoverEnabled: true
          cursorShape: working ? Qt.ArrowCursor : Qt.PointingHandCursor
          // Removing a plugin out from under a job already running on it is
          // the one press here with no way back.
          onClicked: {
            if (working) return
            if (root.confirmRemoveId === rowData.id) root.removeConfirmed(rowData.id)
            else root.askRemove(rowData.id)
          }
        }
      }
      // on/off toggle — always last, so it lines up on every row.
      Rectangle {
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(56); height: Style.space(22)
        radius: height / 2
        color: "transparent"
        border.color: root.hairline; border.width: 1
        Row {
          anchors.fill: parent
          Rectangle {
            width: parent.width / 2; height: parent.height; radius: height / 2
            color: rowData && rowData.enabled ? root.okColor : "transparent"
            Text { anchors.centerIn: parent; text: "on"; textFormat: Text.PlainText; color: rowData && rowData.enabled ? "#0a1a0e" : root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
            MouseArea { anchors.fill: parent; cursorShape: working ? Qt.ArrowCursor : Qt.PointingHandCursor; onClicked: if (!working && rowData && !rowData.enabled) root.setEnabled(rowData.id, true) }
          }
          Rectangle {
            width: parent.width / 2; height: parent.height; radius: height / 2
            color: rowData && !rowData.enabled ? root.fainter : "transparent"
            Text { anchors.centerIn: parent; text: "off"; textFormat: Text.PlainText; color: rowData && !rowData.enabled ? root.foreground : root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
            MouseArea { anchors.fill: parent; cursorShape: working ? Qt.ArrowCursor : Qt.PointingHandCursor; onClicked: if (!working && rowData && rowData.enabled && rowData.canDisable) root.setEnabled(rowData.id, false) }
          }
        }
      }
    }

    Row {
      anchors.left: parent.left
      anchors.leftMargin: Style.space(10)
      anchors.right: controls.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(8)
      // trust mark — community plugins only; official ones are not scanned.
      // A check for clean, a circle for the honest middle, an exclamation
      // for red: a warning to read the code first, not a stop sign, which
      // is why red is not a filled circle.
      Item {
        visible: !(rowData && rowData.official)
        width: Style.space(9); height: Style.space(9)
        anchors.verticalCenter: parent.verticalCenter
        readonly property string band: rowData ? rowData.trustBand : ""
        Rectangle {
          visible: parent.band !== "green" && parent.band !== "red"
          anchors.fill: parent; radius: width / 2
          color: root.trustColor(parent.band)
        }
        Text {
          visible: parent.band === "green" || parent.band === "red"
          anchors.centerIn: parent
          text: parent.band === "green" ? "✓" : "!"
          textFormat: Text.PlainText
          color: root.trustColor(parent.band)
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: true
        }
      }
      Column {
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(1)
        width: parent.width - Style.space(20)
        Row {
          spacing: Style.space(6)
          width: parent.width
          Text {
            text: rowData ? rowData.name : ""
            textFormat: Text.PlainText
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            font.bold: true
            elide: Text.ElideRight
            width: Math.min(implicitWidth, parent.width - badges.width - Style.space(6))
          }
          Row {
            id: badges
            spacing: Style.space(5)
            anchors.verticalCenter: parent.verticalCenter
            Rectangle {
              visible: rowData && rowData.official
              width: ofb.implicitWidth + Style.space(10); height: Style.space(16); radius: height / 2
              color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.22)
              Text { id: ofb; anchors.centerIn: parent; text: "OFFICIAL"; textFormat: Text.PlainText; color: root.accent; font.family: root.fontFamily; font.pixelSize: Style.font.caption - 2; font.bold: true }
            }
          }
        }
        Text {
          width: parent.width
          text: !rowData ? "" : confirming ? "remove this plugin?"
              : rowData.official ? (rowData.kinds || "built-in")
              : rowData.updateAvailable ? (rowData.commitsBehind + " new change" + (rowData.commitsBehind === 1 ? "" : "s") + " · press update to review")
              : rowData.iconHidden ? "on · bar icon hidden"
              // What the mark is about, in words. A colour on its own is the
              // thing that made the old number useless — you could see that
              // Plug disapproved and not what of. The id is the least useful
              // line on the row, so it is what gives way. Red leads with the
              // ask — read it — because it is a warning, not a verdict.
              : rowData.trustBand === "red" && rowData.trustWhy
                ? ("read it — " + rowData.trustWhy)
              : rowData.trustWhy ? rowData.trustWhy
              : (rowData.id + (rowData.kinds ? " · " + rowData.kinds : ""))
          textFormat: Text.PlainText
          color: confirming ? root.dangerColor : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }
    }
  }

  component StoreRow: Rectangle {
    property var cData: null
    readonly property bool installed: cData && root.installedIdSet[cData.id] === true
    height: Style.space(58)
    radius: root.cornerRadius
    color: sHover.containsMouse
      ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.06)
      : "transparent"
    border.color: root.hairline; border.width: 1
    // Double-click opens the plugin's repository — the page you would want
    // before installing something that runs as you. A single click is left
    // alone so it cannot happen by accident on the way to the install button.
    MouseArea {
      id: sHover
      anchors.fill: parent
      hoverEnabled: true
      onDoubleClicked: root.openRepo(cData)
    }
    Row {
      anchors.left: parent.left
      anchors.leftMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(10)
      Rectangle {
        width: Style.space(38); height: Style.space(38); radius: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
        color: root.accent
        Text { anchors.centerIn: parent; text: cData ? (cData.initials || cData.name.slice(0, 2).toUpperCase()) : ""; textFormat: Text.PlainText; color: "#0a0a0a"; font.family: root.fontFamily; font.pixelSize: Style.font.body; font.bold: true }
      }
      Column {
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(2)
        Row {
          spacing: Style.space(6)
          Text {
            text: cData ? cData.name : ""
            textFormat: Text.PlainText
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            font.bold: true
          }
          // Omarchy's own — clearly marked, and never installed or managed here.
          Rectangle {
            visible: cData && cData.official
            anchors.verticalCenter: parent.verticalCenter
            width: ofl.implicitWidth + Style.space(10); height: Style.space(15); radius: height / 2
            color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.22)
            Text { id: ofl; anchors.centerIn: parent; text: "OFFICIAL"; textFormat: Text.PlainText; color: root.accent; font.family: root.fontFamily; font.pixelSize: Style.font.caption - 1; font.bold: true }
          }
          Rectangle {
            visible: cData && !cData.official && cData.verificationStatus === "verified"
            anchors.verticalCenter: parent.verticalCenter
            width: vfl.implicitWidth + Style.space(10); height: Style.space(15); radius: height / 2
            color: Qt.rgba(root.okColor.r, root.okColor.g, root.okColor.b, 0.2)
            Text { id: vfl; anchors.centerIn: parent; text: "✓ verified"; textFormat: Text.PlainText; color: root.okColor; font.family: root.fontFamily; font.pixelSize: Style.font.caption - 1 }
          }
        }
        Text {
          text: cData ? ((cData.author ? "by " + cData.author + "  ·  " : "") + cData.description) : ""
          textFormat: Text.PlainText
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
          width: card.width - Style.space(200)
        }
      }
    }
    // Official plugins are built in (managed by the shell) — shown for
    // discovery, never installed from here. Community manual-setup plugins
    // cannot be one-click installed either. Everything else installs.
    PlugButton {
      anchors.right: parent.right
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      label: cData && cData.official ? "built in"
           : parent.installed ? "installed"
           : (cData && cData.installAvailable) ? "install" : "manual setup"
      onPicked: if (cData && !cData.official && !parent.installed && cData.installAvailable)
                  root.installFromStore(cData)
    }
  }

  component ReviewView: Item {
    id: reviewView

    // The header and the buttons are pinned to the top and the bottom of
    // the card; only the body between them scrolls. In a plain Column a
    // long review pushed the buttons off the bottom with nothing to scroll
    // and no way to reach them, so a verdict could be read and the update
    // it approved could not be applied.
    Row {
      id: reviewHeader
      anchors.top: parent.top
      anchors.left: parent.left
      anchors.right: parent.right
      spacing: Style.space(10)
      PlugButton { label: "‹ back"; onPicked: root.cancelReview() }
      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: (root.reviewMode === "install" ? "Before installing: " : "Review: ")
              + (root.reviewMode === "install" && root.installCandidate
                 ? root.installCandidate.name : root.reviewId)
        textFormat: Text.PlainText
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.bold: true
        elide: Text.ElideRight
        width: card.width - Style.space(140)
      }
    }

    Flickable {
      id: reviewScroll
      anchors.top: reviewHeader.bottom
      anchors.topMargin: Style.space(12)
      anchors.bottom: reviewActions.top
      anchors.bottomMargin: Style.space(12)
      anchors.left: parent.left
      anchors.right: parent.right
      contentHeight: reviewBody.height
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      Column {
        id: reviewBody
        width: reviewScroll.width
        spacing: Style.space(12)
        // running spinner-ish
        Item {
          visible: root.reviewRunning
          width: parent.width; height: Style.space(80)
          Text {
            anchors.centerIn: parent
            text: {
              var what = root.reviewMode === "install"
                ? "the plugin's code" : "the changes"
              if (root.reviewMode === "install" && !root.reviewData)
                return root.settings.reviewAgent === "none"
                  ? "Fetching a copy and scanning it…"
                  : "Fetching a copy and asking " + root.settings.reviewAgent + " to read it…"
              return root.settings.reviewAgent === "none" ? "Scanning " + what + "…"
                   : "Asking " + root.settings.reviewAgent + " to read " + what + "…"
            }
            textFormat: Text.PlainText
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }
        }

        // verdict
        Column {
          visible: !root.reviewRunning && root.reviewData !== null
          width: parent.width
          spacing: Style.space(10)
          Rectangle {
            width: parent.width
            height: verdictCol.height + Style.space(24)
            radius: root.cornerRadius
            color: {
              var v = root.reviewData ? root.reviewData.review.verdict : "UNKNOWN"
              var c = root.verdictColor(v)
              return Qt.rgba(c.r, c.g, c.b, 0.12)
            }
            border.width: 1
            border.color: {
              var v = root.reviewData ? root.reviewData.review.verdict : "UNKNOWN"
              return root.verdictColor(v)
            }
            Column {
              id: verdictCol
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: parent.top
              anchors.margins: Style.space(12)
              spacing: Style.space(6)
              Row {
                spacing: Style.space(10)
                Rectangle {
                  width: Style.space(16); height: Style.space(16); radius: width / 2
                  anchors.verticalCenter: parent.verticalCenter
                  color: root.reviewData ? root.verdictColor(root.reviewData.review.verdict) : root.fainter
                }
                Text {
                  text: {
                    if (!root.reviewData) return ""
                    var v = root.reviewData.review.verdict
                    return v === "SAFE" ? "Safe to update"
                         : v === "CAUTION" ? "Be careful"
                         : v === "DANGER" ? "Do not update" : "Unclear"
                  }
                  textFormat: Text.PlainText
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.subtitle
                  font.bold: true
                  anchors.verticalCenter: parent.verticalCenter
                }
                Text {
                  visible: root.reviewData && root.reviewData.review.agent && root.reviewData.review.agent !== "none"
                  text: root.reviewData ? "reviewed by " + root.reviewData.review.agent : ""
                  textFormat: Text.PlainText
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  anchors.verticalCenter: parent.verticalCenter
                }
              }
              Text {
                width: parent.width
                text: root.reviewData ? root.reviewData.review.headline : ""
                textFormat: Text.PlainText
                wrapMode: Text.WordWrap
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
            }
          }

          Text {
            text: "What changed"
            textFormat: Text.PlainText
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
          }
          Column {
            width: parent.width
            spacing: Style.space(4)
            Repeater {
              model: root.reviewData ? root.reviewData.review.whatChanged : []
              delegate: Text {
                width: card.width - Style.space(60)
                text: "•  " + modelData
                textFormat: Text.PlainText
                wrapMode: Text.WordWrap
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
            }
          }
          Text {
            visible: root.reviewData && root.reviewData.review.watchFor && root.reviewData.review.watchFor !== "nothing notable"
            width: card.width - Style.space(60)
            text: root.reviewData ? "⚠  " + root.reviewData.review.watchFor : ""
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            color: root.warnColor
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          // The author's own words for the change, next to the AI's read.
          //
          // Coerced to a real boolean, because there is no changelog on an
          // install: `reviewData.changelog` is then undefined, the whole
          // expression evaluates to undefined rather than false, and assigning
          // that to `visible` left the heading on screen with nothing under it.
          // It read as a plugin whose author had written release notes that
          // Plug had failed to fetch.
          Text {
            visible: !!(root.reviewData && root.reviewData.changelog
                        && root.reviewData.changelog.length > 0)
            text: "The author's notes"
            textFormat: Text.PlainText
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
          }
          Column {
            visible: !!(root.reviewData && root.reviewData.changelog
                        && root.reviewData.changelog.length > 0)
            width: parent.width
            spacing: Style.space(2)
            Repeater {
              model: root.reviewData ? root.reviewData.changelog : []
              delegate: Text {
                width: card.width - Style.space(60)
                text: "·  " + modelData
                textFormat: Text.PlainText
                wrapMode: Text.WordWrap
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }

          // A repository with no manifest is not a plugin, and `omarchy plugin
          // add` would refuse it. Saying that is more use than a verdict on
          // code that could never have been installed.
          Text {
            visible: root.reviewData && root.reviewData.isPlugin === false
            width: card.width - Style.space(60)
            text: "This repository has no manifest.json, so it is not an Omarchy "
                + "plugin and cannot be installed as one. The review above is "
                + "still a read of its code."
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            color: root.warnColor
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          // The install Plug will not do for you. Cloning a repository runs
          // nothing in it, so a plugin needing packages, a build or a service
          // ships a script and expects you to run it — and that script runs as
          // you, immediately, before a line of the plugin's own code loads.
          // Reviewing code and then executing it is the one thing this plugin
          // exists not to do, so it reads the script, says what it would do,
          // and hands the commands back.
          Column {
            id: manualBlock
            readonly property var mi: root.reviewData ? root.reviewData.manualInstall : null
            readonly property var scripts: mi && mi.scripts ? mi.scripts : []
            // A review with no manualInstall key leaves this undefined rather
            // than false, and QML refuses to assign undefined to a bool: the
            // property keeps whatever it held last, so the block stayed on
            // screen from a previous review. `!!` makes the miss a false.
            visible: !!(mi && mi.required === true)
            width: parent.width
            spacing: Style.space(6)

            Text {
              text: "Manual installation required"
              textFormat: Text.PlainText
              color: root.warnColor
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
            }
            Text {
              width: card.width - Style.space(60)
              text: "Adding this plugin only copies its files. It ships a script "
                  + "that finishes the install, which Plug will not run for you "
                  + "— run it yourself once you have read what it does."
              textFormat: Text.PlainText
              wrapMode: Text.WordWrap
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
            Repeater {
              model: manualBlock.scripts
              delegate: Column {
                width: card.width - Style.space(60)
                spacing: Style.space(2)
                Text {
                  text: modelData.file + "  ·  " + modelData.lines + " lines"
                  textFormat: Text.PlainText
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }
                Repeater {
                  model: modelData.steps || []
                  delegate: Text {
                    width: card.width - Style.space(72)
                    // Straight from the script, in the order it runs. Plain
                    // text, like everything else that came out of a stranger's
                    // repository.
                    text: "    " + modelData.text
                          + (modelData.quotedOnly ? "   (quoted, not run)" : "")
                    textFormat: Text.PlainText
                    wrapMode: Text.WrapAnywhere
                    color: root.dim
                    font.family: root.monoFamily
                    font.pixelSize: Style.font.caption
                  }
                }
              }
            }
            Text {
              width: card.width - Style.space(60)
              text: root.manualCommands(root.reviewData)
              textFormat: Text.PlainText
              wrapMode: Text.WrapAnywhere
              color: root.foreground
              font.family: root.monoFamily
              font.pixelSize: Style.font.caption
            }
          }
        }
      }
    }

    // A body that scrolls has to say so: unmarked, a review cut off at the
    // fold reads as the whole review.
    Rectangle {
      anchors.right: reviewScroll.right
      anchors.top: reviewScroll.top
      width: Style.space(4)
      height: reviewScroll.height
      radius: width / 2
      color: root.hairline
      visible: reviewScroll.contentHeight > reviewScroll.height
      Rectangle {
        width: parent.width
        radius: width / 2
        color: root.dim
        height: Math.max(Style.space(28),
                         parent.height * reviewScroll.height
                         / Math.max(1, reviewScroll.contentHeight))
        y: (parent.height - height)
           * (reviewScroll.contentY
              / Math.max(1, reviewScroll.contentHeight - reviewScroll.height))
      }
    }

    Row {
      id: reviewActions
      anchors.left: parent.left
      anchors.bottom: parent.bottom
      // The condition the enclosing Column used to carry: nothing to act on
      // while the review is still running.
      visible: !root.reviewRunning && root.reviewData !== null
      spacing: Style.space(8)
      // Same again: a missing key is undefined, not false, and these three
      // bools decide which buttons the review offers.
      readonly property bool manual: !!(root.reviewData && root.reviewData.manualInstall
                                        && root.reviewData.manualInstall.required === true)
      readonly property bool notAPlugin: !!(root.reviewData
                                            && root.reviewData.isPlugin === false)
      PlugButton {
        readonly property bool refused: !!(root.reviewData && root.reviewData.review
                                           && root.reviewData.review.verdict === "DANGER")
        // Plug installs what a clone alone completes. Where a script has
        // to run afterwards, the honest button is the one that gives you
        // the commands, not one that half-installs it and says nothing.
        visible: !parent.manual && !parent.notAPlugin
        label: root.reviewMode !== "install"
             ? (refused ? "Apply anyway" : "Apply update")
             : (refused ? "Install anyway" : "Install")
        // The update path is the one people meet again and again, and a
        // DANGER verdict there used to read "Apply update" in ordinary
        // styling, with Enter applying it unremarked.
        danger: refused
        onPicked: root.approveUpdate()
      }
      PlugButton {
        visible: parent.manual
        label: "Copy the commands"
        onPicked: root.copyText(root.manualCommands(root.reviewData))
      }
      PlugButton {
        visible: parent.manual || parent.notAPlugin
        label: "Open repository"
        onPicked: root.openRepo({ repo: root.reviewData ? root.reviewData.url : "",
                                  name: root.reviewData ? root.reviewData.name : "" })
      }
      PlugButton { label: root.reviewMode === "install" ? "Cancel" : "Not now"; onPicked: root.cancelReview() }
    }
  }

  component SettingsView: Item {
    Flickable {
      anchors.fill: parent
      contentHeight: setCol.height
      clip: true
      Column {
        id: setCol
        width: parent.width
        spacing: Style.space(16)

        // AI reviewer
        Column {
          width: parent.width
          spacing: Style.space(6)
          Text { text: "Who reviews updates"; textFormat: Text.PlainText; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.body; font.bold: true }
          Text {
            width: card.width - Style.space(60)
            text: "When an update is waiting, this is who reads the changes and tells you in plain English whether it is safe. It only ever reads — it can never change the plugin or your machine."
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
          Row {
            spacing: Style.space(6)
            Repeater {
              model: {
                var opts = []
                for (var i = 0; i < root.availableAgents.length; i++) opts.push(root.availableAgents[i])
                opts.push({ key: "none", label: "Just the offline scan" })
                return opts
              }
              delegate: Rectangle {
                width: agl.implicitWidth + Style.space(20); height: Style.space(28); radius: root.cornerRadius
                color: root.settings.reviewAgent === modelData.key ? root.selBg : "transparent"
                border.color: root.hairline; border.width: 1
                Text { id: agl; anchors.centerIn: parent; text: modelData.label; textFormat: Text.PlainText; color: root.settings.reviewAgent === modelData.key ? root.selText : root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.setAgent(modelData.key) }
              }
            }
          }
          // model, when the chosen agent has choices. A Flow rather than a
          // Row so a long local-model name wraps instead of running off the
          // panel with the last entry sliced in half at the edge.
          Flow {
            width: parent.width
            visible: {
              for (var i = 0; i < root.availableAgents.length; i++)
                if (root.availableAgents[i].key === root.settings.reviewAgent) return root.availableAgents[i].models.length > 1
              return false
            }
            spacing: Style.space(6)
            // A positioner sets its children's y, so this label carries its own
            // height and centres the text inside it rather than anchoring.
            Text { text: "model:"; textFormat: Text.PlainText; color: root.dim; height: Style.space(24); verticalAlignment: Text.AlignVCenter; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
            Repeater {
              model: {
                for (var i = 0; i < root.availableAgents.length; i++)
                  if (root.availableAgents[i].key === root.settings.reviewAgent) return root.availableAgents[i].models
                return []
              }
              delegate: Rectangle {
                width: mdl.implicitWidth + Style.space(16); height: Style.space(24); radius: root.cornerRadius
                color: root.settings.reviewModel === modelData ? root.selBg : "transparent"
                border.color: root.hairline; border.width: 1
                Text { id: mdl; anchors.centerIn: parent; text: modelData; textFormat: Text.PlainText; color: root.settings.reviewModel === modelData ? root.selText : root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.setModel(modelData) }
              }
            }
          }
        }

        Rectangle { width: parent.width; height: 1; color: root.hairline }

        // Hotkey
        Column {
          width: parent.width
          spacing: Style.space(6)
          Text { text: "Hotkey"; textFormat: Text.PlainText; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.body; font.bold: true }
          Row {
            spacing: Style.space(8)
            Rectangle {
              width: Style.space(180); height: Style.space(30); radius: root.cornerRadius
              color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.06)
              border.color: root.capturing ? root.accent : root.hairline; border.width: 1
              Text {
                anchors.centerIn: parent
                text: root.capturing ? "press keys…" : (root.settings.shortcut || "no hotkey set")
                textFormat: Text.PlainText
                color: root.capturing ? root.accent : (root.settings.shortcut ? root.foreground : root.fainter)
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
              // Re-read what Hyprland has bound before listening for a key.
              // The list was read once when the shell started and never again,
              // so a combination bound since then was not known to be taken —
              // and the whole point of the list is to explain why a key press
              // never arrives. Stale, it explains nothing and the recorder
              // looks broken instead.
              MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { root.loadBinds(); root.capturing = true; root.captureNote = "" } }
            }
            // Only offered when there is something to clear — a Clear button
            // beside "no hotkey set" is a button that does nothing.
            PlugButton {
              visible: (root.settings.shortcut || "") !== ""
              label: "clear"
              onPicked: root.clearHotkey()
            }
          }
          // Where it went, and why Clear matters. Uninstalling a plugin runs
          // nothing belonging to it, so the block Plug wrote into bindings.lua
          // would outlive the plugin with nothing left able to remove it. The
          // house standard says both lines belong on the card, not only in the
          // README, and this card had neither.
          Text {
            visible: (root.settings.shortcut || "") !== ""
            width: card.width - Style.space(60)
            text: "Bound in a marked block in ~/.config/hypr/bindings.lua, between "
                + "-- >>> plug hotkey and -- <<< plug hotkey. Every other line in "
                + "that file is left as it was."
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
          Text {
            visible: (root.settings.shortcut || "") !== ""
            width: card.width - Style.space(60)
            text: "Press clear before uninstalling Plug — removing it deletes the "
                + "script that would take the block out again."
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            color: root.warnColor
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
          Text {
            visible: root.captureNote !== ""
            text: root.captureNote
            textFormat: Text.PlainText
            color: root.warnColor
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
          Text {
            width: card.width - Style.space(60)
            text: "Off by default — Plug opens from the bar icon or a terminal without one. If you set a hotkey, Plug checks every shortcut Hyprland is actually using (including Omarchy's own, which are not in bindings.lua) and refuses a combination that is already taken."
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        Rectangle { width: parent.width; height: 1; color: root.hairline }

        // Bar icon
        Column {
          width: parent.width
          spacing: Style.space(6)
          Text { text: "Bar icon"; textFormat: Text.PlainText; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.body; font.bold: true }
          Row {
            spacing: Style.space(8)
            PlugButton { label: "show in bar"; onPicked: Quickshell.execDetached(["bash", root.pluginDir + "/plug-ctl.sh", "bar", "on", "right"]) }
            PlugButton { label: "hide from bar"; onPicked: Quickshell.execDetached(["bash", root.pluginDir + "/plug-ctl.sh", "bar", "off"]) }
          }
        }
      }
    }
  }
}
