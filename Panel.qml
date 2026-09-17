import QtQuick
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons
import "Model.js" as Model

// NordVPN bar widget + drop-down panel. The collapsed widget shows the
// connected country (and optional live throughput); the panel exposes quick
// connect / disconnect, live network stats, favorites, and an interactive
// world map + searchable country list. All colors come from the active
// Omarchy theme via the qs.Commons Color singleton.
Panel {
  id: root
  moduleName: "ayan.nordvpn"
  ipcTarget: "ayan.nordvpn"

  implicitWidth: barButton.width
  implicitHeight: bar ? bar.barSize : 26

  // -------------------------------------------------------------- state ----
  property var status: Model.parseStatus("")
  property bool loggedIn: true
  property bool daemonUp: true
  property bool inGroup: true
  property bool hasCli: true
  property bool busy: false
  property string busyLabel: ""

  // --------------------------------------------------- trusted execution ----
  // Every external program is invoked by its absolute, package-owned path so
  // a shadowed/earlier PATH entry can never be picked up instead — these are
  // the paths `nordvpn`/`sh`/etc. actually resolve to on an Omarchy (Arch)
  // install, hardcoded rather than looked up through the inherited PATH.
  readonly property string binSh: "/usr/bin/sh"
  readonly property string binBash: "/usr/bin/bash"
  readonly property string binNordvpn: "/usr/bin/nordvpn"
  readonly property string binPkexec: "/usr/bin/pkexec"
  readonly property string binSystemctl: "/usr/bin/systemctl"
  readonly property string binUsermod: "/usr/bin/usermod"
  readonly property string binPing: "/usr/bin/ping"
  readonly property string binWlCopy: "/usr/bin/wl-copy"
  readonly property string binLaunchBrowser: "/usr/bin/omarchy-launch-browser"

  // Minimal env for plain CLI helpers: just enough for them to find $HOME and
  // resolve any command they shell out to internally, nothing inherited from
  // this process that they don't need.
  readonly property var minimalEnv: ({
    "HOME": Quickshell.env("HOME") || "",
    "USER": Quickshell.env("USER") || Quickshell.env("LOGNAME") || "",
    "PATH": "/usr/bin"
  })
  // pkexec needs to reach the session's polkit authentication agent over the
  // session bus, and wl-copy needs the Wayland socket — both otherwise absent
  // from minimalEnv.
  readonly property var sessionEnv: {
    var e = {};
    for (var k in root.minimalEnv) e[k] = root.minimalEnv[k];
    e["XDG_RUNTIME_DIR"] = Quickshell.env("XDG_RUNTIME_DIR") || "";
    e["DBUS_SESSION_BUS_ADDRESS"] = Quickshell.env("DBUS_SESSION_BUS_ADDRESS") || "";
    e["WAYLAND_DISPLAY"] = Quickshell.env("WAYLAND_DISPLAY") || "";
    return e;
  }

  // Bounds a Process's lifetime: SIGTERM after `termMs` of running, SIGKILL
  // after a further `killMs` if it ignored that. Without this a shadowed or
  // wedged CLI standing in for `nordvpn`/etc. would run — and hold its
  // StdioCollector output — forever, since none of these processes otherwise
  // have any timeout of their own.
  component ProcGuard: Item {
    id: guard
    property Process target
    property int termMs: 8000
    property int killMs: 3000
    readonly property bool targetRunning: target ? target.running : false
    onTargetRunningChanged: {
      if (targetRunning) termTimer.restart();
      else { termTimer.stop(); killTimer.stop(); }
    }
    Timer {
      id: termTimer
      interval: guard.termMs
      repeat: false
      onTriggered: {
        if (guard.target && guard.target.running) {
          guard.target.signal(15);
          killTimer.restart();
        }
      }
    }
    Timer {
      id: killTimer
      interval: guard.killMs
      repeat: false
      onTriggered: { if (guard.target && guard.target.running) guard.target.signal(9); }
    }
  }

  // ProcGuard bounds wall-clock time, not bytes: a fast (or malicious)
  // producer standing in for `nordvpn`/etc. could still exhaust memory in
  // StdioCollector well before a timeout fires. StdioCollector's `dataChanged`
  // fires as each chunk of output arrives — unlike a line-based parser it
  // isn't waiting on a delimiter, so this reacts immediately rather than
  // buffering an unbounded "unterminated record". The instant accumulated
  // output crosses the cap, the owning process is killed outright (SIGKILL,
  // not just asked to stop) so no further output is produced.
  readonly property int outputCapBytes: 65536
  component OutputCap: Connections {
    property Process guarded
    property int capBytes: root.outputCapBytes
    // Verified live: referencing this Connections' own `id` from inside its
    // signal handler throws "ReferenceError: <id> is not defined" when the
    // Connections is an inline `component` type instantiated elsewhere —
    // true both for "onDataChanged: {...}" and "function onDataChanged()"
    // forms. Unqualified access to `target` (built into Connections) and to
    // this component's own properties works fine, so that's what's used
    // here instead of a self-id prefix.
    onDataChanged: {
      if (target && target.text && target.text.length > capBytes && guarded && guarded.running)
        guarded.signal(9);
    }
  }
  property string tab: "map"
  property string hoverName: ""
  property string hoverMeta: ""

  // A brand-new install (no `nordvpn` binary, service not running, user not
  // in the `nordvpn` group yet, or simply never logged in) is walked through
  // one blocker at a time by the setup view instead of showing the normal
  // connect/map/list UI. Checked in this order because each earlier one
  // makes every later signal meaningless (no binary -> no daemon reply -> etc).
  readonly property string blocker: {
    if (!hasCli) return "nocli";
    if (!inGroup) return "nogroup";
    if (!daemonUp) return "nodaemon";
    if (!loggedIn) return "loggedout";
    return "none";
  }

  // ------------------------------------------------------------- login ----
  property bool loginBusy: false
  property string loginStatusText: ""
  property string loginError: ""
  property string loginUrl: ""
  property bool loginUrlOpened: false
  property string loginOutputBuf: ""
  // Raw per-stream accumulation backing loginOutputBuf, each capped to
  // outputCapBytes so neither this buffer nor the underlying collector can
  // grow unbounded even if the process is never terminated in time.
  property string _loginOutText: ""
  property string _loginErrText: ""

  function startLogin() {
    if (loginProc.running) return;
    loginError = "";
    loginUrl = "";
    loginUrlOpened = false;
    loginOutputBuf = "";
    root._loginOutText = "";
    root._loginErrText = "";
    loginStatusText = "Opening nordvpn.com in your browser…";
    loginBusy = true;
    // A truly first-ever run of `nordvpn` on a machine (no prior config at
    // all — verified live right after a fresh install) shows a one-time
    // interactive analytics consent prompt ("(y/n)") before doing anything
    // else, including login. With no TTY attached — as here — it just blocks
    // forever with zero output, which looks exactly like "stuck, nothing
    // happens". Piping "n" into stdin answers it (declining analytics, the
    // more private default) and is a harmless no-op if the prompt doesn't
    // come up (already answered on a prior run).
    var quoted = [root.binNordvpn, "login"].map(function (a) { return root.shQuote(a); }).join(" ");
    loginProc.command = [root.binBash, "-c", "printf 'n\\n' | " + quoted];
    loginProc.running = true;
    loginUrlTimeoutTimer.restart();
  }

  // There is deliberately no manual "paste callback URL" / "paste token"
  // fallback here. `nordvpn login --callback <url>` and `--token <token>`
  // both take the credential as a plain argv element — the CLI's own
  // non-interactive error text confirms it has no other input path
  // ("provide the token as an argument using the 'nordvpn login --token
  // <TOKEN>' command"), and Quickshell's Process has no way to allocate a
  // pty for the interactive stdin prompt the CLI otherwise expects. Any
  // argv-passed secret is readable by other processes on the host via
  // /proc/<pid>/cmdline, so submitting a token/callback link this way would
  // leak it — the browser-driven flow above is the only login path that
  // keeps the credential out of a command line entirely.

  // `nordvpn login` prints its URL and then blocks — sometimes for as long as
  // the browser round-trip takes — so we can't wait for the process to exit
  // before showing it. `text` is the *entire* cumulative content of one
  // stream so far (from a live, not-yet-exited StdioCollector — see loginProc
  // below), which is why it's stored (capped) rather than appended: it always
  // replaces, never accumulates on top of, what we saw last time for that
  // stream. Matches the same shape of problem in
  // ../panels/tailscale/Service.qml's handleLoginOutput/openAuthUrlFrom.
  function handleLoginOutput(text, isError) {
    var capped = String(text || "").slice(-root.outputCapBytes);
    if (isError) root._loginErrText = capped; else root._loginOutText = capped;
    root.loginOutputBuf = root._loginOutText + "\n" + root._loginErrText;
    if (loginUrlOpened) return;
    var m = capped.match(/https?:\/\/\S+/);
    if (!m) return;
    loginUrl = m[0];
    loginUrlOpened = true;
    loginUrlTimeoutTimer.stop();
    loginStatusText = "Waiting for you to finish in the browser…";
    Quickshell.execDetached({ command: [root.binLaunchBrowser, loginUrl] });
    loginPollTimer.restart();
  }

  property bool setupBusy: false
  property string setupMessage: ""

  property var countryData: ({})              // code -> { name, serverCount, cities }
  property var worldPaths: ({ viewBox: [0, 0, 1000, 500], paths: {} })
  property var favorites: []
  property var recents: []
  property string searchText: ""
  property real latencyMs: -1

  readonly property bool connected: status.connected
  readonly property string countryName: status.country
  readonly property string currentCode: nameToCode[normalizeName(status.country)] || ""

  // Highlight color for every "active / attention" surface (bar dot + label,
  // panel header, selected tab, map current/hover fills). Comes from the
  // theme's `[bar] active` shell.toml token — the same one other bar widgets
  // use for recording / alert / update states — so it matches the palette
  // (red on Tokyo Night). Falls back to urgent, then accent.
  readonly property color hiColor: Color.bar.active

  // throughput, derived from `Transfer` deltas between status polls
  property real prevIn: 0
  property real prevOut: 0
  property real prevT: 0
  property real rateIn: 0
  property real rateOut: 0

  // ------------------------------------------------------- derived data ----
  readonly property var nameToCode: {
    var m = ({});
    for (var code in countryData) m[normalizeName(countryData[code].name)] = code;
    return m;
  }
  readonly property var allCountries: {
    var arr = [];
    for (var code in countryData) {
      var c = countryData[code];
      arr.push({ code: code, name: c.name, serverCount: c.serverCount || 0 });
    }
    arr.sort(function (a, b) { return a.name.localeCompare(b.name); });
    return arr;
  }
  readonly property var listRows: {
    var q = searchText.trim().toLowerCase();
    var favs = favorites;
    var rows = allCountries.filter(function (c) {
      return !q || c.name.toLowerCase().indexOf(q) >= 0 || c.code.toLowerCase() === q;
    });
    rows.sort(function (a, b) {
      var fa = favs.indexOf(a.code) >= 0, fb = favs.indexOf(b.code) >= 0;
      if (fa !== fb) return fa ? -1 : 1;
      return a.name.localeCompare(b.name);
    });
    return rows;
  }

  function normalizeName(n) { return String(n || "").trim().toLowerCase(); }

  // ------------------------------------------------------------ actions ----
  function refreshStatus() {
    if (!statusProc.running) statusProc.running = true;
    if (!accountProc.running) accountProc.running = true;
    // Cheap enough to recheck every poll: flips `hasCli` on its own the
    // moment the user installs the package, without needing a manual retry.
    if (!cliProbe.running) cliProbe.running = true;
  }

  function shQuote(s) { return "'" + String(s).replace(/'/g, "'\\''") + "'"; }

  property string toastText: ""

  function showToast(text) {
    toastText = text;
    toastTimer.restart();
  }

  // Handed to wl-copy over stdin rather than embedded in a `sh -c "..."`
  // script string: the latter would put the copied value (e.g. the live
  // login URL) into that shell's own argv, readable by any other local
  // process via /proc/<pid>/cmdline for as long as it runs — shQuote
  // prevents injection but does nothing to prevent that exposure.
  function copyText(s) {
    copyProc.pendingText = String(s || "");
    copyProc.command = [root.binWlCopy];
    copyProc.stdinEnabled = true;
    copyProc.running = true;
    showToast("Copied to clipboard");
  }

  Timer { id: toastTimer; interval: 1600; onTriggered: root.toastText = "" }

  // One-off privileged/system fixes for the setup flow (start the daemon,
  // join the nordvpn group). Kept separate from runAction/busy: these use
  // pkexec, are rare, and shouldn't be gated by the VPN "busy" state.
  function runSetupFix(cmd, label) {
    if (setupProc.running) return;
    setupBusy = true;
    setupMessage = label;
    setupProc.command = cmd;
    setupProc.running = true;
  }

  function runAction(args, label) {
    if (busy) return;
    busy = true;
    busyLabel = label;
    actionProc.command = [root.binNordvpn].concat(args);
    actionProc.running = true;
  }

  function quickConnect() {
    var target = setting("quickConnectTarget", "");
    runAction(target && target.length > 0 ? ["connect", target] : ["connect"],
              target && target.length > 0 ? ("Connecting to " + target) : "Connecting…");
  }

  function disconnect() { runAction(["disconnect"], "Disconnecting…"); }

  function connectCountry(code, name) {
    if (!code) return;
    runAction(["connect", String(code).toLowerCase()], "Connecting to " + (name || code));
    rememberRecent(code);
  }

  function toggleFavorite(code) {
    var f = favorites.slice();
    var i = f.indexOf(code);
    if (i >= 0) f.splice(i, 1); else f.unshift(code);
    favorites = f;
    persistPrefs();
  }

  function rememberRecent(code) {
    if (!code) return;
    var r = recents.slice();
    var i = r.indexOf(code);
    if (i >= 0) r.splice(i, 1);
    r.unshift(code);
    recents = r.slice(0, 6);
    persistPrefs();
  }

  function cycleFavorite(dir) {
    if (!favorites.length) return;
    var idx = favorites.indexOf(currentCode);
    idx = (idx + (dir > 0 ? 1 : favorites.length - 1)) % favorites.length;
    var code = favorites[idx];
    connectCountry(code, (countryData[code] || {}).name || code);
  }

  function applyStatus(text, ok) {
    var raw = String(text || "");
    var permissionIssue = /permission denied|operation not permitted/i.test(raw);
    root.inGroup = !permissionIssue;
    root.daemonUp = ok && !permissionIssue &&
      !/(could not connect|failed to connect|daemon|socket|connection refused|is not running|no such file)/i.test(raw);
    // `nordvpn status` says nothing about login state when logged out (just
    // "Status: Disconnected") — the login check runs off `nordvpn account`
    // instead, in accountProc below.
    var s = Model.parseStatus(raw);
    var now = Date.now() / 1000;
    if (s.connected && prevT > 0 && s.transferIn >= prevIn) {
      var dt = now - prevT;
      if (dt > 0.3) {
        rateIn = Math.max(0, (s.transferIn - prevIn) / dt);
        rateOut = Math.max(0, (s.transferOut - prevOut) / dt);
      }
    } else {
      rateIn = 0;
      rateOut = 0;
    }
    if (s.connected) { prevIn = s.transferIn; prevOut = s.transferOut; prevT = now; }
    else { prevIn = 0; prevOut = 0; prevT = 0; latencyMs = -1; }
    root.status = s;
  }

  // --------------------------------------------------------- data load ----
  readonly property string pluginDir: Qt.resolvedUrl(".").toString().replace(/^file:\/\//, "")

  FileView {
    id: countriesFile
    path: root.pluginDir + "data/countries.json"
    printErrors: false
    onLoaded: { try { root.countryData = JSON.parse(text()); } catch (e) { console.warn("ayan.nordvpn: countries.json parse error", e); } }
    onLoadFailed: function (err) { console.warn("ayan.nordvpn: countries.json load failed", err); }
  }
  FileView {
    id: worldFile
    path: root.pluginDir + "data/world-paths.json"
    printErrors: false
    onLoaded: { try { root.worldPaths = JSON.parse(text()); } catch (e) { console.warn("ayan.nordvpn: world-paths.json parse error", e); } }
    onLoadFailed: function (err) { console.warn("ayan.nordvpn: world-paths.json load failed", err); }
  }

  // Checking the state directory once and writing through a separately
  // re-resolved path (e.g. a FileView) later leaves a gap: the pathname gets
  // walked a second time, from scratch, at save time, so nothing ties that
  // write back to the specific directory object that was actually validated
  // — it could have been swapped for a symlink in between. Instead, the
  // check and the write happen back-to-back inside one shell invocation:
  // `cd` into the validated directory once, then do every subsequent
  // operation (mktemp/write/rename) with a bare relative name. A process's
  // working directory is bound to the directory's inode at the time of
  // `cd`, not re-resolved from the path string afterwards, so this is the
  // shell-level equivalent of holding an fd opened O_NOFOLLOW on that
  // directory — later replacing "omarchy-nordvpn" on disk can't redirect
  // operations this same script already `cd`-ed into. The write itself is
  // still a randomized temp file + rename within that directory, so it's
  // atomic and never follows a symlink at the destination name either.
  readonly property string prefsDir: (Quickshell.env("HOME") || "") + "/.local/state/omarchy-nordvpn"
  readonly property string prefsPath: root.prefsDir + "/prefs.json"

  function persistPrefs() {
    // Never let a write failure bubble into a caller (e.g. connectCountry).
    try {
      var json = root.shQuote(JSON.stringify({ favorites: favorites, recents: recents }));
      var script = [
        "set -e",
        "umask 077",
        "base=\"$HOME/.local/state\"",
        "mkdir -p \"$base\"",
        "cd \"$base\"",
        "name=omarchy-nordvpn",
        "if [ -e \"$name\" ] && [ -L \"$name\" ]; then echo 'refusing symlinked state dir' >&2; exit 1; fi",
        "mkdir \"$name\" 2>/dev/null || true",
        // Re-check right before cd'ing in: mkdir's "already exists" failure
        // is only benign if what already exists is still the real directory,
        // not a symlink dropped in the instant between the check above and
        // this mkdir attempt.
        "[ -d \"$name\" ] && [ ! -L \"$name\" ]",
        "cd \"$name\"",
        "tmp=$(mktemp ./.prefs.XXXXXXXXXX)",
        "printf %s " + json + " > \"$tmp\" && mv -T \"$tmp\" prefs.json"
      ].join(" && ");
      prefsWriteProc.command = [root.binSh, "-c", script];
      prefsWriteProc.running = true;
    } catch (e) {
      console.warn("ayan.nordvpn: could not persist prefs", e);
    }
  }

  Component.onCompleted: {
    countriesFile.reload();
    worldFile.reload();
    reloadPrefsIfSafe();
    cliProbe.running = true;
    refreshStatus();
  }

  onOpenedChanged: {
    if (opened) refreshStatus();
  }

  // ------------------------------------------------------------ procs -----
  Process {
    id: statusProc
    command: [root.binNordvpn, "status"]
    clearEnvironment: true
    environment: root.minimalEnv
    stdout: StdioCollector { id: statusOut; waitForEnd: false }
    stderr: StdioCollector { id: statusErr; waitForEnd: false }
    onExited: function (code) {
      root.applyStatus((statusOut.text || "") + "\n" + (statusErr.text || ""), code === 0);
    }
  }
  ProcGuard { target: statusProc; termMs: 6000; killMs: 2000 }
  OutputCap { target: statusOut; guarded: statusProc }
  OutputCap { target: statusErr; guarded: statusProc }

  // `nordvpn status` never mentions login state (logged-out just reads
  // "Status: Disconnected") — `nordvpn account` is the one command that
  // actually says "You're not logged in.", so login detection runs off this.
  Process {
    id: accountProc
    command: [root.binNordvpn, "account"]
    clearEnvironment: true
    environment: root.minimalEnv
    stdout: StdioCollector { id: accountOut; waitForEnd: false }
    stderr: StdioCollector { id: accountErr; waitForEnd: false }
    onExited: {
      var raw = (accountOut.text || "") + (accountErr.text || "");
      root.loggedIn = !/not logged in/i.test(raw);
    }
  }
  ProcGuard { target: accountProc; termMs: 6000; killMs: 2000 }
  OutputCap { target: accountOut; guarded: accountProc }
  OutputCap { target: accountErr; guarded: accountProc }

  Process {
    id: actionProc
    clearEnvironment: true
    environment: root.minimalEnv
    stdout: StdioCollector { id: actionOut; waitForEnd: false }
    stderr: StdioCollector { id: actionErr; waitForEnd: false }
    onExited: function () {
      root.busy = false;
      root.busyLabel = "";
      root.prevT = 0;               // reset throughput baseline after a switch
      root.refreshStatus();
      settleTimer.restart();
    }
  }
  ProcGuard { target: actionProc; termMs: 20000; killMs: 3000 }
  OutputCap { target: actionOut; guarded: actionProc }
  OutputCap { target: actionErr; guarded: actionProc }

  Process {
    id: copyProc
    property string pendingText: ""
    clearEnvironment: true
    environment: root.sessionEnv
    onStarted: {
      write(pendingText);
      stdinEnabled = false;   // closes stdin so wl-copy sees EOF
      pendingText = "";
    }
  }
  ProcGuard { target: copyProc; termMs: 5000; killMs: 2000 }

  Process {
    id: cliProbe
    command: [root.binSh, "-c", "[ -x " + root.shQuote(root.binNordvpn) + " ]"]
    clearEnvironment: true
    environment: root.minimalEnv
    onExited: function (code) { root.hasCli = (code === 0); }
  }
  ProcGuard { target: cliProbe; termMs: 5000; killMs: 2000 }

  // Validates the state directory and writes prefs.json in one shell
  // invocation — see the comment on persistPrefs() for why the check and the
  // write can't be split across separate steps/mechanisms.
  Process {
    id: prefsWriteProc
    clearEnvironment: true
    environment: root.minimalEnv
    stdout: StdioCollector { id: prefsWriteOut; waitForEnd: false }
    stderr: StdioCollector { id: prefsWriteErr; waitForEnd: false }
    onExited: function (code) {
      if (code !== 0)
        console.warn("ayan.nordvpn: could not persist prefs", prefsWriteErr.text || prefsWriteOut.text || code);
    }
  }
  ProcGuard { target: prefsWriteProc; termMs: 5000; killMs: 2000 }
  OutputCap { target: prefsWriteOut; guarded: prefsWriteProc }
  OutputCap { target: prefsWriteErr; guarded: prefsWriteProc }

  // Privileged/system one-off fixes for the setup flow (start the daemon
  // service, add the user to the `nordvpn` group). Separate from actionProc
  // so a pkexec prompt never fights with the VPN connect/disconnect "busy"
  // state, and a cancelled prompt doesn't get reported as a VPN error.
  Process {
    id: setupProc
    clearEnvironment: true
    environment: root.sessionEnv
    stdout: StdioCollector { id: setupOut; waitForEnd: false }
    stderr: StdioCollector { id: setupErr; waitForEnd: false }
    onExited: function (code) {
      root.setupBusy = false;
      var text = (setupOut.text || "") + (setupErr.text || "");
      root.setupMessage = (code !== 0 && /dismiss|not authorized|cancel/i.test(text))
        ? "Cancelled." : "";
      root.refreshStatus();
      settleTimer.restart();
    }
  }
  // pkexec blocks on the user entering their password in the polkit agent
  // dialog, which can legitimately sit open for a while — give it much more
  // rope than a plain CLI call before treating it as wedged.
  ProcGuard { target: setupProc; termMs: 120000; killMs: 5000 }
  OutputCap { target: setupOut; guarded: setupProc }
  OutputCap { target: setupErr; guarded: setupProc }

  // `nordvpn login` prints "Continue in the browser: <url>" and then BLOCKS
  // until the browser round-trip completes (confirmed live: sometimes that's
  // ~1s, sometimes it sits for as long as the user takes in the browser) —
  // so output is watched live via a non-waiting StdioCollector instead of
  // collected and read only at exit; otherwise the URL would never reach the
  // UI while the process is still waiting. A line-splitting parser would
  // buffer an entire record with no visible size until its delimiter showed
  // up, which is exactly the "unterminated record" a hostile/wedged CLI could
  // abuse; StdioCollector instead exposes (and grows) its `text` on every
  // chunk regardless of line breaks, so handleLoginOutput/OutputCap see and
  // cap it continuously. onExited is still the fallback for success/failure
  // text once the process does finally exit.
  Process {
    id: loginProc
    clearEnvironment: true
    environment: root.minimalEnv
    stdout: StdioCollector { id: loginStdout; waitForEnd: false }
    stderr: StdioCollector { id: loginStderr; waitForEnd: false }
    onExited: function (code) {
      var text = root.loginOutputBuf;
      root.refreshStatus();
      if (/logged in|welcome|already logged in/i.test(text)) {
        root.loginBusy = false;
        root.loginStatusText = "";
        root.loginUrl = "";
      } else if (!root.loginUrlOpened && (code !== 0 || /error|invalid|expired|fail/i.test(text))) {
        root.loginBusy = false;
        root.loginStatusText = "";
        root.loginUrl = "";
        root.loginError = "Login didn't go through — try again.";
      } else if (!root.loginUrlOpened) {
        // Exited without ever printing a URL and without a clear error —
        // rely on the account poll to notice a login that did go through.
        root.loginStatusText = "Finishing up…";
        loginPollTimer.restart();
      }
      // If a URL was already opened, handleLoginOutput has already put us
      // into "waiting for the browser" and started the poll — leave it be.
    }
  }
  // The browser round-trip is user-paced; give it generous rope before
  // assuming the process itself (not just the human) is stuck.
  ProcGuard { target: loginProc; termMs: 300000; killMs: 5000 }
  Connections { target: loginStdout; onDataChanged: root.handleLoginOutput(loginStdout.text, false) }
  Connections { target: loginStderr; onDataChanged: root.handleLoginOutput(loginStderr.text, true) }
  OutputCap { target: loginStdout; guarded: loginProc }
  OutputCap { target: loginStderr; guarded: loginProc }

  // If no URL shows up at all within 12s (e.g. the daemon is unreachable, or
  // this version of the CLI changed its wording), stop looking like it's
  // silently working forever.
  Timer {
    id: loginUrlTimeoutTimer
    interval: 12000
    repeat: false
    onTriggered: {
      if (root.loginUrlOpened) return;
      root.loginBusy = false;
      root.loginStatusText = "";
      root.loginError = "No login link showed up yet — try again.";
    }
  }

  Timer {
    id: loginPollTimer
    interval: 2000
    repeat: true
    property int ticks: 0
    onRunningChanged: if (running) ticks = 0
    onTriggered: {
      root.refreshStatus();
      ticks++;
      if (root.loggedIn) {
        running = false;
        root.loginBusy = false;
        root.loginStatusText = "";
      } else if (ticks >= 60) {   // ~2 minutes
        running = false;
        root.loginBusy = false;
        root.loginStatusText = "";
        root.loginError = "Still not logged in — click \"Log in with browser\" again if the browser didn't bring you back.";
      }
    }
  }

  Process {
    id: pingProc
    clearEnvironment: true
    environment: root.minimalEnv
    stdout: StdioCollector { id: pingOut; waitForEnd: false }
    onExited: function () {
      var m = String(pingOut.text || "").match(/time[=<]([\d.]+)\s*ms/i);
      root.latencyMs = m ? parseFloat(m[1]) : -1;
    }
  }
  ProcGuard { target: pingProc; termMs: 5000; killMs: 2000 }
  OutputCap { target: pingOut; guarded: pingProc }

  // Poll cadence: relaxed when the panel is closed, snappier while it is open.
  Timer {
    id: pollTimer
    interval: root.opened ? 2500 : 10000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.refreshStatus()
  }

  // A connect/disconnect settles asynchronously; re-poll a few times after.
  Timer {
    id: settleTimer
    interval: 1200
    repeat: true
    property int ticks: 0
    running: false
    onRunningChanged: if (running) ticks = 0
    onTriggered: {
      root.refreshStatus();
      if (++ticks >= 4) { running = false; }
    }
  }

  Timer {
    interval: 4000
    repeat: true
    running: root.opened && root.connected && root.status.ip !== ""
    triggeredOnStart: true
    onTriggered: {
      if (pingProc.running) return;
      pingProc.command = [root.binPing, "-n", "-c", "1", "-W", "1", root.status.ip];
      pingProc.running = true;
    }
  }

  // Mirrors the write side's symlink check: a plain FileView read follows
  // symlinks, so without this, swapping the state dir or prefs.json for a
  // symlink would make the widget load and trust whatever that points at
  // as "favorites"/"recents". preload is off so the very first load also
  // goes through this check rather than firing automatically on `path` being
  // set.
  function reloadPrefsIfSafe() {
    if (prefsCheckProc.running) return;
    prefsCheckProc.command = [root.binSh, "-c",
      "[ ! -L " + root.shQuote(root.prefsDir) + " ] && [ ! -L " + root.shQuote(root.prefsPath) + " ]"];
    prefsCheckProc.running = true;
  }

  Process {
    id: prefsCheckProc
    clearEnvironment: true
    environment: root.minimalEnv
    onExited: function (code) {
      if (code === 0) prefsFile.reload();
      else console.warn("ayan.nordvpn: refusing to read prefs (symlinked path)");
    }
  }
  ProcGuard { target: prefsCheckProc; termMs: 5000; killMs: 2000 }

  FileView {
    id: prefsFile
    path: root.prefsPath
    watchChanges: true
    preload: false
    printErrors: false
    onLoaded: {
      try {
        var d = JSON.parse(text());
        root.favorites = Array.isArray(d.favorites) ? d.favorites : [];
        root.recents = Array.isArray(d.recents) ? d.recents : [];
      } catch (e) { /* keep defaults */ }
    }
    onFileChanged: root.reloadPrefsIfSafe()
  }

  // ----------------------------------------------------- bar widget -------
  // Compact: a status dot plus an elided label (country name when connected).
  // The label caps at ~13 characters so the widget stays small; the panel is
  // pinned to the dot's position sampled when it opens (see NordPanel), so it
  // does not chase the label as the name changes.
  readonly property string barLabel: {
    if (root.blocker === "nocli") return "Setup";
    if (root.blocker === "nogroup") return "Setup";
    if (root.blocker === "nodaemon") return "VPN";
    if (root.blocker === "loggedout") return "Log in";
    if (root.busy) return "…";
    if (root.connected && root.countryName) return root.countryName;
    return "VPN";
  }
  readonly property color barDotColor: {
    if (root.blocker !== "none") return Color.urgent;
    if (root.busy) return Qt.rgba(root.hiColor.r, root.hiColor.g, root.hiColor.b, 0.55);
    if (root.connected) return root.hiColor;
    return Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.35);
  }
  readonly property string barTooltip: {
    if (root.blocker === "nocli") return "NordVPN isn't installed — click to set up";
    if (root.blocker === "nogroup") return "NordVPN: permission needed — click to set up";
    if (root.blocker === "nodaemon") return "NordVPN service isn't running — click to set up";
    if (root.blocker === "loggedout") return "NordVPN: not logged in — click to log in";
    if (root.connected)
      return root.status.server + "  •  " + root.status.ip +
             "  •  up " + Model.formatUptime(root.status.uptimeSec);
    return "NordVPN: disconnected — click to open";
  }

  TextMetrics {
    id: labelCap
    font.family: root.bar ? root.bar.fontFamily : Style.font.family
    font.pixelSize: Style.font.body
    text: "MMMMMMMMMMMMM"   // 13-char cap
  }
  readonly property real barDotSize: Math.max(7, Style.space(8))

  Item {
    id: barButton
    height: root.implicitHeight
    width: Style.space(8) + root.barDotSize + Style.space(6) + label.width + Style.space(8)

    Rectangle {
      id: statusDot
      x: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      width: root.barDotSize
      height: root.barDotSize
      radius: width / 2
      color: root.barDotColor
      Behavior on color { ColorAnimation { duration: 160 } }
    }

    Text {
      id: label
      anchors.left: statusDot.right
      anchors.leftMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
      width: Math.min(implicitWidth, labelCap.width)
      text: root.barLabel
      elide: Text.ElideRight
      color: root.connected ? root.hiColor : (root.bar ? root.bar.barForeground : Color.foreground)
      font.family: root.bar ? root.bar.fontFamily : Style.font.family
      font.pixelSize: Style.font.body
      Behavior on color { ColorAnimation { duration: 160 } }
    }

    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: function (m) {
        if (m.button === Qt.LeftButton) root.toggle();
        else if (m.button === Qt.RightButton) root.connected ? root.disconnect() : root.quickConnect();
        else if (m.button === Qt.MiddleButton) root.refreshStatus();
      }
      onWheel: function (w) { root.cycleFavorite(w.angleDelta.y > 0 ? 1 : -1); }
      onEntered: if (root.bar && root.bar.showTooltip) root.bar.showTooltip(barButton, root.barTooltip)
      onExited: if (root.bar && root.bar.hideTooltip) root.bar.hideTooltip(barButton)
    }
  }

  // --------------------------------------------------------- panel -------
  NordPanel {
    id: panel
    anchorItem: statusDot
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: Style.space(430)
    contentHeight: layout.implicitHeight + Style.space(28)
    onDismissed: root.close()

    Item {
      id: keyCatcher
      anchors.fill: parent
      focus: true
      Keys.onPressed: function (event) {
        if (search.activeFocus) return;
        if (event.key === Qt.Key_Escape) { root.close(); event.accepted = true; }
        else if (event.text === "c" || event.text === "C") { root.connected ? root.disconnect() : root.quickConnect(); event.accepted = true; }
        else if (event.text === "d" || event.text === "D") { root.disconnect(); event.accepted = true; }
        else if (event.text === "m" || event.text === "M") { root.tab = "map"; event.accepted = true; }
        else if (event.text === "l" || event.text === "L") { root.tab = "list"; event.accepted = true; }
        else if (event.text === "r" || event.text === "R") { root.refreshStatus(); event.accepted = true; }
      }

      Column {
        id: layout
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.spacing.panelGap

        // ---- header ----------------------------------------------------
        Item {
          width: parent.width
          height: Math.max(headerLabels.implicitHeight, headerAction.implicitHeight)

          Row {
            id: headerLabels
            anchors.left: parent.left
            anchors.right: headerAction.left
            anchors.rightMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(10)

            Rectangle {
              anchors.verticalCenter: parent.verticalCenter
              width: 10; height: 10; radius: 5
              color: root.blocker !== "none" ? Color.urgent
                   : root.connected ? root.hiColor
                   : Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.35)
            }

            Column {
              anchors.verticalCenter: parent.verticalCenter
              spacing: 2
              Text {
                text: {
                  if (root.blocker === "nocli") return "NordVPN not installed";
                  if (root.blocker === "nogroup") return "Permission needed";
                  if (root.blocker === "nodaemon") return "Service not running";
                  if (root.blocker === "loggedout") return "Not logged in";
                  if (root.busy) return root.busyLabel;
                  return root.connected ? root.countryName : "Disconnected";
                }
                color: Color.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.title
                font.bold: true
                elide: Text.ElideRight
              }
              Text {
                visible: text !== ""
                text: {
                  if (root.blocker === "nocli") return "finish setup below to continue";
                  if (root.blocker === "nogroup") return "finish setup below to continue";
                  if (root.blocker === "nodaemon") return "finish setup below to continue";
                  if (root.blocker === "loggedout") return "log in below to continue";
                  if (root.connected)
                    return root.status.city + "  •  " + root.status.server +
                           "  •  " + root.status.technology + " " + root.status.protocol;
                  return "Not protected";
                }
                color: Qt.darker(Color.foreground, 1.4)
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
                width: headerLabels.width - 20
              }
            }
          }

          PillButton {
            id: headerAction
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            visible: root.blocker === "none"
            enabled: !root.busy
            emphasized: !root.connected
            text: root.connected ? "Disconnect" : "Quick Connect"
            onClicked: root.connected ? root.disconnect() : root.quickConnect()
          }
        }

        // ---- setup (shown instead of everything below, one blocker at a time) --
        SetupView { visible: root.blocker !== "none"; width: parent.width }

        // ---- live stats ----------------------------------------------
        Grid {
          visible: root.connected && root.blocker === "none"
          width: parent.width
          columns: 2
          columnSpacing: Style.space(10)
          rowSpacing: Style.space(8)

          StatCell { label: "Download"; value: Model.formatRate(root.rateIn) }
          StatCell { label: "Upload"; value: Model.formatRate(root.rateOut) }
          StatCell { label: "Server IP"; value: root.status.ip || "—" }
          StatCell { label: "Latency"; value: root.latencyMs >= 0 ? Math.round(root.latencyMs) + " ms" : "—" }
          StatCell { label: "Uptime"; value: Model.formatUptime(root.status.uptimeSec) }
          StatCell { label: "Protocol"; value: (root.status.technology + " " + root.status.protocol).trim() || "—" }
          StatCell { label: "Received"; value: Model.formatBytes(root.status.transferIn) }
          StatCell { label: "Sent"; value: Model.formatBytes(root.status.transferOut) }
        }

        PanelSeparator { visible: root.blocker === "none" }

        // ---- location picker header + tabs --------------------------
        Item {
          visible: root.blocker === "none"
          width: parent.width
          height: pickerHeader.implicitHeight

          PanelSectionHeader {
            id: pickerHeader
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: {
              if (root.hoverName) return root.hoverName.toUpperCase() + "  ·  " + root.hoverMeta;
              if (root.currentCode) return "CONNECTED: " + root.countryName.toUpperCase();
              return "CHOOSE A LOCATION";
            }
          }

          Row {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(4)
            TabButton { text: "Map"; selected: root.tab === "map"; onClicked: root.tab = "map" }
            TabButton { text: "List"; selected: root.tab === "list"; onClicked: root.tab = "list" }
          }
        }

        // ---- MAP ---------------------------------------------------
        WorldMap {
          id: map
          visible: root.tab === "map" && root.blocker === "none"
          width: parent.width
          height: Style.space(240)
          geo: root.worldPaths
          currentCode: root.currentCode
          favorites: root.favorites
          accentColor: root.hiColor
          onCountryHovered: function (code, name) {
            root.hoverName = name;
            var c = root.countryData[code];
            root.hoverMeta = c ? (c.serverCount + " servers") : "";
          }
          onCountryActivated: function (code, name) { root.connectCountry(code, name); }
        }

        Text {
          visible: root.tab === "map" && root.blocker === "none"
          width: parent.width
          text: "Scroll to zoom · drag to pan · click a country to connect"
          horizontalAlignment: Text.AlignHCenter
          color: Qt.darker(Color.foreground, 1.5)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }

        // ---- LIST ------------------------------------------------
        Column {
          visible: root.tab === "list" && root.blocker === "none"
          width: parent.width
          spacing: Style.space(8)
          onVisibleChanged: if (visible) Qt.callLater(function () { search.forceActiveFocus(); })

          Rectangle {
            width: parent.width
            height: Style.spacing.controlHeight
            radius: Style.cornerRadius
            color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.05)
            border.width: 1
            border.color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, search.activeFocus ? 0.4 : 0.15)

            TextInput {
              id: search
              anchors.fill: parent
              anchors.leftMargin: Style.space(10)
              anchors.rightMargin: Style.space(10)
              verticalAlignment: TextInput.AlignVCenter
              clip: true
              color: Color.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.body
              selectionColor: Qt.rgba(root.hiColor.r, root.hiColor.g, root.hiColor.b, 0.4)
              onTextChanged: root.searchText = text
              Keys.onEscapePressed: { text = ""; keyCatcher.forceActiveFocus(); }
              Keys.onReturnPressed: {
                if (root.listRows.length > 0) root.connectCountry(root.listRows[0].code, root.listRows[0].name);
              }
            }
            Text {
              anchors.left: parent.left
              anchors.leftMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              visible: search.text === ""
              text: "Search countries…"
              color: Qt.darker(Color.foreground, 1.6)
              font.family: Style.font.family
              font.pixelSize: Style.font.body
            }
          }

          ListView {
            id: listView
            width: parent.width
            height: Style.space(210)
            clip: true
            model: root.listRows
            boundsBehavior: Flickable.StopAtBounds

            delegate: Rectangle {
              width: listView.width
              height: Style.spacing.popupRowHeight + 4
              color: rowMouse.containsMouse
                ? Qt.rgba(root.hiColor.r, root.hiColor.g, root.hiColor.b, 0.12)
                : "transparent"
              radius: Style.cornerRadius

              readonly property bool isCurrent: modelData.code === root.currentCode
              readonly property bool isFav: root.favorites.indexOf(modelData.code) >= 0

              MouseArea {
                id: rowMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.connectCountry(modelData.code, modelData.name)
              }

              Text {
                anchors.left: parent.left
                anchors.leftMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
                width: 20
                text: parent.isFav ? "★" : "☆"
                color: parent.isFav ? root.hiColor : Qt.darker(Color.foreground, 1.7)
                font.pixelSize: Style.font.body
                MouseArea {
                  anchors.fill: parent
                  anchors.margins: -4
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.toggleFavorite(modelData.code)
                }
              }

              Text {
                anchors.left: parent.left
                anchors.leftMargin: Style.space(30)
                anchors.verticalCenter: parent.verticalCenter
                text: modelData.name
                color: parent.isCurrent ? root.hiColor : Color.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                font.bold: parent.isCurrent
              }

              Text {
                anchors.right: parent.right
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                text: parent.isCurrent ? "connected" : (modelData.serverCount + " servers")
                color: Qt.darker(Color.foreground, 1.5)
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }
            }
          }
        }

      }

      // ---- toast (e.g. "Copied to clipboard") -----------------------
      Rectangle {
        id: toast
        anchors.top: parent.top
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.topMargin: Style.space(10)
        width: toastLabel.implicitWidth + Style.space(24)
        height: toastLabel.implicitHeight + Style.space(12)
        radius: Style.cornerRadius
        color: Color.background
        border.width: 1
        border.color: Qt.rgba(root.hiColor.r, root.hiColor.g, root.hiColor.b, 0.5)
        opacity: root.toastText !== "" ? 1 : 0
        visible: opacity > 0
        z: 100
        Behavior on opacity { NumberAnimation { duration: 150 } }
        Text {
          id: toastLabel
          anchors.centerIn: parent
          text: root.toastText
          color: Color.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
      }
    }
  }

  // ---------------------------------------------- small inline components --
  component PillButton: Rectangle {
    id: pill
    property string text: ""
    property bool emphasized: false
    property bool enabled: true
    signal clicked()
    implicitWidth: pillLabel.implicitWidth + Style.space(24)
    implicitHeight: Style.spacing.controlHeight
    radius: Style.cornerRadius
    opacity: enabled ? 1 : 0.4
    color: emphasized ? root.hiColor
         : Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.08)
    border.width: 1
    border.color: emphasized ? root.hiColor
         : Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.25)
    Text {
      id: pillLabel
      anchors.centerIn: parent
      text: pill.text
      color: pill.emphasized ? Color.background : Color.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.body
      font.bold: true
    }
    MouseArea {
      anchors.fill: parent
      enabled: pill.enabled
      cursorShape: Qt.PointingHandCursor
      onClicked: pill.clicked()
    }
  }

  component TabButton: Rectangle {
    id: tb
    property string text: ""
    property bool selected: false
    signal clicked()
    implicitWidth: tbLabel.implicitWidth + Style.space(16)
    implicitHeight: Style.space(22)
    radius: Style.cornerRadius
    color: selected ? Qt.rgba(root.hiColor.r, root.hiColor.g, root.hiColor.b, 0.18) : "transparent"
    border.width: 1
    border.color: selected ? root.hiColor
        : Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.15)
    Text {
      id: tbLabel
      anchors.centerIn: parent
      text: tb.text
      color: tb.selected ? root.hiColor : Qt.darker(Color.foreground, 1.3)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      font.bold: tb.selected
    }
    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: tb.clicked() }
  }

  // First-run / broken-install flow: walks a user who has never set up
  // NordVPN (or hit a permissions/daemon snag) through exactly one blocker
  // at a time, in the same card the normal connect UI lives in.
  component SetupView: Column {
    id: setup
    spacing: Style.space(12)

    readonly property string blocker: root.blocker

    Text {
      width: parent.width
      wrapMode: Text.WordWrap
      text: {
        if (setup.blocker === "nocli") return "The NordVPN CLI isn't installed. Install it, then this panel will pick it up automatically.";
        if (setup.blocker === "nogroup") return "Your user isn't in the nordvpn group yet, so the app can't talk to the VPN service.";
        if (setup.blocker === "nodaemon") return "The NordVPN background service isn't running.";
        return "Connect your Nord Account to manage the VPN from here.";
      }
      color: Qt.darker(Color.foreground, 1.2)
      font.family: Style.font.family
      font.pixelSize: Style.font.body
    }

    // ---- nocli: copyable install command -------------------------------
    Column {
      visible: setup.blocker === "nocli"
      width: parent.width
      spacing: Style.space(10)

      CopyRow {
        width: parent.width
        commandText: "omarchy pkg aur add nordvpn-bin"
      }
      Text {
        text: "(plain Arch / non-Omarchy: yay -S nordvpn-bin)"
        color: Qt.darker(Color.foreground, 1.6)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }
      PillButton { text: "Check again"; onClicked: root.refreshStatus() }
    }

    // ---- nogroup / nodaemon: one pkexec fix ----------------------------
    Column {
      visible: setup.blocker === "nogroup" || setup.blocker === "nodaemon"
      width: parent.width
      spacing: Style.space(8)

      PillButton {
        emphasized: true
        enabled: !root.setupBusy
        text: root.setupBusy ? (root.setupMessage || "Working…")
            : setup.blocker === "nogroup" ? "Add me to the nordvpn group"
            : "Start the NordVPN service"
        onClicked: {
          if (setup.blocker === "nogroup")
            root.runSetupFix([root.binPkexec, root.binUsermod, "-aG", "nordvpn", Quickshell.env("USER") || Quickshell.env("LOGNAME")],
                              "Adding you to the nordvpn group…");
          else
            root.runSetupFix([root.binPkexec, root.binSystemctl, "enable", "--now", "nordvpnd"],
                              "Starting the NordVPN service…");
        }
      }
      Text {
        width: parent.width
        wrapMode: Text.WordWrap
        text: setup.blocker === "nogroup"
            ? "Runs: sudo usermod -aG nordvpn " + (Quickshell.env("USER") || "$USER") + " — you'll need to log out and back in afterwards."
            : "Runs: sudo systemctl enable --now nordvpnd"
        color: Qt.darker(Color.foreground, 1.6)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }
    }

    // ---- loggedout: browser login ---------------------------------------
    Column {
      visible: setup.blocker === "loggedout"
      width: parent.width
      spacing: Style.space(10)

      PillButton {
        emphasized: true
        enabled: !root.loginBusy
        text: root.loginBusy ? (root.loginStatusText || "Working…") : "Log in with browser"
        onClicked: root.startLogin()
      }

      Text {
        visible: root.loginBusy && root.loginStatusText !== ""
        width: parent.width
        wrapMode: Text.WordWrap
        text: root.loginStatusText
        color: Qt.darker(Color.foreground, 1.4)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }

      // The CLI opens this itself, but surface it in case xdg-open / $BROWSER
      // isn't wired up in this session — nothing else would tell the user why
      // "waiting for the browser" never resolves.
      Column {
        visible: root.loginUrl !== ""
        width: parent.width
        spacing: Style.space(8)
        Text {
          width: parent.width
          wrapMode: Text.WrapAnywhere
          text: root.loginUrl
          color: root.hiColor
          font.family: "monospace"
          font.pixelSize: Style.font.caption
        }
        Row {
          spacing: Style.space(10)
          PillButton { text: "Open in browser"; onClicked: Quickshell.execDetached({ command: [root.binLaunchBrowser, root.loginUrl] }) }
          CopyIconButton { value: root.loginUrl; anchors.verticalCenter: parent.verticalCenter }
        }
      }

      Text {
        visible: root.loginError !== ""
        width: parent.width
        wrapMode: Text.WordWrap
        text: root.loginError
        color: Color.urgent
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }
    }
  }

  // A small square button that draws its own copy icon (two overlapping
  // outlined squares — no icon font dependency, so it always renders) and
  // flips to a checkmark for a moment after copying. Both states are themed
  // off root.hiColor / Color.foreground, so they track the active palette.
  component CopyIconButton: Rectangle {
    id: btn
    property string value: ""
    property bool copied: false
    readonly property color iconColor: (copied || mouse.containsMouse) ? root.hiColor : Qt.darker(Color.foreground, 1.3)

    width: Style.space(28)
    height: Style.space(28)
    radius: Style.cornerRadius
    color: mouse.containsMouse ? Qt.rgba(root.hiColor.r, root.hiColor.g, root.hiColor.b, 0.14) : "transparent"
    Behavior on color { ColorAnimation { duration: 120 } }

    Rectangle {
      visible: !btn.copied
      x: parent.width / 2 - 3
      y: parent.height / 2 - 7
      width: 9; height: 9
      radius: 2
      color: "transparent"
      border.width: 1.3
      border.color: btn.iconColor
    }
    Rectangle {
      visible: !btn.copied
      x: parent.width / 2 - 7
      y: parent.height / 2 - 3
      width: 9; height: 9
      radius: 2
      color: Color.background
      border.width: 1.3
      border.color: btn.iconColor
    }
    Text {
      visible: btn.copied
      anchors.centerIn: parent
      text: "✓"
      color: btn.iconColor
      font.bold: true
      font.pixelSize: Style.font.body
    }
    MouseArea {
      id: mouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: {
        root.copyText(btn.value);
        btn.copied = true;
        copiedTimer.restart();
      }
    }
    Timer { id: copiedTimer; interval: 1400; onTriggered: btn.copied = false }
  }

  // A monospace command in its own themed box, with a CopyIconButton pinned
  // to the right edge instead of a separate "Copy" button below it.
  component CopyRow: Rectangle {
    id: copyRow
    property string commandText: ""
    height: Math.max(cmdLabel.implicitHeight, icon.height) + Style.space(20)
    radius: Style.cornerRadius
    color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.06)
    border.width: 1
    border.color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.15)

    Text {
      id: cmdLabel
      anchors.left: parent.left
      anchors.leftMargin: Style.space(14)
      anchors.right: icon.left
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      text: copyRow.commandText
      color: Color.foreground
      font.family: "monospace"
      font.pixelSize: Style.font.body
      elide: Text.ElideMiddle
    }
    CopyIconButton {
      id: icon
      value: copyRow.commandText
      anchors.right: parent.right
      anchors.rightMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
    }
  }

  component StatCell: Column {
    property string label: ""
    property string value: ""
    width: (parent.width - Style.space(10)) / 2
    spacing: 1
    Text {
      text: parent.label.toUpperCase()
      color: Qt.darker(Color.foreground, 1.5)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      font.letterSpacing: 1
    }
    Text {
      text: parent.value
      color: Color.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.subtitle
      font.bold: true
      elide: Text.ElideRight
      width: parent.width
    }
  }

}
