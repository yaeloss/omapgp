// Runs the real gpg with Model.js's argument builders against throwaway
// keyrings. Never touches ~/.gnupg. Requires gpg on PATH.
const assert = require("node:assert/strict")
const { spawnSync } = require("node:child_process")
const fs = require("node:fs")
const os = require("node:os")
const path = require("node:path")
const model = require("../Model.js")

function workerRun(args, input) {
  const p = spawnSync("python3", ["-I", "-B", path.join(__dirname, "..", "gpg-worker.py"), ...args],
    {input:input || "", encoding:"utf8", timeout:15000, maxBuffer:3*1024*1024})
  assert.equal(p.status, 0, p.stderr || String(p.error))
  const r = JSON.parse(p.stdout)
  r.status = model.parseStatus(r.statusLines)
  return r
}

function home() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "omapgp-test-"))
  fs.chmodSync(dir, 0o700)
  return dir
}

function run(args, input) {
  const r = spawnSync(args[0], args.slice(1), { input: input === undefined ? "" : input, encoding: "utf8" })
  return { exitCode: r.status, stdout: r.stdout, status: model.parseStatus(r.stderr.split("\n")) }
}

function genKey(dir, uid) {
  const r = run(model.gpgArgs(dir, ["--pinentry-mode", "loopback", "--passphrase", "", "--quick-gen-key", uid, "default", "default", "never"]))
  assert.equal(r.exitCode, 0, "key generation failed")
}

function keys(dir) {
  return model.parseKeys(run(model.listKeysArgs(dir, false)).stdout, run(model.listKeysArgs(dir, true)).stdout)
}

