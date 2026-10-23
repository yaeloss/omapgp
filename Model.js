// Pure helpers for omapgp: gpg argument building, --with-colons key parsing,
// and --status-fd interpretation. No QML imports, so the same file loads in
// the shell and under `node` for tests.
//
// Privacy rules every builder here follows:
//   - message text only ever travels over stdin, never argv or temp files;
//   - dirmngr is disabled, so gpg cannot reach a keyserver or WKD;
//   - keys are never fetched or imported implicitly from messages.

var BASE_ARGS = [
  "--no-options",
  "--batch",
  "--no-tty",
  "--disable-dirmngr",
  "--no-auto-key-retrieve",
  "--no-auto-key-import",
  "--no-symkey-cache",
  "--no-encrypt-to",
  "--no-groups",
  "--max-output", "262144",
  "--output", "-",
  "--display-charset", "utf-8",
  "--status-fd", "2"
]

var MAX_INPUT_BYTES = 64 * 1024
var MAX_INPUT_CHARS = MAX_INPUT_BYTES
var MAX_OUTPUT_BYTES = 256 * 1024

function gpgArgs(homedir, extra) {
  var args = ["gpg"].concat(BASE_ARGS)
  if (homedir) args.push("--homedir", String(homedir))
  return args.concat(extra || [])
}

function expandHome(path, home) {
  path = String(path || "").trim()
  if (path === "~") return home
  if (path.indexOf("~/") === 0) return home + path.slice(1)
  return path
}

function listKeysArgs(homedir, secret) {
  return gpgArgs(homedir, ["--with-colons", "--fixed-list-mode",
    secret ? "--list-secret-keys" : "--list-keys"])
}

// Fingerprints are the only key identifiers we hand to gpg. A full 40/64-hex
// fingerprint can't be confused with a user ID, which keeps argv injection-free.
function isFingerprint(value) {
  return typeof value === "string" && /^([0-9A-F]{40}|[0-9A-F]{64})$/.test(value)
}

function encryptArgs(homedir, opts) {
  var recipients = opts.recipients || []
  if (recipients.length === 0 || recipients.some(function(f) { return !isFingerprint(f) })) return null
  var args = ["--armor"]
  if (opts.allowUnverified) args.push("--trust-model", "always")
  args.push("--encrypt")
  if (opts.signer) {
    if (!isFingerprint(opts.signer)) return null
    args.push("--sign", "--local-user", opts.signer)
  }
  for (var i = 0; i < recipients.length; i++) args.push("--recipient", recipients[i])
  return gpgArgs(homedir, args)
}

function clearsignArgs(homedir, signer) {
  if (!isFingerprint(signer)) return null
  return gpgArgs(homedir, ["--armor", "--local-user", signer, "--clearsign"])
}

function decryptArgs(homedir) {
  return gpgArgs(homedir, ["--decrypt"])
}

function importArgs(homedir) {
  return gpgArgs(homedir, ["--import"])
}

function exportArgs(homedir, fpr) {
  if (!isFingerprint(fpr)) return null
  return gpgArgs(homedir, ["--armor", "--export-options", "export-minimal", "--export", fpr])
}

function lsignArgs(homedir, fpr, signer, uid) {
  if (!isFingerprint(fpr) || typeof uid !== "string" || uid === "") return null
  var args = []
  if (signer) {
    if (!isFingerprint(signer)) return null
    args.push("--local-user", signer)
  }
  args.push("--quick-lsign-key", "--", fpr)
  args.push("=" + uid)
  return gpgArgs(homedir, args)
}

// --- key listing ------------------------------------------------------------

function unescapeColon(value) {
  return String(value || "").replace(/\\x([0-9a-fA-F]{2})/g, function(_, hex) {
    return String.fromCharCode(parseInt(hex, 16))
  })
}

function splitUid(uid) {
  var m = /^(.*?)\s*<([^<>]*)>\s*$/.exec(uid)
  if (m) return { name: m[1].replace(/\s*\([^()]*\)\s*$/, "").trim(), email: m[2].trim() }
  return { name: uid.trim(), email: "" }
}

