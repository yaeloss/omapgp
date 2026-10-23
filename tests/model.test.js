const assert = require("node:assert/strict")
const model = require("../Model.js")

const ALICE = "7EE2D9F067002395724E24F1AB5368D1CED2B790"
const BOB = "0AA83F84581E9E09DA3A16C649B2F813C526592F"

const pub = [
  "tru:o:1:1792688722:1:3:1:5",
  "pub:u:255:22:AB5368D1CED2B790:1792688722:::u:::scESC:::::ed25519:::0:",
  `fpr:::::::::${ALICE}:`,
  "uid:u::::1792688722::EF79::Alice Test <alice@example.invalid>::::::::::0:",
  "sub:u:255:18:DCBD2778A6715DCC:1792688722::::::e:::::cv25519::",
  "fpr:::::::::62947799E41A109541888E5BDCBD2778A6715DCC:",
  "pub:-:255:22:49B2F813C526592F:1792688722:::-:::scESC:::::ed25519:::0:",
  `fpr:::::::::${BOB}:`,
  "uid:-::::1792688722::60D5::Bob \\x3a Test (work) <bob@example.invalid>::::::::::0:",
  "sub:-:255:18:072E6D017DF6C285:1792688722::::::e:::::cv25519::",
  "fpr:::::::::F6A15B804834F6B5A7762112072E6D017DF6C285:",
  "pub:r:255:22:1111111111111111:1792688722:::-:::sc:::::ed25519:::0:",
  "fpr:::::::::1111111111111111111111111111111111111111:",
  "uid:r::::1792688722::60D5::Revoked <r@example.invalid>::::::::::0:"
].join("\n")
const sec = ["sec:u:255:22:AB5368D1CED2B790:1792688722:::u:::scESC:::+::ed25519:::0:", `fpr:::::::::${ALICE}:`, "grp:::::::::2D0E:", "ssb:u:255:18:DCBD:1:::::e:::+:::", "fpr:::::::::62947799E41A109541888E5BDCBD2778A6715DCC:"].join("\n")

const keys = model.parseKeys(pub, sec)
assert.equal(keys.length, 3)
assert.equal(keys[0].fingerprint, ALICE)
assert.equal(keys[0].hasSecret, true)
assert.equal(keys[0].verified, true)
const bob = model.findKey(keys, BOB)
assert.equal(bob.name, "Bob : Test")
assert.equal(bob.email, "bob@example.invalid")
assert.equal(bob.hasSecret, false)
assert.equal(bob.verified, false)
assert.equal(bob.canEncrypt, true)
const revoked = model.findKey(keys, "1111111111111111111111111111111111111111")
assert.equal(revoked.usable, false)
assert.equal(revoked.name, "(no name)")
assert.deepEqual(model.encryptionKeys(keys).map(k => k.fingerprint), [ALICE, BOB])
assert.deepEqual(model.signingKeys(keys).map(k => k.fingerprint), [ALICE])
assert.equal(model.findKey(keys, "49B2F813C526592F"), bob)
assert.equal(model.findKey(keys, ""), null)
assert.equal(model.formatFingerprint(ALICE), "7EE2 D9F0 6700 2395 724E  24F1 AB53 68D1 CED2 B790")

// argv safety: only fingerprints reach gpg, message text never does.
assert.equal(model.isFingerprint(ALICE), true)
assert.equal(model.isFingerprint("--output=/tmp/x"), false)
assert.equal(model.isFingerprint("alice@example.invalid"), false)
assert.equal(model.encryptArgs("", { recipients: ["--evil"] }), null)
assert.equal(model.encryptArgs("", { recipients: [BOB], signer: "--evil" }), null)
assert.equal(model.clearsignArgs("", "x"), null)
assert.equal(model.exportArgs("", "x"), null)
assert.equal(model.encryptArgs("/tmp/h", { recipients: [BOB, "junk"], signer: ALICE, allowUnverified: true }), null)
const enc = model.encryptArgs("/tmp/h", { recipients: [BOB], signer: ALICE, allowUnverified: true })
assert.deepEqual(enc.slice(0, 1), ["gpg"])
for (const flag of ["--batch", "--disable-dirmngr", "--no-auto-key-retrieve", "--no-auto-key-import"]) assert.ok(enc.includes(flag), flag)
assert.deepEqual(enc.slice(enc.indexOf("--homedir"), enc.indexOf("--homedir") + 2), ["--homedir", "/tmp/h"])
assert.ok(enc.includes("--trust-model"))
assert.deepEqual(enc.filter((a, i) => enc[i - 1] === "--recipient"), [BOB])
assert.ok(!model.encryptArgs("", { recipients: [BOB] }).includes("--trust-model"))
assert.ok(!model.decryptArgs("").includes("--homedir"))
assert.equal(model.expandHome("~/x", "/home/u"), "/home/u/x")
assert.equal(model.expandHome("  ", "/home/u"), "")

