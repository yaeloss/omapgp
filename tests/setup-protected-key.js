const fs = require("node:fs")
const path = require("node:path")
const assert = require("node:assert/strict")
const {spawnSync} = require("node:child_process")
const model = require("../Model.js")

function setup(home) {
  const pinentry = path.join(home, "test-pinentry.py")
  fs.copyFileSync(path.join(__dirname, "fixtures", "pinentry.py"), pinentry)
  fs.chmodSync(pinentry, 0o700)
  fs.writeFileSync(path.join(home, "gpg-agent.conf"), `pinentry-program ${pinentry}\n`, {mode:0o600})
  function run(args) {
    const r = spawnSync("gpg", model.gpgArgs(home, args).slice(1), {encoding:"utf8", timeout:10000})
    assert.equal(r.status, 0, r.stderr)
    return r.stdout
  }
  const pass = ["--pinentry-mode", "loopback", "--passphrase", "disposable-test-passphrase"]
  run(pass.concat(["--quick-gen-key", "Protected Fixture <protected@example.invalid>", "ed25519", "sign", "0"]))
  const fpr = model.parseKeys(run(["--with-colons", "--list-keys"]), "")[0].fingerprint
  run(pass.concat(["--quick-add-key", fpr, "cv25519", "encr", "0"]))
  spawnSync("gpgconf", ["--homedir", home, "--kill", "all"], {timeout:5000})
  return fpr
}
module.exports = setup
if (require.main === module) setup(process.argv[2])