// Parses `gpg --with-colons --fixed-list-mode --list-keys` output. Secret
// fingerprints come from a separate --list-secret-keys run.
function parseKeys(publicColons, secretColons) {
  var secret = {}
  var lines = String(secretColons || "").split("\n")
  var inSec = false
  for (var s = 0; s < lines.length; s++) {
    var f = lines[s].split(":")
    if (f[0] === "sec") inSec = true
    else if (f[0] === "ssb" || f[0] === "pub" || f[0] === "sub") inSec = false
    else if (f[0] === "fpr" && inSec) { secret[f[9]] = true; inSec = false }
  }

  var keys = []
  var current = null
  var expectPrimaryFpr = false
  lines = String(publicColons || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var fields = lines[i].split(":")
    var type = fields[0]
    if (type === "pub") {
      var caps = fields[11] || ""
      current = {
        fingerprint: "",
        keyId: fields[4] || "",
        validity: fields[1] || "-",
        created: Number(fields[5]) || 0,
        expires: Number(fields[6]) || 0,
        canEncrypt: caps.indexOf("E") !== -1,
        canSign: caps.indexOf("S") !== -1,
        disabled: caps.indexOf("D") !== -1,
        uids: [],
        hasSecret: false
      }
      keys.push(current)
      expectPrimaryFpr = true
    } else if (type === "fpr" && current && expectPrimaryFpr) {
      current.fingerprint = fields[9] || ""
      current.hasSecret = secret[current.fingerprint] === true
      expectPrimaryFpr = false
    } else if (type === "sub") {
      expectPrimaryFpr = false
    } else if (type === "uid" && current) {
      var validity = fields[1] || "-"
      if (validity === "r") continue
      current.uids.push({ text: unescapeColon(fields[9]), validity: validity })
    }
  }

  var result = []
  for (var k = 0; k < keys.length; k++) {
    var key = keys[k]
    if (!isFingerprint(key.fingerprint)) continue
    var primary = key.uids.length > 0 ? key.uids[0].text : ""
    var parts = splitUid(primary)
    key.uid = primary
    key.uidValidity = key.uids.length > 0 ? key.uids[0].validity : "-"
    key.name = parts.name || "(no name)"
    key.email = parts.email
    key.revoked = key.validity === "r"
    key.expired = key.validity === "e"
    key.usable = !key.revoked && !key.expired && !key.disabled
    key.verified = key.usable && (key.uidValidity === "f" || key.uidValidity === "u")
    result.push(key)
  }
  result.sort(function(a, b) {
    if (a.hasSecret !== b.hasSecret) return a.hasSecret ? -1 : 1
    return a.name.toLowerCase() < b.name.toLowerCase() ? -1 : (a.name.toLowerCase() > b.name.toLowerCase() ? 1 : 0)
  })
  return result
}

function validityLabel(validity) {
  switch (validity) {
  case "u": return "ultimately trusted"
  case "f": return "verified"
  case "m": return "marginally trusted"
  case "n": return "not trusted"
  case "e": return "expired"
  case "r": return "revoked"
  case "i": return "invalid"
  default: return "unverified"
  }
}

function formatFingerprint(fpr) {
  fpr = String(fpr || "")
  var groups = []
  for (var i = 0; i < fpr.length; i += 4) groups.push(fpr.slice(i, i + 4))
  if (groups.length === 10) return groups.slice(0, 5).join(" ") + "  " + groups.slice(5).join(" ")
  return groups.join(" ")
}

function shortFingerprint(fpr) {
  fpr = String(fpr || "")
  return formatFingerprint(fpr.slice(-16))
}

function keyLabel(key) {
  if (!key) return ""
  return displayIdentity(key.email ? key.name + " <" + key.email + ">" : key.name)
}

function displayIdentity(value) {
  return String(value || "").replace(/[\u0000-\u001f\u007f-\u009f\u202a-\u202e\u2066-\u2069]/g, function(c) {
    return "\\u" + ("0000" + c.charCodeAt(0).toString(16)).slice(-4)
  })
}

function statusUid(value) {
  try { return decodeURIComponent(String(value || "")) }
  catch (e) { return null }
}

function findKey(keys, fprOrKeyId) {
  var id = String(fprOrKeyId || "").toUpperCase()
  if (!id) return null
  for (var i = 0; i < keys.length; i++) {
    var fpr = keys[i].fingerprint
    if (fpr === id || keys[i].keyId === id || (id.length >= 16 && fpr.slice(-id.length) === id)) return keys[i]
  }
  return null
}

function encryptionKeys(keys) {
  return keys.filter(function(k) { return k.usable && k.canEncrypt })
}

function signingKeys(keys) {
  return keys.filter(function(k) { return k.usable && k.canSign && k.hasSecret })
}

// --- input classification ---------------------------------------------------

