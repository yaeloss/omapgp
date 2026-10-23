import QtQuick
import Quickshell.Io
import "Model.js" as Model

// A disposable process/collector per request. Only bounded worker output ever
// reaches the shared shell; cancel/completion dispose the collector entirely.
Item {
  id: root
  property var _active: null
  property var _callback: null
  readonly property bool running: _active !== null
  readonly property string workerPath: decodeURIComponent(Qt.resolvedUrl("gpg-worker.py").toString().replace(/^file:\/\//, ""))

  signal pinentryLaunched()

  function start(args, inputText, callback) {
    if (running || !args) return false
    var input = inputText === undefined || inputText === null ? "" : String(inputText)
    _callback = callback || null
    _active = runComponent.createObject(root, {
      command: ["python3", "-I", "-B", workerPath].concat(args), payload: input
    })
    _active.running = true
    deadline.restart()
    startupDeadline.restart()
    return true
  }

  function cancel() {
    deadline.stop()
    startupDeadline.stop()
    var run = _active
    _active = null
    _callback = null
    if (!run) return
    run.payload = ""
    run.running = false
    run.destroy()
  }

  function _finish(run, failure) {
    if (!run || _active !== run) return
    if (!failure && (!run.exited || !run.drained)) return
    var result = { exitCode: -1, stdout: "", status: [], errorCode: failure || "worker-failed" }
    if (!failure) {
      try {
        var parsed = JSON.parse(run.output.text)
        if (typeof parsed.stdout === "string" && parsed.stdout.length <= Model.MAX_OUTPUT_BYTES &&
            Array.isArray(parsed.statusLines) && typeof parsed.exitCode === "number") {
          result = { exitCode: parsed.exitCode, stdout: parsed.stdout,
            status: Model.parseStatus(parsed.statusLines), errorCode: parsed.errorCode || "" }
        }
      } catch (e) { /* Fail closed without logging any response data. */ }
    }
    var cb = _callback
    deadline.stop()
    startupDeadline.stop()
    _callback = null
    _active = null
    run.payload = ""
    run.destroy()
    if (cb) cb(result)
  }

  Timer {
    id: deadline
    interval: 125000
    onTriggered: if (root._active) root._finish(root._active, "timeout")
  }
  Timer {
    id: startupDeadline
    interval: 3000
    onTriggered: if (root._active && !root._active.hasStarted) root._finish(root._active, "worker-failed")
  }

  Component {
    id: runComponent
    Process {
      id: run
      property string payload: ""
      property bool exited: false
      property bool drained: false
      property bool hasStarted: false
      property alias output: collector
      stdinEnabled: true
      onStarted: {
        hasStarted = true
        write(payload)
        payload = ""
        stdinEnabled = false
      }
      onExited: {
        run.exited = true
        Qt.callLater(function() { root._finish(run, "") })
      }
      stdout: StdioCollector {
        id: collector
        onStreamFinished: {
          run.drained = true
          Qt.callLater(function() { root._finish(run, "") })
        }
      }
      stderr: SplitParser {
        onRead: function(line) { if (line === "PINENTRY_LAUNCHED") root.pinentryLaunched() }
      }
    }
  }
}
