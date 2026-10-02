#!/usr/bin/env bash
# One version for every platform. It lives in five files:
#   NotchBuddy/project.yml (macOS), windows/package.json, windows/package-lock.json,
#   windows/src-tauri/tauri.conf.json and windows/Cargo.toml (Windows and Linux).
#
#   bash scripts/versions.sh show            what each file says
#   bash scripts/versions.sh set 0.3.0       writes it everywhere
#   bash scripts/versions.sh check 0.3.0     fails if any file disagrees (used by CI on tags)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

python3 - "$@" <<'PY'
import json, re, sys

def mac(v=None):
    p = "NotchBuddy/project.yml"; s = open(p).read()
    pat = r'(CFBundleShortVersionString: )"([^"]*)"'
    if v: open(p, "w").write(re.sub(pat, rf'\g<1>"{v}"', s, count=1))
    return re.search(pat, s).group(2)

def jsonfile(path, keys):
    def f(v=None):
        d = json.load(open(path))
        cur = d
        for k in keys[:-1]: cur = cur[k]
        old = cur[keys[-1]]
        if v:
            cur[keys[-1]] = v
            open(path, "w").write(json.dumps(d, indent=2, ensure_ascii=False) + "\n")
        return old
    return f

def cargo(v=None):
    p = "windows/Cargo.toml"; s = open(p).read()
    pat = r'(\[workspace\.package\]\s*\nversion = )"([^"]*)"'
    if v: open(p, "w").write(re.sub(pat, rf'\g<1>"{v}"', s, count=1))
    return re.search(pat, s).group(2)

lock = "windows/package-lock.json"
files = {
    "NotchBuddy/project.yml": mac,
    "windows/package.json": jsonfile("windows/package.json", ["version"]),
    lock: jsonfile(lock, ["version"]),
    "windows/src-tauri/tauri.conf.json": jsonfile("windows/src-tauri/tauri.conf.json", ["version"]),
    "windows/Cargo.toml": cargo,
}

cmd = sys.argv[1] if len(sys.argv) > 1 else "show"
want = sys.argv[2] if len(sys.argv) > 2 else None
if cmd in ("set", "check") and not (want and re.fullmatch(r"\d+\.\d+\.\d+", want)):
    sys.exit(f"✗ Give a version like 0.3.0 (got {want!r})")

if cmd == "show":
    for name, f in files.items(): print(f"{f():>10}  {name}")
elif cmd == "set":
    for f in files.values(): f(want)
    jsonfile(lock, ["packages", "", "version"])(want)
    print(f"✓ {want} everywhere")
elif cmd == "check":
    bad = [f"{name} says {f()}" for name, f in files.items() if f() != want]
    if bad: sys.exit(f"✗ The tag says {want}, but " + "; ".join(bad) + ". Run: bash scripts/versions.sh set " + want)
    print(f"✓ every platform is {want}")
else:
    sys.exit("usage: versions.sh show | set <version> | check <version>")
PY