assert.equal(model.messageKind("x\n-----BEGIN PGP MESSAGE-----\n"), "message")
assert.equal(model.messageKind("-----BEGIN PGP SIGNED MESSAGE-----"), "signed")
assert.equal(model.messageKind("-----BEGIN PGP PUBLIC KEY BLOCK-----"), "public-key")
assert.equal(model.messageKind(" \n"), "empty")
assert.equal(model.inputTooLarge("a".repeat(model.MAX_INPUT_CHARS + 1)), true)

const st = l => model.parseStatus(l.map(s => "[GNUPG:] " + s).concat(["gpg: human text"]))
assert.equal(model.parseStatusLine("gpg: nope"), null)

// Encrypted + signed by a key we don't have.
let s = model.decryptSummary(st(["ENC_TO 072E6D017DF6C285 18 0", "BEGIN_DECRYPTION", "DECRYPTION_INFO 2 9 0", "PLAINTEXT 62 0 ", "NEWSIG",
  `ERRSIG AB5368D1CED2B790 22 10 00 1792688723 9 ${ALICE}`, "NO_PUBKEY AB5368D1CED2B790", "DECRYPTION_OKAY", "GOODMDC", "END_DECRYPTION"]), 2)
assert.equal(s.decrypted, true)
assert.equal(s.error, "")
assert.equal(s.signatures[0].state, "missing-key")
assert.equal(model.signatureTone(s.signatures[0]), "warn")
assert.match(model.signatureText(s.signatures[0], []), /not imported/)

// Good signature from a verified key.
s = model.decryptSummary(st(["NEWSIG", "GOODSIG AB5368D1CED2B790 Alice Test <alice@example.invalid>",
  `VALIDSIG ${ALICE} 2026-10-22 1792688723 0 4 0 22 10 01 ${ALICE}`, "TRUST_ULTIMATE 0 pgp"]), 0)
assert.equal(s.signatures[0].fingerprint, ALICE)
assert.equal(model.signatureTone(s.signatures[0], keys), "good")
assert.equal(model.signatureText(s.signatures[0], keys), "Good signature from Alice Test <alice@example.invalid> (verified identity)\nFingerprint: " + model.formatFingerprint(ALICE))

s = model.decryptSummary(st(["NEWSIG", "BADSIG AB5368D1CED2B790 Alice Test <alice@example.invalid>"]), 1)
assert.equal(model.signatureTone(s.signatures[0]), "bad")

// No secret key.
s = model.decryptSummary(st(["ENC_TO 072E6D017DF6C285 18 0", "NO_SECKEY 072E6D017DF6C285", "BEGIN_DECRYPTION", "DECRYPTION_FAILED", "END_DECRYPTION"]), 2)
assert.equal(s.noSecretKey, true)
assert.match(s.error, /secret keys/)

// Missing integrity protection is rejected even if gpg reported success.
s = model.decryptSummary(st(["ENC_TO 072E6D017DF6C285 18 0", "BEGIN_DECRYPTION", "DECRYPTION_INFO 0 9 0", "DECRYPTION_OKAY"]), 0)
assert.equal(s.decrypted, false)
assert.match(s.error, /Integrity/)

s = model.decryptSummary(st(["NODATA 1"]), 2)
assert.match(s.error, /No PGP data/)

let f = model.encryptFailure(st([`INV_RECP 10 ${BOB}`, "FAILURE encrypt 53"]))
assert.deepEqual(f.untrusted, [BOB])
f = model.encryptFailure(st([`INV_RECP 1 ${BOB}`]))
assert.match(f.message, /unusable/)

let imp = model.importSummary(st([`IMPORT_OK 1 ${BOB}`, "IMPORT_RES 1 0 1 0 0 0 0 0 0 0 0 0 0 0 0"]))
assert.deepEqual(imp, { ok: true, fingerprints: [BOB], message: "1 key imported" })
imp = model.importSummary(st(["IMPORT_RES 1 0 0 0 1 0 0 0 0 0 0 0 0 0 0"]))
assert.equal(imp.message, "already in your keyring")
imp = model.importSummary(st([]))
assert.equal(imp.ok, false)

