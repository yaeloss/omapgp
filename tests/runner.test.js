// Test shell-runner failure handling without launching Quickshell or a desktop.
const assert = require("node:assert/strict")
const fs = require("node:fs")
const os = require("node:os")
const path = require("node:path")
const {spawnSync} = require("node:child_process")
const bin = fs.mkdtempSync(path.join(os.tmpdir(), "omapgp-runner-"))
try {
  const fake = path.join(bin, "quickshell")
  fs.copyFileSync(path.join(__dirname, "fixtures", "failing-quickshell.sh"), fake)
  fs.chmodSync(fake, 0o700)
  for (const script of ["run-qml.sh", "run-ui.sh"]) {
    const r = spawnSync("bash", [path.join(__dirname, script)], {
      env:{...process.env, PATH:bin + path.delimiter + process.env.PATH},
      encoding:"utf8", timeout:20000
    })
    assert.equal(r.status, 7, script + " must preserve Quickshell's failed exit: " + r.stdout + r.stderr)
  }
  console.log("QML runner abnormal-exit regression tests passed")
} finally {
  fs.rmSync(bin, {recursive:true, force:true})
}
