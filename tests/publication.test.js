// Repository/package checks, including files not staged yet during development.
const assert = require("node:assert/strict")
const fs = require("node:fs")
const path = require("node:path")
const {execFileSync} = require("node:child_process")
const root = path.resolve(__dirname, "..")
const manifest = JSON.parse(fs.readFileSync(path.join(root, "manifest.json"), "utf8"))
function sourceFiles(directory, prefix = "") {
  const out = []
  for (const entry of fs.readdirSync(directory, {withFileTypes:true})) {
    if ([".git", "__pycache__", ".venv", "venv", "node_modules"].includes(entry.name)) continue
    const name = prefix + entry.name
    if (entry.isDirectory()) out.push(...sourceFiles(path.join(directory, entry.name), name + "/"))
    else out.push(name)
  }
  return out
}
let candidates
try {
  candidates = execFileSync("git", ["-c", "safe.directory=" + root, "ls-files", "--cached", "--others", "--exclude-standard", "-z"],
    {cwd:root, encoding:"utf8", stdio:["ignore", "pipe", "ignore"]}).split("\0").filter(Boolean)
} catch (e) {
  // GitHub's source archives do not contain .git metadata.
  candidates = sourceFiles(root)
}
assert.equal(manifest.id, "io.github.yaeloss.omapgp")
assert.equal(manifest.name, "omaPGP")
assert.equal(manifest.barWidget.displayName, "omaPGP")
assert.match(manifest.version, /^\d+\.\d+\.\d+$/)
assert.equal(manifest.license, "MIT")
for (const name of [manifest.entryPoints.barWidget, "Panel.qml", "GpgProcess.qml", "Model.js", "PgpTextArea.qml", "PgpTextView.qml", "gpg-worker.py", "assets/icon.svg", "LICENSE", "README.md", "SECURITY.md", "CHANGELOG.md"]) {
  assert.ok(name && !path.isAbsolute(name) && !name.split("/").includes(".."), "safe package path")
  assert.ok(fs.statSync(path.join(root, name)).isFile(), "missing package file: " + name)
}
assert.match(fs.readFileSync(path.join(root, "LICENSE"), "utf8"), /^MIT License/)

// Keep the committed preview usable without an image-processing dependency in CI.
const preview = fs.readFileSync(path.join(root, ".github", "social-preview.png"))
assert.equal(preview.subarray(0, 8).toString("hex"), "89504e470d0a1a0a", "preview must be PNG")
assert.equal(preview.toString("ascii", 12, 16), "IHDR")
assert.equal(preview.readUInt32BE(16), 1280)
assert.equal(preview.readUInt32BE(20), 640)
assert.ok(preview.length < 1000000, "social preview must stay below 1 MB")
const previewSource = fs.readFileSync(path.join(root, ".github", "social-preview.svg"), "utf8")
assert.match(previewSource, /Illustrative UI/)
assert.ok(!/<(?:script|foreignObject)\b|href\s*=\s*["'](?:https?:|\/\/|data:)/i.test(previewSource), "preview source must stay self-contained and script-free")

for (const name of candidates) {
  const file = path.join(root, name)
  let stat
  try { stat = fs.lstatSync(file) }
  catch (e) { if (e.code === "ENOENT") continue; throw e } // Permit an unstaged deletion.
  const privatePath = name.split("/").some(part => [".gnupg", "gnupg", "private-keys-v1.d", "openpgp-revocs.d", ".env"].includes(part) || (part.startsWith(".env.") && part !== ".env.example"))
  assert.ok(!privatePath, "local secret/keyring file in package: " + name)
  assert.ok(!stat.isSymbolicLink() && stat.isFile(), "plugin sources must be regular files, not symlinks: " + name)
  const data = fs.readFileSync(file)
  if (data.includes(0)) continue
  const text = data.toString("utf8")
  assert.ok(!/^-----BEGIN (?:PGP PRIVATE KEY BLOCK|(?:[A-Z0-9]+ )?PRIVATE KEY)-----\r?$/m.test(text), "private-key material in " + name)
  assert.ok(!/\b(?:gh[pousr]_[A-Za-z0-9_]{30,}|github_pat_[A-Za-z0-9_]{50,})\b/.test(text), "possible GitHub credential in " + name)
  if (name.endsWith(".md")) {
    for (const match of text.matchAll(/\[[^\]]*\]\(([^)]+)\)/g)) {
      const target = match[1].split("#")[0]
      if (!target || /^[a-z][a-z\d+.-]*:/i.test(target)) continue
      assert.ok(!path.isAbsolute(target), "machine-specific Markdown link in " + name)
      assert.ok(fs.existsSync(path.resolve(path.dirname(file), decodeURIComponent(target))), "broken local link in " + name + ": " + target)
    }
  }
}
console.log("publication/package checks passed (not a comprehensive secret scanner)")