const alice = home()
const bob = home()
const dirs = [alice, bob]
try {
  genKey(alice, "Alice Test <alice@example.invalid>")
  genKey(bob, "Bob Test <bob@example.invalid>")
  const aliceKey = keys(alice)[0]
  const bobKey = keys(bob)[0]
  assert.equal(aliceKey.hasSecret, true)

  // Exchange public keys through the same import path the panel uses.
  const bobPub = run(model.exportArgs(bob, bobKey.fingerprint))
  assert.match(bobPub.stdout, /BEGIN PGP PUBLIC KEY BLOCK/)
  let imp = model.importSummary(run(model.importArgs(alice), bobPub.stdout).status)
  assert.equal(imp.ok, true)
  assert.deepEqual(imp.fingerprints, [bobKey.fingerprint])
  imp = model.importSummary(run(model.importArgs(bob), run(model.exportArgs(alice, aliceKey.fingerprint)).stdout).status)
  assert.equal(imp.ok, true)

  const bobInAlice = model.findKey(keys(alice), bobKey.fingerprint)
  assert.equal(bobInAlice.verified, false)

  const secretText = "Meet at the usual place — 7pm. ünïcödé ✓\n"

  // Unverified recipients are refused unless explicitly allowed.
  let r = run(model.encryptArgs(alice, { recipients: [bobKey.fingerprint], signer: aliceKey.fingerprint }), secretText)
  assert.notEqual(r.exitCode, 0)
  assert.deepEqual(model.encryptFailure(r.status).untrusted, [bobKey.fingerprint])

  r = run(model.encryptArgs(alice, { recipients: [bobKey.fingerprint, aliceKey.fingerprint], signer: aliceKey.fingerprint, allowUnverified: true }), secretText)
  assert.equal(r.exitCode, 0)
  assert.match(r.stdout, /BEGIN PGP MESSAGE/)
  assert.ok(!r.stdout.includes("Meet at"))
  const armored = r.stdout

  // Bob decrypts and sees a good-but-unverified signature.
  r = run(model.decryptArgs(bob), armored)
  let s = model.decryptSummary(r.status, r.exitCode)
  assert.equal(s.decrypted, true)
  assert.equal(r.stdout, secretText)
  assert.equal(s.signatures.length, 1)
  assert.equal(s.signatures[0].state, "good")
  assert.equal(s.signatures[0].fingerprint, aliceKey.fingerprint)
  assert.equal(model.signatureTone(s.signatures[0], keys(bob)), "warn")

  // Alice can read her own copy (encrypt-to-self).
  r = run(model.decryptArgs(alice), armored)
  assert.equal(r.stdout, secretText)

  // Bob verifies Alice's key locally, after which the signature is trusted.
  r = run(model.lsignArgs(bob, aliceKey.fingerprint, bobKey.fingerprint, aliceKey.uid))
  assert.equal(r.exitCode, 0)
  assert.equal(model.findKey(keys(bob), aliceKey.fingerprint).verified, true)
  r = run(model.decryptArgs(bob), armored)
  s = model.decryptSummary(r.status, r.exitCode)
  assert.equal(model.signatureTone(s.signatures[0], keys(bob)), "good")

  // Clearsigned text verifies; a tampered copy is flagged as bad.
  r = run(model.clearsignArgs(alice, aliceKey.fingerprint), "Signed statement\n")
  assert.equal(r.exitCode, 0)
  const signed = r.stdout
  r = run(model.decryptArgs(bob), signed)
  s = model.decryptSummary(r.status, r.exitCode)
  assert.equal(s.encrypted, false)
  assert.equal(s.signatures[0].state, "good")
  r = run(model.decryptArgs(bob), signed.replace("Signed statement", "Signed statemenT"))
  s = model.decryptSummary(r.status, r.exitCode)
  assert.equal(s.signatures[0].state, "bad")

  // A third party without the secret key can't decrypt.
  const eve = home(); dirs.push(eve)
  r = run(model.decryptArgs(eve), armored)
  s = model.decryptSummary(r.status, r.exitCode)
  assert.equal(s.decrypted, false)
  assert.equal(s.noSecretKey, true)
  assert.equal(r.stdout, "")

  // Garbage is reported, not crashed on.
  r = run(model.decryptArgs(bob), "-----BEGIN PGP MESSAGE-----\n\nnot really\n-----END PGP MESSAGE-----\n")
  s = model.decryptSummary(r.status, r.exitCode)
  assert.ok(s.error !== "")

  // F1: small compressed ciphertext cannot fill the shared shell with plaintext.
  r = run(model.encryptArgs(alice, {recipients:[bobKey.fingerprint], allowUnverified:true}), "x".repeat(4*1024*1024))
  assert.equal(r.exitCode, 0)
  assert.ok(!model.inputTooLarge(r.stdout))
  const oversized = workerRun(model.decryptArgs(bob), r.stdout)
  assert.equal(oversized.errorCode, "output-limit")
  assert.equal(oversized.stdout, "")

  // F2: importing a new primary UID does not inherit a different UID's certificate.
  for (const uid of ["Uncertified Person <uncertified@example.invalid>", "Other Person <other@example.invalid>"]) {
    r = run(model.gpgArgs(alice, ["--pinentry-mode", "loopback", "--passphrase", "", "--quick-add-uid", aliceKey.fingerprint, uid]))
    assert.equal(r.exitCode, 0)
  }
  r = run(model.gpgArgs(alice, ["--quick-set-primary-uid", aliceKey.fingerprint, "Uncertified Person <uncertified@example.invalid>"]))
  assert.equal(r.exitCode, 0)
  r = run(model.importArgs(bob), run(model.exportArgs(alice, aliceKey.fingerprint)).stdout)
  assert.equal(r.exitCode, 0)
  let changed = model.findKey(keys(bob), aliceKey.fingerprint)
  assert.equal(changed.validity, "f")
  assert.equal(changed.uidValidity, "-")
  assert.equal(changed.verified, false)
  r = run(model.decryptArgs(bob), run(model.clearsignArgs(alice, aliceKey.fingerprint), "New UID test\n").stdout)
  s = model.decryptSummary(r.status, r.exitCode)
  assert.equal(s.signatures[0].state, "good")
  assert.equal(model.signatureTone(s.signatures[0], keys(bob)), "warn")
  assert.match(model.signatureText(s.signatures[0], keys(bob)), /identity not verified/)
  r = run(model.lsignArgs(bob, aliceKey.fingerprint, bobKey.fingerprint, changed.uid))
  assert.equal(r.exitCode, 0)
  changed = model.findKey(keys(bob), aliceKey.fingerprint)
  assert.equal(changed.verified, true)
  assert.equal(changed.uids.find(u => u.text.startsWith("Other Person")).validity, "-")

  // F3: even a conflicting options file cannot add recipients or redirect output.
  const unexpectedFile = path.join(alice, "must-not-exist.txt")
  fs.writeFileSync(path.join(alice, "gpg.conf"), `encrypt-to ${aliceKey.fingerprint}\nhidden-encrypt-to ${aliceKey.fingerprint}\ngroup ${bobKey.fingerprint}=${aliceKey.fingerprint}\noutput ${unexpectedFile}\n`)
  const isolated = workerRun(model.encryptArgs(alice, {recipients:[bobKey.fingerprint], allowUnverified:true}), "Controlled recipient fixture\n")
  assert.equal(isolated.exitCode, 0)
  assert.equal(isolated.errorCode, "")
  assert.equal(fs.existsSync(unexpectedFile), false)
  assert.notEqual(run(model.decryptArgs(alice), isolated.stdout).exitCode, 0)
  const unexpectedDecryptFile = path.join(bob, "must-not-exist.txt")
  fs.writeFileSync(path.join(bob, "gpg.conf"), `output ${unexpectedDecryptFile}\n`)
  const isolatedDecryption = workerRun(model.decryptArgs(bob), isolated.stdout)
  assert.equal(isolatedDecryption.exitCode, 0)
  assert.equal(isolatedDecryption.stdout, "Controlled recipient fixture\n")
  assert.equal(fs.existsSync(unexpectedDecryptFile), false)

  console.log("gpg integration tests passed")
} finally {
  for (const d of dirs) {
    spawnSync("gpgconf", ["--homedir", d, "--kill", "all"])
    fs.rmSync(d, { recursive: true, force: true })
  }
}
