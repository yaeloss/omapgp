// Execute the actual QML callback functions with controlled delayed completion.
const assert = require("node:assert/strict")
const fs = require("node:fs")
const vm = require("node:vm")
const source = fs.readFileSync(require("node:path").join(__dirname, "..", "Panel.qml"), "utf8")
const Model = require("../Model.js")
const FPR = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
const manifest = JSON.parse(fs.readFileSync(require("node:path").join(__dirname, "..", "manifest.json"), "utf8"))
assert.equal(manifest.name, "omaPGP")
assert.equal(manifest.barWidget.displayName, "omaPGP")
assert.equal(manifest.id, "io.github.yaeloss.omapgp")
assert.match(fs.readFileSync(require("node:path").join(__dirname, "..", "BarWidget.qml"), "utf8"), /tooltipText: "omaPGP"/)

function extract(name) {
  const start = source.indexOf("  function " + name + "(")
  assert.ok(start >= 0)
  const end = source.indexOf("\n  }", start) + 4
  assert.ok(end > start)
  return source.slice(start, end)
}

function context() {
  let pending = null
  const c = {
    Model, opened:true, _operationEpoch:0, _actionKind:"", _readRevision:0, _writeRevision:0,
    homedir:"/disposable", homedirError:"", copyNotice:"", copyClearSeconds:45,
    copyTimeoutNotice(text) { return text + " (clears in 45s)" },
    recipients:[FPR], signer:"", encryptToSelf:false, selfKey:null, selfKeys:[], selfKeyFingerprint:"",
    keysLoaded:true, keys:[{fingerprint:FPR, keyId:FPR.slice(-16), usable:true, canEncrypt:true}],
    signKeys:[], certKeys:[{fingerprint:"C".repeat(40)}], keysNotice:"", verifyTarget:null, fingerprintCheck:"empty",
    unverifiedRecipients:[], allowUnverified:false, writeOutput:"", writeError:"", writeOutputKind:"",
    writeOutputSensitive:false,
    writeInput:{text:"Draft fixture"}, readInput:{text:"-----BEGIN PGP MESSAGE-----"},
    writeOutputArea:{text:"", clear(){this.text=""}}, readOutput:{text:"", clear(){this.text=""}},
    clipboard:{calls:[], copy(...args){this.calls.push(args);return true}},
    gpg:{running:false, start(args, input, callback){this.running=true;pending=callback;c.sentArgs=args;return true},
         cancel(){this.running=false;pending=null}},
    complete(result){const cb=pending;this.gpg.running=false;pending=null;cb(result)},
    pending(){return pending}
  }
  Object.defineProperty(c, "busy", {get:()=>c.gpg.running})
  c.root = c
  const context = vm.createContext(c)
  for (const name of ["clearReadResult", "clearWriteResult", "cancelAction", "invalidateRead", "invalidateWrite", "runGpg", "encrypt", "signOnly", "decrypt", "copyPublicKey", "copyWriteOutput", "copyEditorText", "verifyKey"]) {
    vm.runInContext(extract(name), context)
  }
  return c
}

const encryption = {exitCode:0, errorCode:"", stdout:"-----BEGIN PGP MESSAGE-----\nfixture",
  status:Model.parseStatus(["[GNUPG:] END_ENCRYPTION"])}

// A queued callback from an invalidated request cannot resurrect an old result.
for (const change of [c=>c.signer=FPR, c=>c.recipients=[], c=>c.encryptToSelf=true, c=>c.writeInput.text="Changed draft"]) {
  const c = context()
  c.encrypt()
  const oldCallback = c.pending()
  change(c)
  c.invalidateWrite()
  oldCallback(encryption)
  assert.equal(c.writeOutput, "")
  assert.equal(c.writeOutputKind, "")
  assert.equal(c.gpg.running, false)
}

// Labels derive from the captured request, even if a change hook were missed.
const snapshot = context()
snapshot.encrypt()
assert.equal(snapshot.sentArgs.includes("--sign"), false)
snapshot.signer = FPR
snapshot.complete(encryption)
assert.equal(snapshot.writeOutputKind, "Encrypted")
snapshot.invalidateWrite()
assert.equal(snapshot.writeOutput, "")
assert.equal(snapshot.writeOutputArea.text, "")

const missingStatus = context()
missingStatus.signer = FPR
missingStatus.encrypt()
missingStatus.complete(encryption)
assert.equal(missingStatus.writeOutput, "")
assert.notEqual(missingStatus.writeError, "")

const certifiedRecipient = context()
certifiedRecipient.keys[0].locallyVerified = true
certifiedRecipient.encrypt()
assert.ok(certifiedRecipient.sentArgs.includes("--trust-model"), "a locally verified recipient can encrypt without changing ownertrust")
certifiedRecipient.cancelAction()
certifiedRecipient.unverifiedRecipients = [{ fingerprint: "B".repeat(40) }]
certifiedRecipient.encrypt()
assert.equal(certifiedRecipient.gpg.running, false, "local verification never approves another unverified recipient")

const closed = context()
closed.encrypt()
const delayed = closed.pending()
closed.opened = false
closed.cancelAction()
delayed(encryption)
assert.equal(closed.writeOutput, "")

const signedCopy = context()
signedCopy.writeOutput = "signed plaintext fixture"
signedCopy.writeOutputSensitive = true
signedCopy.copyWriteOutput()
assert.deepEqual(signedCopy.clipboard.calls, [["signed plaintext fixture", true, "Copied the signed message. (clears in 45s)"]])

