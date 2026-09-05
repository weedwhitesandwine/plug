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
// This panel only renders and routes clicks; everything it shows comes from
// plugd.py, which it runs as a fresh process per question. Jobs that end in
// a shell reload run detached through `plugd.py job …`, leave their result
// in outcome.json, and summon Plug back to read it.
Item {
  id: root

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
  property string monoFamily: "monospace"
  readonly property color dim: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.6)
  readonly property color fainter: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.35)
  readonly property color hairline: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.14)

  // Verdict and trust colours are fixed, not theme: green must be green on
  // every theme.
  readonly property color okColor: "#3fb950"
  readonly property color warnColor: "#d29922"
  readonly property color dangerColor: "#f85149"
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
  onTabChanged: Qt.callLater(function() {
    if (!root.opened) return
    if (root.tab === "store" && typeof searchInput !== "undefined") searchInput.forceActiveFocus()
    else keyCatcher.forceActiveFocus()
  })
  property var installedRows: []
  property var officialRows: []
  property bool communityExpanded: true
  property bool officialExpanded: false
  property var catalogRows: []
  property bool catalogLoaded: false
  property string storeQuery: ""
  property bool busy: false
  property string busyNote: ""
  property string noticeText: ""
  property int selectedIndex: 0
  property string confirmRemoveId: ""
  property string pendingHighlight: ""

  // The review overlay serves two questions: "apply this update?" and
  // "install this at all?".
  property string reviewId: ""
  property var reviewData: null
  property bool reviewRunning: false
  property string reviewMode: "update"      // update | install
  property var installCandidate: null
  // Set when an install stopped because the code moved between the review
  // and the click; nothing was installed.
  property string movedName: ""
  property string movedSha: ""
  property var lastApproved: null

  // A review waiting behind the Settings tab steps aside and comes back,
  // rather than leaving Enter bound to an install nobody can see.
  readonly property bool reviewOnScreen: root.reviewId !== "" && root.tab !== "settings"

  readonly property int updateCount: {
    var n = 0
    for (var i = 0; i < root.installedRows.length; i++)
      if (root.installedRows[i].updateAvailable) n++
    return n
  }
  onUpdateCountChanged: PlugState.updateCount = root.updateCount

  property var settings: ({ reviewAgent: "claude", reviewModel: "sonnet",
                            autoCheck: true, autoCatalog: true })
  property var availableAgents: []
  property bool settingsLoaded: false

  // ------------------------------------------------------------ the engine
  //
  // Every question goes to plugd.py the same way: one bounded process, one
  // JSON answer. ask() coalesces — a request landing mid-run is served the
  // moment the run finishes, never dropped and never doubling the process.
  component Engine: Process {
    id: ep
    property string sub: ""
    property var extra: []
    property bool pending: false
    signal result(var data)
    signal failed()
    command: ["python3", root.pluginDir + "/plugd.py", sub].concat(extra)
    onExited: if (pending) { pending = false; running = true }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var d = null
        try { d = JSON.parse(text) } catch (e) { ep.failed(); return }
        ep.result(d)
      }
    }
    function ask() { if (running) pending = true; else running = true }
  }

  Engine {
    id: rowsEngine
    sub: "rows"
    onResult: function(d) {
      if (!d || !Array.isArray(d.community)) return
      root.installedRows = d.community
      root.officialRows = Array.isArray(d.official) ? d.official : []
      if (root.pendingHighlight !== "") {
        for (var h = 0; h < d.community.length; h++)
          if (d.community[h].id === root.pendingHighlight) { root.selectedIndex = h; break }
        root.pendingHighlight = ""
      }
      if (root.selectedIndex >= d.community.length)
        root.selectedIndex = Math.max(0, d.community.length - 1)
    }
  }

  // The scan is slow (over a second across a full plugin folder); rows is
  // fast. A refresh reads rows now and again when the scan lands.
  property bool snapshotPending: false
  function refreshAll() {
    rowsEngine.ask()
    if (snapshotProc.running) root.snapshotPending = true
    else root.startSnapshot()
  }

  property int snapshotKills: 0
  function startSnapshot() {
    root.snapshotPending = false
    root.snapshotKills = 0
    snapshotProc.running = true
    snapshotStall.restart()
  }
  Engine {
    id: snapshotProc
    sub: "snapshot"
    onExited: {
      snapshotStall.stop()
      root.snapshotKills = 0
      rowsEngine.ask()
      if (root.snapshotPending) { root.snapshotPending = false; root.startSnapshot() }
    }
  }
  // A scan on a stalled mount can outlive the panel's patience; the interval
  // sits above the engine's own worst case for one wedged plugin, because a
  // killed scan never writes and late beats wrong. SIGTERM first, SIGKILL on
  // the next tick.
  Timer {
    id: snapshotStall
    interval: 240000
    repeat: true
    onTriggered: {
      if (!snapshotProc.running) { snapshotStall.stop(); root.snapshotKills = 0; return }
      root.snapshotKills += 1
      if (root.snapshotKills <= 1) snapshotProc.running = false
      else if (typeof snapshotProc.signal === "function") snapshotProc.signal(9)
      else snapshotProc.running = false
    }
  }

  // The one network step behind the update flag. It defers to a running job
  // for the footer line at both ends.
  property bool updatesChecked: false
  function checkUpdates() {
    if (!root.jobRunning) { root.busy = true; root.busyNote = "Checking for updates…" }
    checkProc.running = false; checkProc.running = true
  }
  Engine {
    id: checkProc
    sub: "check-updates"
    onExited: {
      if (!root.jobRunning) { root.busy = false; root.busyNote = "" }
      root.updatesChecked = true
      rowsEngine.ask()
    }
  }

  // --------------------------------------------------------------- lifecycle
  function open(payloadJson) {
    root.opened = true
    root.tab = "installed"
    root.selectedIndex = 0
    root.confirmRemoveId = ""
    root.cancelReview()
    root.noticeText = ""
    root.pendingHighlight = ""
    root.movedName = ""; root.movedSha = ""
    root.clearJob()
    jobPoll.stop(); root.jobPollsLeft = 0
    outcomeEngine.ask()
    if (root.settings.autoCheck !== false) autoCheckTimer.restart()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  Timer { id: autoCheckTimer; interval: 500; onTriggered: if (root.opened) root.checkUpdates() }

  // A finished job writes its result to outcome.json before summoning Plug
  // back; this reads and clears it. Nothing is lost if the summon misses —
  // the file waits for the next open.
  Engine {
    id: outcomeEngine
    sub: "outcome"
    onResult: function(d) {
      if (!d || typeof d !== "object") return
      var any = false
      if (d.moved && d.moved.name) {
        root.movedName = String(d.moved.name)
        root.movedSha = d.moved.sha ? String(d.moved.sha) : ""
        any = true
      } else if (d.error) {
        root.noticeText = String(d.error).trim().split("\n").pop()
        any = true
      } else if (d.notice) {
        root.noticeText = String(d.notice)
        any = true
      }
      if (d.highlight) { root.pendingHighlight = String(d.highlight); any = true }
      if (d.tab === "settings" || d.tab === "store" || d.tab === "installed")
        root.tab = String(d.tab)
      // The shell's own registry can lag the change a job just made, so ask
      // again a few times.
      if (any) { root.jobPollsLeft = 6; jobPoll.restart() }
    }
  }

  // The host's hide() calls close() back before clearing its record, so an
  // unguarded close() recurses until the JS stack gives out.
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

  // ------------------------------------------------------------- the jobs
  //
  // A job is a whole-panel condition: the runners behind the rows are
  // shared, and every control is reading state from before the job started,
  // so the guard covers every row and every door goes through runJob().
  // Where the work is a process this panel holds, the process itself is the
  // authority — a timer must not release the guard under live work.
  property string jobId: ""
  readonly property bool jobRunning: root.jobId !== "" || toggleProc.running

  function clearJob() {
    root.busy = false; root.busyNote = ""
    root.jobId = ""
    jobWatchdog.stop()
  }

  function runJob(args, note, id) {
    if (root.jobRunning) {
      root.noticeText = "Something is already running — wait for it to finish."
      return
    }
    root.busy = true; root.busyNote = note
    root.jobId = id ? String(id) : "job"
    jobWatchdog.restart()
    root.jobPollsLeft = 8
    jobPoll.restart()
    Quickshell.execDetached(["python3", root.pluginDir + "/plugd.py", "job"].concat(args))
  }

  property int jobPollsLeft: 0
  Timer {
    id: jobPoll
    interval: 700
    repeat: true
    onTriggered: {
      rowsEngine.ask()
      root.jobPollsLeft -= 1
      if (root.jobPollsLeft <= 0) {
        stop()
        root.busy = false; root.busyNote = ""
      }
    }
  }
  // Last resort for a detached runner that dies without reporting. Sized
  // above the slowest job's worst case — an install clones over the network —
  // because releasing the guard early reopens the corridor it exists to
  // close.
  Timer {
    id: jobWatchdog
    interval: 180000
    onTriggered: {
      toggleProc.running = false
      root.clearJob(); root.refreshAll()
    }
  }

  // --------------------------------------------------------- enable/disable
  function ownsAPanel(id) {
    var lists = [root.installedRows, root.officialRows]
    for (var l = 0; l < lists.length; l++)
      for (var i = 0; i < lists[l].length; i++) {
        var r = lists[l][i]
        if (r.id !== id) continue
        var k = r.kinds || ""
        return k.indexOf("panel") >= 0 || k.indexOf("overlay") >= 0 || k.indexOf("menu") >= 0
      }
    return false
  }

  // Toggling tears nothing down, so it runs attached and re-reads when the
  // command returns — except a plugin owning a panel of its own, whose
  // toggle rebuilds every panel delegate including this one; those run
  // detached and summon Plug back.
  function setEnabled(id, on) {
    if (root.jobRunning) return
    if (root.ownsAPanel(id)) {
      root.runJob([on ? "enable" : "disable", id], (on ? "Enabling" : "Disabling") + "…", id)
      return
    }
    root.busy = true
    root.busyNote = (on ? "Enabling" : "Disabling") + "…"
    root.togglingId = id
    root.jobId = id
    jobWatchdog.restart()
    toggleProc.command = ["python3", root.pluginDir + "/plugd.py", "job",
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

  // ------------------------------------------------------------------ review
  function startReview(id) {
    root.reviewCancelled = 0
    root.reviewMode = "update"
    root.installCandidate = null
    root.reviewId = id
    root.reviewData = null
    root.reviewRunning = true
    reviewEngine.extra = [id]
    reviewEngine.running = false; reviewEngine.running = true
  }
  Engine {
    id: reviewEngine
    sub: "review"
    onResult: function(d) {
      if (d && d.review) root.reviewData = d
      else if (d && d.error) {
        root.noticeText = "Review failed: " + d.error
        root.cancelReview()
      }
    }
    onFailed: {
      // A read the user cancelled delivers a partial answer; that is not a
      // failure to report.
      if (root.reviewCancelled > 0) root.reviewCancelled -= 1
      else root.noticeText = "Could not read the review result"
    }
    onExited: root.reviewRunning = false
  }

  // The install carries the commit that was actually read: an address points
  // at whatever is there when something looks, a commit is the code the
  // reviewer judged.
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
    // Stop the work, not just the screen showing it — and count the stopped
    // engines still owed an unreadable answer, so their partial output is
    // not reported as a failure.
    if (inspectEngine.running) root.reviewCancelled += 1
    if (reviewEngine.running) root.reviewCancelled += 1
    inspectEngine.running = false
    reviewEngine.running = false
  }
  property int reviewCancelled: 0

  function revert(id) {
    root.runJob(["rollback", id], "Restoring…", id)
  }

  // The author pushed after the review; take the version that was read.
  function installApproved() {
    var a = root.lastApproved
    root.movedName = ""; root.movedSha = ""
    if (!a || !a.repo) return
    root.runJob(["install", String(a.repo).replace(/\.git$/, "") + ".git",
                 a.name, a.sha, a.id,
                 "--approved-version"], "Installing the version you approved…", a.id)
  }
  // Or read the newer code instead — the same review, on what is there now.
  function reviewMoved() {
    var a = root.lastApproved
    root.movedName = ""; root.movedSha = ""
    if (a && a.candidate) root.installFromStore(a.candidate)
  }

  // ------------------------------------------------------------------ store
  //
  // Startup reads the saved catalog and touches the network not at all. A
  // fetch happens when the Store opens with a copy older than six hours, or
  // on the refresh control. There is no timer.
  readonly property int catalogMaxAgeMs: 6 * 60 * 60 * 1000
  property string catalogFetchedAt: ""
  property bool catalogRefreshing: false
  property bool catalogQuiet: false
  function catalogIsStale() {
    if (!root.catalogLoaded) return true
    var t = Date.parse(root.catalogFetchedAt)
    if (isNaN(t)) return true
    return (Date.now() - t) > root.catalogMaxAgeMs
  }
  function loadCatalog() { catalogRead.ask() }
  function refreshCatalog(quiet) {
    if (root.catalogRefreshing) return
    root.catalogRefreshing = true
    root.catalogQuiet = (quiet === true)
    if (!root.catalogQuiet && !root.jobRunning) { root.busy = true; root.busyNote = "Fetching catalog…" }
    catalogFetch.running = false; catalogFetch.running = true
  }
  function openStore() {
    root.tab = "store"
    if (!root.catalogLoaded) root.refreshCatalog(false)
    else if (root.catalogIsStale() && root.settings.autoCatalog !== false) root.refreshCatalog(true)
  }
  Engine {
    id: catalogFetch
    sub: "catalog"
    onResult: function(d) {
      root.catalogRefreshing = false
      if (!root.jobRunning) { root.busy = false; root.busyNote = "" }
      var ok = d && d.ok === true
      var trimmed = d && d.truncated === true
      var why = (!ok && d && typeof d.error === "string")
        ? d.error.replace(/\s+/g, " ").trim().slice(0, 160) : ""
      if (!ok)
        root.noticeText = "Catalog not updated: "
          + (why === "" ? "no reason given" : why)
          + (root.catalogLoaded ? " — showing the saved copy" : "")
      else if (trimmed)
        root.noticeText = "Catalog updated — too large to show in full, so the end of the list was left out"
      else if (!root.catalogQuiet) root.noticeText = "Catalog updated"
      root.loadCatalog()
    }
    onFailed: {
      root.catalogRefreshing = false
      if (!root.jobRunning) { root.busy = false; root.busyNote = "" }
      root.noticeText = "Catalog not updated: no reason given"
        + (root.catalogLoaded ? " — showing the saved copy" : "")
      root.loadCatalog()
    }
  }
  Engine {
    id: catalogRead
    sub: "print-catalog"
    onResult: function(d) {
      if (d && Array.isArray(d.plugins)) {
        root.catalogRows = d.plugins
        root.catalogFetchedAt = (typeof d.fetchedAt === "string") ? d.fetchedAt : ""
        root.catalogLoaded = true
      }
    }
  }

  readonly property var installedIdSet: {
    var s = ({})
    for (var i = 0; i < root.installedRows.length; i++) s[root.installedRows[i].id] = true
    return s
  }
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
  // Catalog addresses are data off the internet: checked against a plain
  // https shape, passed as an argument, never through a shell.
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

  // A repository pasted by hand gets the same read a catalog entry does.
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
    root.installCandidate = { repo: url, name: url.split("/").pop(),
                              id: "", typed: true }
    root.reviewId = root.installCandidate.name
    root.reviewData = null
    root.reviewRunning = true
    inspectEngine.extra = [url]
    inspectEngine.running = false; inspectEngine.running = true
  }

  // The commands that finish a manual install, pinned to the reviewed commit
  // and chained with && so the first failure stops everything after it. A
  // script name unsafe to print on a command line is described instead.
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
      if (scripts[i].safeName === false)
        notes.push("# one script cannot be named safely on a command line — "
                   + "open " + dir + " and run it yourself after reading it")
      else
        lines.push(dir + "/" + String(scripts[i].file))
    }
    lines.push("omarchy plugin enable " + id)
    return lines.join(" &&\n") + (notes.length ? "\n" + notes.join("\n") : "")
  }
  function copyText(s) {
    if (!s) return
    Quickshell.execDetached(["wl-copy", "--", String(s)])
    root.noticeText = "Copied"
  }

  // Read it before it lands: throwaway clone, scan, full-source review,
  // nothing installed and nothing run.
  function installFromStore(c) {
    if (!c || !c.repo) return
    root.reviewCancelled = 0
    root.reviewMode = "install"
    root.installCandidate = c
    root.reviewId = c.id || c.name || "plugin"
    root.reviewData = null
    root.reviewRunning = true
    inspectEngine.extra = [c.repo]
    inspectEngine.running = false; inspectEngine.running = true
  }
  Engine {
    id: inspectEngine
    sub: "inspect"
    onResult: function(d) {
      if (d && d.review) root.reviewData = d
      else if (d && d.error) {
        root.noticeText = "Could not check it: " + d.error
        root.cancelReview()
      }
    }
    onFailed: {
      if (root.reviewCancelled > 0) root.reviewCancelled -= 1
      else root.noticeText = "Could not read the check result"
      root.cancelReview()
    }
    onExited: root.reviewRunning = false
  }

  // ------------------------------------------------------------------ settings
  function loadSettings() { settingsEngine.ask() }
  Engine {
    id: settingsEngine
    sub: "print-settings"
    onResult: function(s) {
      if (s && typeof s === "object" && !Array.isArray(s) && Object.keys(s).length > 0)
        root.settings = s
      root.settingsLoaded = true
      agentsEngine.ask()
    }
    onFailed: { root.settingsLoaded = true; agentsEngine.ask() }
  }
  Engine {
    id: agentsEngine
    sub: "agents"
    onResult: function(a) { if (Array.isArray(a)) root.availableAgents = a }
  }
  function saveSettings() {
    if (!root.settingsLoaded) return
    Quickshell.execDetached(["python3", root.pluginDir + "/plugd.py",
                             "set-settings", JSON.stringify(root.settings)])
  }
  function setAgent(key) {
    var s = JSON.parse(JSON.stringify(root.settings))
    s.reviewAgent = key
    for (var i = 0; i < root.availableAgents.length; i++)
      if (root.availableAgents[i].key === key) s.reviewModel = root.availableAgents[i].defaultModel
    root.settings = s
    root.saveSettings()
  }
  function setModel(m) {
    var s = JSON.parse(JSON.stringify(root.settings)); s.reviewModel = m
    root.settings = s; root.saveSettings()
  }

  // `hyprctl binds` is the authoritative list of taken shortcuts, including
  // Omarchy's own that never appear in bindings.lua.
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
    if (root.takenBinds[combo] === true) {
      root.captureNote = combo + " is already used by something else — try another."
      return
    }
    // Checked here as well as in plug-ctl.sh: two independent guards on a
    // value that becomes Lua source.
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
        if (root.movedName !== "" && root.reviewId === "") {
          if (e.key === Qt.Key_Escape) { root.movedName = ""; root.movedSha = "" }
          e.accepted = true
          return
        }
        if (root.reviewOnScreen) {
          if (e.key === Qt.Key_Escape) { root.cancelReview(); e.accepted = true }
          else if ((e.key === Qt.Key_Return || e.key === Qt.Key_Enter)
                   && root.reviewData && !root.reviewRunning
                   && !(root.reviewData.manualInstall
                        && root.reviewData.manualInstall.required === true)
                   && root.reviewData.isPlugin !== false) { root.approveUpdate(); e.accepted = true }
          return
        }
        // Escape unwinds one layer at a time, then closes.
        if (e.key === Qt.Key_Escape) {
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
        // clicked.
        if (root.tab === "store") {
          if (e.key === Qt.Key_Backspace) {
            root.storeQuery = root.storeQuery.slice(0, -1); e.accepted = true; return
          }
          if (e.text && e.text.length === 1 && e.text.charCodeAt(0) >= 0x20
              && !(e.modifiers & (Qt.ControlModifier | Qt.MetaModifier | Qt.AltModifier))) {
            root.storeQuery += e.text; e.accepted = true; return
          }
        }

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

      // Absorbs clicks that land on the card and miss a control, so they do
      // not fall through to the scrim and close the panel.
      MouseArea { anchors.fill: parent }

      Column {
        anchors.fill: parent
        anchors.margins: Style.space(18)
        spacing: Style.space(12)

        // -------- header: title, tabs, update badge
        Item {
          width: parent.width
          height: Style.space(30)
          Row {
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(10)
            Text {
              text: "  Plug"
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

          // The author pushed while the review was on screen; nothing was
          // installed, and only the user can choose which way forward.
          Rectangle {
            id: movedScreen
            visible: root.movedName !== "" && root.reviewId === ""
            anchors.fill: parent
            color: root.background
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

            Rectangle {
              id: searchBox
              width: parent.width
              height: Style.space(32)
              radius: root.cornerRadius
              color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b,
                             searchInput.activeFocus ? 0.10 : 0.06)
              border.color: searchInput.activeFocus ? root.accent : root.hairline
              border.width: 1

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
                    maximumLength: 128
                    cursorVisible: activeFocus
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
                Item {
                  id: refreshBtn
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

            // A pasted address matches no catalog entry, so it gets its own
            // row instead of an empty list.
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

            Item {
              width: parent.width
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

  // Compact row, two-up. Every community row carries the same four controls
  // in the same order — update · restore · remove · on/off; official rows
  // show only the switch, anchored at the same right edge.
  component InstalledRow: Rectangle {
    property var rowData: null
    property bool confirming: false
    property bool selected: false
    property bool selectable: false
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

    Row {
      id: controls
      anchors.right: parent.right
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(5)

      // update — green and pressable when changes are waiting.
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
      // restore — lit once there is a previous version recorded.
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
          onClicked: {
            if (working) return
            if (root.confirmRemoveId === rowData.id) root.removeConfirmed(rowData.id)
            else root.askRemove(rowData.id)
          }
        }
      }
      // on/off — always last, so it lines up on every row.
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
      // trust mark — a check for clean, a circle for the honest middle, an
      // exclamation for red: a warning to read the code, not a stop sign.
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

          // `!!` throughout: a missing key is undefined, and undefined
          // assigned to `visible` leaves the previous value standing.
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

          // The install Plug will not do for you: the script is read,
          // described, and handed back — reviewing code and then executing
          // it is the one thing this plugin exists not to do.
          Column {
            id: manualBlock
            readonly property var mi: root.reviewData ? root.reviewData.manualInstall : null
            readonly property var scripts: mi && mi.scripts ? mi.scripts : []
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

    // A body that scrolls has to say so, or a review cut off at the fold
    // reads as the whole review.
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
      visible: !root.reviewRunning && root.reviewData !== null
      spacing: Style.space(8)
      readonly property bool manual: !!(root.reviewData && root.reviewData.manualInstall
                                        && root.reviewData.manualInstall.required === true)
      readonly property bool notAPlugin: !!(root.reviewData
                                            && root.reviewData.isPlugin === false)
      PlugButton {
        readonly property bool refused: !!(root.reviewData && root.reviewData.review
                                           && root.reviewData.review.verdict === "DANGER")
        visible: !parent.manual && !parent.notAPlugin
        label: root.reviewMode !== "install"
             ? (refused ? "Apply anyway" : "Apply update")
             : (refused ? "Install anyway" : "Install")
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
          // A Flow, so a long local-model name wraps instead of running off
          // the panel.
          Flow {
            width: parent.width
            visible: {
              for (var i = 0; i < root.availableAgents.length; i++)
                if (root.availableAgents[i].key === root.settings.reviewAgent) return root.availableAgents[i].models.length > 1
              return false
            }
            spacing: Style.space(6)
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
              // Re-read what Hyprland has bound before listening, so a
              // taken combination can be explained rather than silently
              // swallowed by the compositor.
              MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { root.loadBinds(); root.capturing = true; root.captureNote = "" } }
            }
            PlugButton {
              visible: (root.settings.shortcut || "") !== ""
              label: "clear"
              onPicked: root.clearHotkey()
            }
          }
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
            PlugButton { label: "show in bar"; onPicked: root.runJob(["bar", "on", "right"], "Updating bar icon…", "bar") }
            PlugButton { label: "hide from bar"; onPicked: root.runJob(["bar", "off"], "Updating bar icon…", "bar") }
          }
        }
      }
    }
  }
}