function messageKind(text) {
  text = String(text || "")
  if (text.indexOf("-----BEGIN PGP MESSAGE-----") !== -1) return "message"
  if (text.indexOf("-----BEGIN PGP SIGNED MESSAGE-----") !== -1) return "signed"
  if (text.indexOf("-----BEGIN PGP PUBLIC KEY BLOCK-----") !== -1) return "public-key"
  if (text.indexOf("-----BEGIN PGP PRIVATE KEY BLOCK-----") !== -1) return "private-key"
  if (text.indexOf("-----BEGIN PGP SIGNATURE-----") !== -1) return "detached-signature"
  return text.trim() === "" ? "empty" : "unknown"
}

function inputTooLarge(text) {
  return utf8Length(text) > MAX_INPUT_BYTES
}

function utf8Length(text) {
  text = String(text || "")
  var bytes = 0
  for (var i = 0; i < text.length; i++) {
    var c = text.charCodeAt(i)
    if (c < 128) bytes++
    else if (c < 2048) bytes += 2
    else if (c >= 0xD800 && c <= 0xDBFF && i + 1 < text.length &&
             text.charCodeAt(i + 1) >= 0xDC00 && text.charCodeAt(i + 1) <= 0xDFFF) { bytes += 4; i++ }
    else bytes += 3
  }
  return bytes
}

function workerFailure(result) {
  switch (result.errorCode) {
  case "input-limit": return "Input is too large (maximum 64 KiB of UTF-8 text)."
  case "output-limit": return "Output is too large; the operation was stopped safely."
  case "status-limit": return "GnuPG returned too much diagnostic data; the operation was stopped."
  case "timeout": return "The operation timed out. Please try again."
  case "cancelled": return "The operation was cancelled."
  case "agent-unavailable": return "GnuPG's passphrase agent could not be started. Check your GnuPG agent configuration."
  case "": case undefined: return ""
  default: return "The isolated worker could not complete the operation."
  }
}

function writeSucceeded(result, signed, encrypted) {
  if (result.exitCode !== 0 || result.errorCode) return false
  if (encrypted && !hasStatus(result.status, "END_ENCRYPTION")) return false
  if (signed && !hasStatus(result.status, "SIG_CREATED")) return false
  return result.stdout.indexOf(encrypted ? "-----BEGIN PGP MESSAGE-----" : "-----BEGIN PGP SIGNED MESSAGE-----") === 0
}

// --- status-fd parsing ------------------------------------------------------

function parseStatusLine(line) {
  var m = /^\[GNUPG:\] (\S+)(?: (.*))?$/.exec(String(line || "").replace(/\r$/, ""))
  if (!m) return null
  return { keyword: m[1], args: m[2] === undefined ? [] : m[2].split(" "), rest: m[2] || "" }
}

function parseStatus(lines) {
  var out = []
  for (var i = 0; i < lines.length; i++) {
    var parsed = parseStatusLine(lines[i])
    if (parsed) out.push(parsed)
  }
  return out
}

var TRUST_LABELS = {
  TRUST_ULTIMATE: "your key",
  TRUST_FULLY: "verified",
  TRUST_MARGINAL: "marginally trusted",
  TRUST_NEVER: "not trusted",
  TRUST_UNDEFINED: "unverified"
}