// Ciphertext does not need clipboard expiry.
const ciphertextCopy = context()
ciphertextCopy.writeOutput = "-----BEGIN PGP MESSAGE-----\nfixture"
ciphertextCopy.writeOutputSensitive = false
ciphertextCopy.copyWriteOutput()
assert.deepEqual(ciphertextCopy.clipboard.calls, [["-----BEGIN PGP MESSAGE-----\nfixture", false, "Copied the encrypted message."]])

// Editor copies (drafts, pasted keys) go through the same guarded path.
const editorContext = context()
editorContext.copyEditorText("draft secret", false)
assert.deepEqual(editorContext.clipboard.calls, [["draft secret", true, "Copied the selection. (clears in 45s)", undefined]])
editorContext.clipboard.calls = []
const removeSelection = () => true
editorContext.copyEditorText("draft secret", true, removeSelection)
assert.deepEqual(editorContext.clipboard.calls, [["draft secret", true, "Moved the selection to the clipboard. (clears in 45s)", removeSelection]])
editorContext.copyEditorText("", false)
assert.equal(editorContext.clipboard.calls.length, 1, "empty selections are not copied")

// A copy request while wl-copy is still running is reported, not dropped.
const busyCopy = context()
busyCopy.copyNotice = ""
busyCopy.clipboard.copy = function() { return false }
busyCopy.copyEditorText("draft secret", false)
assert.match(busyCopy.copyNotice, /still finishing/)

const publicCopy = context()
publicCopy.copyPublicKey(publicCopy.keys[0])
publicCopy.complete({exitCode:0, stdout:"-----BEGIN PGP PUBLIC KEY BLOCK-----\nfixture"})
assert.equal(publicCopy.keysNotice, "")
assert.equal(publicCopy.copyNotice, "")
assert.equal(publicCopy.clipboard.calls.length, 1)

const BOB = "B".repeat(40)
const secondKey = {fingerprint:BOB, canDecrypt:true}
const selfCopy = context()
selfCopy.encryptToSelf = true
selfCopy.selfKeys = [{fingerprint:FPR, canDecrypt:true}, secondKey]
selfCopy.encrypt()
assert.match(selfCopy.writeError, /Choose a personal key/)
assert.equal(selfCopy.gpg.running, false)
selfCopy.selfKeyFingerprint = BOB
selfCopy.selfKey = secondKey
selfCopy.encrypt()
assert.deepEqual(Array.from(selfCopy.sentArgs.slice(-4)), ["--recipient", FPR, "--recipient", BOB])
assert.ok(selfCopy.sentArgs.includes("--trust-model"), "an untrusted personal copy can use the request-only override")
selfCopy.cancelAction()
selfCopy.unverifiedRecipients = [selfCopy.keys[0]]
selfCopy.encrypt()
assert.match(selfCopy.writeError, /Confirm the unverified recipients/)
assert.equal(selfCopy.gpg.running, false, "the same override cannot implicitly approve an unverified contact")
selfCopy.unverifiedRecipients = []
selfCopy.selfKeys = []
selfCopy.selfKey = null
selfCopy.encrypt()
assert.match(selfCopy.writeError, /unavailable/)
assert.equal(selfCopy.gpg.running, false)
selfCopy.encryptToSelf = false
selfCopy.encrypt()
assert.deepEqual(Array.from(selfCopy.sentArgs.slice(-2)), ["--recipient", FPR])
assert.ok(!selfCopy.sentArgs.includes("--trust-model"))

const toMyself = context()
toMyself.keys[0].canDecrypt = true
toMyself.encrypt()
assert.ok(toMyself.sentArgs.includes("--trust-model"), "a directly selected personal key can receive its own copy")

const uid = "Alice  Test <alice@example.invalid>"
const key = {fingerprint:FPR, uid, displayUid:Model.displayIdentity(uid), usable:true}
const mismatched = context()
mismatched.fingerprintCheck = "mismatch"
mismatched.verifyKey(key)
assert.equal(mismatched.gpg.running, false)
const noCertifyingKey = context()
noCertifyingKey.certKeys = []
noCertifyingKey.verifyKey(key)
assert.equal(noCertifyingKey.gpg.running, false)
for (const [loaded, validity, expected] of [[false, "f", /Could not confirm/], [true, "-", /Could not confirm/], [true, "f", /marked as verified/]]) {
  const verification = context()
  let finishRefresh
  verification.refreshKeys = callback => { finishRefresh = callback }
  verification.verifyKey(key)
  assert.equal(verification.sentArgs.at(-1), "=" + uid)
  assert.ok(verification.sentArgs.includes(verification.certKeys[0].fingerprint))
  verification.complete({exitCode:0})
  assert.equal(verification.keysNotice, "")
  verification.keys = [{...key, uids:[{text:key.displayUid, validity:"f"}, {text:uid, validity}]}]
  finishRefresh(loaded)
  assert.match(verification.keysNotice, expected)
}

// A bad gnupgHome fails closed before gpg can start.
const badHome = context()
badHome.homedirError = "relative"
badHome.encrypt()
assert.equal(badHome.gpg.running, false)
assert.match(badHome.writeError, /absolute path/)

for (const name of ["Recipients", "Signer", "EncryptToSelf", "SelfKeyFingerprint", "AllowUnverified", "Keys"]) {
  assert.match(source, new RegExp("on" + name + "Changed: invalidateWrite\\(\\)"))
}
console.log("panel request/copy regression tests passed")
