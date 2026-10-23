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
    homedir:"/disposable", recipients:[FPR], signer:"", encryptToSelf:false, selfKey:null,
    keysLoaded:true, keys:[{fingerprint:FPR, keyId:FPR.slice(-16), usable:true, canEncrypt:true}],
    unverifiedRecipients:[], allowUnverified:false, writeOutput:"", writeError:"", writeOutputKind:"",
    writeOutputSensitive:false, writeCopyArmed:false,
    writeInput:{text:"Draft fixture"}, readInput:{text:"-----BEGIN PGP MESSAGE-----"},
    writeOutputArea:{text:"", clear(){this.text=""}}, readOutput:{text:"", clear(){this.text=""}},
    copyArmTimer:{restart(){}}, clipboard:{calls:[], copy(...args){this.calls.push(args)}},
    gpg:{running:false, start(args, input, callback){this.running=true;pending=callback;c.sentArgs=args;return true},
         cancel(){this.running=false;pending=null}},
    complete(result){const cb=pending;this.gpg.running=false;pending=null;cb(result)},
    pending(){return pending}
  }
  Object.defineProperty(c, "busy", {get:()=>c.gpg.running})
  c.root = c
  const context = vm.createContext(c)
  for (const name of ["clearReadResult", "clearWriteResult", "cancelAction", "invalidateRead", "invalidateWrite", "runGpg", "encrypt", "signOnly", "decrypt", "copyWriteOutput"]) {
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
assert.equal(signedCopy.clipboard.calls.length, 0)
signedCopy.copyWriteOutput()
assert.deepEqual(signedCopy.clipboard.calls, [["signed plaintext fixture", true]])

for (const name of ["Recipients", "Signer", "EncryptToSelf", "AllowUnverified", "Keys"]) {
  assert.match(source, new RegExp("on" + name + "Changed: invalidateWrite\\(\\)"))
}
console.log("panel request/copy regression tests passed")