// Summarizes the status of a `gpg --decrypt` run, which also covers
// clearsigned and inline-signed messages.
function decryptSummary(status, exitCode) {
  var s = {
    encrypted: false,
    decrypted: false,
    decryptFailed: false,
    noSecretKey: false,
    integrityOk: false,
    recipients: [],
    signatures: [],
    error: ""
  }
  var sig = null
  var missingSecret = []
  for (var i = 0; i < status.length; i++) {
    var st = status[i]
    var a = st.args
    switch (st.keyword) {
    case "ENC_TO": s.encrypted = true; s.recipients.push(a[0]); break
    case "BEGIN_DECRYPTION": s.encrypted = true; break
    case "DECRYPTION_OKAY": s.decrypted = true; break
    case "DECRYPTION_FAILED": s.decryptFailed = true; break
    case "NO_SECKEY": missingSecret.push(a[0]); break
    case "GOODMDC": s.integrityOk = true; break
    case "DECRYPTION_INFO": if (a[2] && a[2] !== "0") s.integrityOk = true; break
    case "NEWSIG": sig = { state: "unknown", keyId: "", fingerprint: "", uid: "", trust: "", created: 0 }; s.signatures.push(sig); break
    case "GOODSIG":
    case "EXPSIG":
    case "EXPKEYSIG":
    case "REVKEYSIG":
    case "BADSIG":
      if (!sig) { sig = { state: "unknown", keyId: "", fingerprint: "", uid: "", trust: "", created: 0 }; s.signatures.push(sig) }
      sig.state = { GOODSIG: "good", EXPSIG: "expired-signature", EXPKEYSIG: "expired-key", REVKEYSIG: "revoked-key", BADSIG: "bad" }[st.keyword]
      sig.keyId = a[0] || ""
      sig.uid = st.rest.slice((a[0] || "").length + 1)
      break
    case "ERRSIG":
      if (!sig) { sig = { state: "unknown", keyId: "", fingerprint: "", uid: "", trust: "", created: 0 }; s.signatures.push(sig) }
      sig.state = a[5] === "9" ? "missing-key" : "error"
      sig.keyId = a[0] || ""
      sig.created = Number(a[4]) || 0
      if (isFingerprint(a[6])) sig.fingerprint = a[6]
      break
    case "VALIDSIG":
      if (sig) {
        sig.valid = true
        sig.fingerprint = isFingerprint(a[9]) ? a[9] : a[0]
        sig.created = Number(a[2]) || 0
      }
      break
    case "TRUST_ULTIMATE":
    case "TRUST_FULLY":
    case "TRUST_MARGINAL":
    case "TRUST_NEVER":
    case "TRUST_UNDEFINED":
      if (sig) sig.trust = TRUST_LABELS[st.keyword]
      break
    case "NODATA": s.error = "No PGP data found in the text."; break
    case "UNEXPECTED": s.error = "The PGP data is malformed."; break
    case "BADARMOR": s.error = "The PGP armor is damaged."; break
    }
  }
  for (var j = 0; j < s.signatures.length; j++) {
    if (s.signatures[j].state === "good" && !s.signatures[j].valid) s.signatures[j].state = "error"
  }
  if (s.encrypted && !s.decrypted) {
    s.decryptFailed = true
    if (missingSecret.length > 0 && missingSecret.length >= s.recipients.length) s.noSecretKey = true
  }
  if (s.encrypted && s.decrypted && !s.integrityOk) {
    s.decrypted = false
    s.decryptFailed = true
    s.error = "Integrity check failed; the message may have been altered."
  }
  if (!s.error && s.decryptFailed)
    s.error = s.noSecretKey ? "None of your secret keys can decrypt this message." : "Decryption failed or was cancelled."
  if (!s.error && !s.encrypted && s.signatures.length === 0 && exitCode !== 0)
    s.error = "gpg could not read this text."
  return s
}

function signatureText(sig, keys) {
  var key = findKey(keys || [], sig.fingerprint || sig.keyId)
  var who = displayIdentity(statusUid(sig.uid) || sig.uid || (key ? keyLabel(key) : "") || ("key " + shortFingerprint(sig.fingerprint || sig.keyId)))
  var fingerprint = sig.fingerprint ? "\nFingerprint: " + formatFingerprint(sig.fingerprint) : ""
  switch (sig.state) {
  case "good": return "Good signature from " + who + (signatureIdentity(sig, keys) ? " (verified identity)" : " (identity not verified)") + fingerprint
  case "bad": return "BAD signature claiming to be from " + who + ". Do not trust this message."
  case "expired-signature": return "Signature from " + who + " has expired"
  case "expired-key": return "Good signature from " + who + ", but the key has expired"
  case "revoked-key": return "Signature from " + who + ", but the key was revoked"
  case "missing-key": return "Signed by " + shortFingerprint(sig.fingerprint || sig.keyId) + ", a key you have not imported"
  default: return "The signature could not be checked"
  }
}

// "good" | "warn" | "bad" — drives the colour of the signature line.
function signatureIdentity(sig, keys) {
  if (sig.state !== "good" || !sig.valid || !isFingerprint(sig.fingerprint)) return false
  var key = findKey(keys || [], sig.fingerprint)
  if (!key || !key.usable) return false
  // GOODSIG uses percent encoding, unlike the C escapes in --with-colons.
  // Decoding both formats would let a literal "\\x3a" impersonate a colon.
  var uid = statusUid(sig.uid)
  if (uid === null) return false
  for (var i = 0; i < key.uids.length; i++) {
    if (key.uids[i].text === uid && (key.uids[i].validity === "f" || key.uids[i].validity === "u")) return true
  }
  return false
}

