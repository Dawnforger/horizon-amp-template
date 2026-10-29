#!/usr/bin/env bash
# Prepares Horizon's game files on a headless box (VPS, Docker, AMP) with no Minecraft launcher.
#
# It builds the launcher layout horizon-prepare reads (versions/<v>/<v>.json, <v>.jar, libraries/)
# straight from Mojang's CDN, using the exact files research-lock.json pins (every file is
# SHA-1 checked here and again by horizon-prepare), then runs horizon-prepare.
#
#   prepare-headless.sh <horizon-release-dir>
#
# Needs: bash, python3, and Java 25 (JAVA_HOME or `java` on PATH). With HORIZON_FETCH_JAVA=1
# and no Java 25 found, it downloads an Eclipse Temurin 25 JRE into the work folder.
# By running this you accept the Minecraft EULA (https://aka.ms/MinecraftEULA). You should own
# Minecraft Java Edition.
set -euo pipefail

ROOT=${1:?usage: prepare-headless.sh <horizon-release-dir>}
ROOT=$(cd "$ROOT" && pwd)
LOCK="$ROOT/research-lock.json"
[ -f "$LOCK" ] || { echo "prepare: no research-lock.json in $ROOT" >&2; exit 1; }
[ -x "$ROOT/horizon-prepare" ] || { echo "prepare: no horizon-prepare in $ROOT" >&2; exit 1; }
command -v python3 >/dev/null || { echo "prepare: python3 is needed" >&2; exit 1; }

WORK=${HORIZON_PREP_WORK:-"$ROOT/.prep-work"}
mkdir -p "$WORK"

VERSION=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["minecraft"]["version"])' "$LOCK")
JAVA_MAJOR=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["minecraft"]["java_major"])' "$LOCK")

# Skip when these exact pins were already prepared (a Horizon update that changes them re-prepares).
STAMP="$ROOT/.local/horizon-client/.prepared-lock.sha256"
LOCK_SUM=$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$LOCK")
if [ "${HORIZON_REPREPARE:-0}" != 1 ] && [ -f "$STAMP" ] && [ "$(cat "$STAMP")" = "$LOCK_SUM" ] \
   && [ -n "$(ls -A "$ROOT/.local/horizon-client/$VERSION" 2>/dev/null)" ]; then
  echo "prepare: $VERSION already prepared for this Horizon build (HORIZON_REPREPARE=1 to redo)"
  exit 0
fi

echo "prepare: fetching the pinned Minecraft $VERSION files from Mojang..."
python3 - "$LOCK" "$WORK/minecraft" "$WORK/server.jar" <<'PY'
import hashlib, json, os, sys, urllib.request
from concurrent.futures import ThreadPoolExecutor

lock = json.load(open(sys.argv[1]))["minecraft"]
mc, server_jar = sys.argv[2], sys.argv[3]
v = lock["version"]

def sha1(path):
    h = hashlib.sha1()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()

def get(url, dest, want):
    if os.path.isfile(dest) and sha1(dest) == want:
        return
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    tmp = dest + ".part"
    for attempt in range(3):
        try:
            with urllib.request.urlopen(url, timeout=60) as r, open(tmp, "wb") as f:
                while chunk := r.read(1 << 20):
                    f.write(chunk)
            break
        except Exception as e:
            if attempt == 2:
                raise SystemExit(f"prepare: download failed: {url}: {e}")
    got = sha1(tmp)
    if got != want:
        os.remove(tmp)
        raise SystemExit(f"prepare: {url} has sha1 {got}, expected {want}")
    os.replace(tmp, dest)

manifest_path = os.path.join(mc, "versions", v, f"{v}.json")
get(f"https://piston-meta.mojang.com/v1/packages/{lock['manifest_sha1']}/{v}.json",
    manifest_path, lock["manifest_sha1"])
manifest = json.load(open(manifest_path))
d = manifest["downloads"]
assert d["client"]["sha1"] == lock["client_sha1"] and d["server"]["sha1"] == lock["server_sha1"]

jobs = [(d["client"]["url"], os.path.join(mc, "versions", v, f"{v}.jar"), d["client"]["sha1"]),
        (d["server"]["url"], server_jar, d["server"]["sha1"])]
# Every library artifact, any OS: horizon-prepare picks the ones it needs.
for lib in manifest.get("libraries", []):
    a = lib.get("downloads", {}).get("artifact")
    if a and a.get("url") and a.get("path"):
        jobs.append((a["url"], os.path.join(mc, "libraries", a["path"]), a["sha1"]))

with ThreadPoolExecutor(8) as pool:
    list(pool.map(lambda j: get(*j), jobs))
print(f"prepare: {len(jobs)} files verified")
PY

# Java: JAVA_HOME, PATH, or (opt-in) a downloaded Temurin JRE.
java_ok() { "$1" -version 2>&1 | grep -Eq "version \"$JAVA_MAJOR([.\"]|$)"; }
if [ -n "${JAVA_HOME:-}" ] && [ -x "$JAVA_HOME/bin/java" ] && java_ok "$JAVA_HOME/bin/java"; then :
elif command -v java >/dev/null && java_ok "$(command -v java)"; then
  JAVA_HOME=$(dirname "$(dirname "$(readlink -f "$(command -v java)")")"); export JAVA_HOME
elif [ "${HORIZON_FETCH_JAVA:-0}" = 1 ]; then
  if [ ! -x "$WORK/jre/bin/java" ]; then
    echo "prepare: downloading Temurin $JAVA_MAJOR JRE..."
    mkdir -p "$WORK/jre"
    python3 - "$JAVA_MAJOR" "$WORK/jre.tar.gz" <<'PY'
import sys, urllib.request
url = f"https://api.adoptium.net/v3/binary/latest/{sys.argv[1]}/ga/linux/x64/jre/hotspot/normal/eclipse"
urllib.request.urlretrieve(url, sys.argv[2])
PY
    tar -xzf "$WORK/jre.tar.gz" -C "$WORK/jre" --strip-components=1
    rm -f "$WORK/jre.tar.gz"
  fi
  export JAVA_HOME="$WORK/jre"
else
  echo "prepare: Java $JAVA_MAJOR not found (set JAVA_HOME, or HORIZON_FETCH_JAVA=1 to download one)" >&2
  exit 1
fi
export PATH="$JAVA_HOME/bin:$PATH"

echo "prepare: running horizon-prepare (a few minutes)..."
"$ROOT/horizon-prepare" --root "$ROOT" --prepare \
  --server-jar "$WORK/server.jar" --minecraft-dir "$WORK/minecraft"

# The launcher copy and the JRE aren't needed after this; keep them only if asked.
[ "${HORIZON_KEEP_WORK:-0}" = 1 ] || rm -rf "$WORK/minecraft" "$WORK/server.jar"
echo "$LOCK_SUM" > "$STAMP"
echo "prepare: done -> $ROOT/.local/horizon-client/$VERSION"