// F1: byte limits, not UTF-16 character counts; bound the gpg output as well.
assert.equal(model.utf8Length("Héllo 😀"), Buffer.byteLength("Héllo 😀"))
assert.equal(model.inputTooLarge("é".repeat(model.MAX_INPUT_BYTES / 2)), false)
assert.equal(model.inputTooLarge("é".repeat(model.MAX_INPUT_BYTES / 2 + 1)), true)
assert.ok(model.BASE_ARGS.includes("--max-output"))
assert.equal(Number(model.BASE_ARGS[model.BASE_ARGS.indexOf("--max-output") + 1]), model.MAX_OUTPUT_BYTES)

// F2: a key's best UID must never confer trust on a different displayed UID.
const mixedPub = pub.replace("Alice Test <alice@example.invalid>", "Uncertified Alice <alice@example.invalid>")
  .replace("uid:u::::1792688722::EF79::Uncertified", "uid:-::::1792688722::EF79::Uncertified")
  .replace("sub:u:255", "uid:f::::1792688722::EF79::Certified Bob <certified@example.invalid>::::::::::0:\nsub:u:255")
const mixedKeys = model.parseKeys(mixedPub, sec)
const mixedKey = model.findKey(mixedKeys, ALICE)
assert.equal(mixedKey.validity, "u")
assert.equal(mixedKey.uidValidity, "-")
assert.equal(mixedKey.verified, false)
const trustedStatus = st(["NEWSIG", "GOODSIG AB5368D1CED2B790 Uncertified Alice <alice@example.invalid>",
  `VALIDSIG ${ALICE} 2026-10-22 1792688723 0 4 0 22 10 01 ${ALICE}`, "TRUST_FULLY 0 pgp"])
const mixedSig = model.decryptSummary(trustedStatus, 0).signatures[0]
assert.equal(model.signatureTone(mixedSig, mixedKeys), "warn")
assert.match(model.signatureText(mixedSig, mixedKeys), /identity not verified/)
assert.match(model.signatureText(mixedSig, mixedKeys), /Fingerprint:/)
assert.equal(model.signatureTone({...mixedSig, uid:"Certified Bob <certified@example.invalid>"}, mixedKeys), "good")
assert.equal(model.signatureTone({...mixedSig, valid:false}, mixedKeys), "warn")
const escapedKeys = [{...mixedKey, uids:[{text:"Known:", validity:"f"}]}]
assert.equal(model.signatureTone({...mixedSig, uid:"Known%5Cx3a"}, escapedKeys), "warn")
assert.equal(model.signatureTone({...mixedSig, uid:"Known%3A"}, escapedKeys), "good")
assert.equal(model.signatureTone({...mixedSig, uid:"bad%escape"}, escapedKeys), "warn")
assert.equal(model.decryptSummary(st(["NEWSIG", "GOODSIG AB5368D1CED2B790 Alice", "TRUST_FULLY 0 pgp"]), 0).signatures[0].state, "error")
assert.equal(model.lsignArgs("", ALICE, BOB), null)
assert.deepEqual(model.lsignArgs("", ALICE, BOB, "Alice").slice(-3), ["--", ALICE, "=Alice"])

// F3: ignore gpg.conf, neutralize extra recipients/groups, and force stdout.
assert.equal(model.BASE_ARGS[0], "--no-options")
for (const f of ["--no-encrypt-to", "--no-groups"]) assert.ok(model.BASE_ARGS.includes(f))
assert.equal(model.BASE_ARGS[model.BASE_ARGS.indexOf("--output") + 1], "-")

// F6: armor/exit status alone must not claim signing/encryption success.
const fakeWrite = {exitCode:0, stdout:"-----BEGIN PGP MESSAGE-----\n", status:[], errorCode:""}
assert.equal(model.writeSucceeded(fakeWrite, false, true), false)
fakeWrite.status = st(["END_ENCRYPTION"])
assert.equal(model.writeSucceeded(fakeWrite, false, true), true)
assert.equal(model.writeSucceeded(fakeWrite, true, true), false)
fakeWrite.status = st(["END_ENCRYPTION", "SIG_CREATED D 22 10 00 1 " + ALICE])
assert.equal(model.writeSucceeded(fakeWrite, true, true), true)
assert.equal(model.writeSucceeded({...fakeWrite, errorCode:"output-limit"}, true, true), false)

console.log("model tests passed")