function signatureTone(sig, keys) {
  if (sig.state === "bad" || sig.state === "revoked-key") return "bad"
  if (signatureIdentity(sig, keys)) return "good"
  return "warn"
}

function encryptFailure(status) {
  var invalid = []
  var noSigner = false
  for (var i = 0; i < status.length; i++) {
    var st = status[i]
    if (st.keyword === "INV_RECP") invalid.push({ reason: st.args[0], who: st.args[1] || "" })
    if (st.keyword === "INV_SGNR" || st.keyword === "NO_SGNR") noSigner = true
  }
  if (invalid.length > 0) {
    var untrusted = invalid.filter(function(r) { return r.reason === "10" })
    if (untrusted.length === invalid.length)
      return { untrusted: untrusted.map(function(r) { return r.who }), message: "Some recipients are not verified." }
    return { untrusted: [], message: "A recipient key is unusable (expired, revoked, or cannot encrypt)." }
  }
  if (noSigner) return { untrusted: [], message: "The signing key is unusable." }
  return { untrusted: [], message: "gpg could not complete the operation or it was cancelled." }
}

function importSummary(status) {
  var res = null
  var fingerprints = []
  for (var i = 0; i < status.length; i++) {
    var st = status[i]
    if (st.keyword === "IMPORT_OK" && isFingerprint(st.args[1]) && fingerprints.indexOf(st.args[1]) === -1)
      fingerprints.push(st.args[1])
    if (st.keyword === "IMPORT_RES") {
      var n = st.args.map(Number)
      res = { considered: n[0] || 0, imported: n[2] || 0, unchanged: n[4] || 0,
              newUids: n[5] || 0, newSubkeys: n[6] || 0, newSigs: n[7] || 0, revocations: n[8] || 0,
              secretRead: n[9] || 0, secretImported: n[10] || 0, secretUnchanged: n[11] || 0, notImported: n[12] || 0 }
    }
  }
  if (!res || res.considered === 0) return { ok: false, fingerprints: [], message: "No keys found in the text." }
  var parts = []
  if (res.imported) parts.push(res.imported + (res.imported === 1 ? " key imported" : " keys imported"))
  if (res.secretImported) parts.push(res.secretImported + " secret " + (res.secretImported === 1 ? "key" : "keys") + " imported")
  var updates = res.newUids + res.newSubkeys + res.newSigs + res.revocations
  if (updates) parts.push(updates + (updates === 1 ? " update" : " updates") + " to existing keys")
  if (res.unchanged && !res.imported && !updates) parts.push("already in your keyring")
  if (res.notImported) parts.push(res.notImported + " not imported")
  return { ok: res.notImported < res.considered, fingerprints: fingerprints, message: parts.join(", ") || "Nothing changed" }
}

function hasStatus(status, keyword) {
  for (var i = 0; i < status.length; i++) if (status[i].keyword === keyword) return true
  return false
}

if (typeof module !== "undefined") {
  module.exports = {
    BASE_ARGS: BASE_ARGS,
    MAX_INPUT_CHARS: MAX_INPUT_CHARS,
    MAX_INPUT_BYTES: MAX_INPUT_BYTES,
    MAX_OUTPUT_BYTES: MAX_OUTPUT_BYTES,
    gpgArgs: gpgArgs,
    expandHome: expandHome,
    listKeysArgs: listKeysArgs,
    isFingerprint: isFingerprint,
    encryptArgs: encryptArgs,
    clearsignArgs: clearsignArgs,
    decryptArgs: decryptArgs,
    importArgs: importArgs,
    exportArgs: exportArgs,
    lsignArgs: lsignArgs,
    parseKeys: parseKeys,
    validityLabel: validityLabel,
    formatFingerprint: formatFingerprint,
    shortFingerprint: shortFingerprint,
    keyLabel: keyLabel,
    findKey: findKey,
    encryptionKeys: encryptionKeys,
    signingKeys: signingKeys,
    messageKind: messageKind,
    inputTooLarge: inputTooLarge,
    utf8Length: utf8Length,
    workerFailure: workerFailure,
    writeSucceeded: writeSucceeded,
    parseStatusLine: parseStatusLine,
    parseStatus: parseStatus,
    decryptSummary: decryptSummary,
    signatureText: signatureText,
    signatureTone: signatureTone,
    signatureIdentity: signatureIdentity,
    encryptFailure: encryptFailure,
    importSummary: importSummary,
    hasStatus: hasStatus
  }
}
