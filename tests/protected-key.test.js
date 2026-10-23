// Verify the real agent/pinentry path without a desktop or real credentials.
const assert = require("node:assert/strict")
const fs = require("node:fs")
const os = require("node:os")
const path = require("node:path")
const {spawnSync} = require("node:child_process")
const model = require("../Model.js")
const setup = require("./setup-protected-key.js")
const home = fs.mkdtempSync(path.join(os.tmpdir(), "omapgp-protected-"))
fs.chmodSync(home, 0o700)
try {
  const fpr = setup(home)
  const r = spawnSync("python3", ["-I", "-B", path.join(__dirname, "..", "gpg-worker.py"),
    ...model.clearsignArgs(home, fpr)], {input:"Protected-key test fixture\n", encoding:"utf8", timeout:15000})
  assert.equal(r.status, 0, r.stderr || String(r.error))
  const result = JSON.parse(r.stdout)
  assert.equal(result.exitCode, 0)
  assert.equal(result.errorCode, "")
  assert.ok(model.hasStatus(model.parseStatus(result.statusLines), "SIG_CREATED"))
  assert.match(result.stdout, /^-----BEGIN PGP SIGNED MESSAGE-----/)
  assert.match(r.stderr, /PINENTRY_LAUNCHED/)
  assert.ok(!(r.stdout + r.stderr).includes("disposable-test-passphrase"))
  console.log("protected-key agent/pinentry tests passed")
} finally {
  spawnSync("gpgconf", ["--homedir", home, "--kill", "all"], {timeout:5000})
  fs.rmSync(home, {recursive:true, force:true})
}
