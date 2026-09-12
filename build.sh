#!/usr/bin/env bash
# Build a Docusaurus site into a Kiwix ZIM.
#
# A ZIM serves entries, not directories, and the reader mounts a book under a URL
# prefix. Two things follow, and this script handles both:
#
#   1. the site is built with baseUrl set to that prefix, so the server-rendered HTML
#      and the hydrated React router both emit paths the reader can resolve;
#   2. every page gets a redirect from "page/" to "page/index.html", because the
#      reader will not resolve a directory to its index.
#
# Requires Docker: the packaging image (built from this repo's Dockerfile) and
# kiwix-serve for --serve/--verify.
#
#   docusaurus2zim/build.sh                   build, package
#   docusaurus2zim/build.sh --serve           also serve it on :8081
#   docusaurus2zim/build.sh --skip-build      repackage the existing out-dir
#
# Run from the root of a Docusaurus site that has a docusaurus2zim.json.
#
set -euo pipefail

# Defaults live in the offliner definition, which is also the Zimfarm contract, so
# there is one declarative source for them rather than two that drift.
# The config may live outside the site repo, so it is mounted into the packaging
# container separately rather than assumed to be under $ROOT.
CONFIG="${DOCUSAURUS2ZIM_CONFIG:-docusaurus2zim.json}"
cfg() {
  python3 -c "
import json, sys
v = json.load(open(sys.argv[1]))['defaults'].get(sys.argv[2], '')
print(v if isinstance(v, str) else json.dumps(v))
" "$CONFIG" "$1"
}
NAME="$(cfg name)"
TITLE="$(cfg title)"
DESCRIPTION="$(cfg description)"
CREATOR="$(cfg creator)"
PUBLISHER="$(cfg publisher)"
LANGUAGE="$(cfg language)"
EXCLUDE="$(cfg exclude)"
PRUNE_PREFIXES="$(cfg prune_prefixes)"
INDEX_SELECTOR="$(cfg index_selector)"
ONLY_CURRENT="$(cfg only_current_version)"
CONFIG_OVERRIDES="$(cfg docusaurus_overrides)"
# cfg emits JSON, so these are already valid JS literals for the wrapper.
ONLY_CURRENT_JS="${ONLY_CURRENT:-false}"
CONFIG_OVERRIDES_JS="${CONFIG_OVERRIDES:-{\}}"
WELCOME="index.html"
OUT_DIR="build-zim"
ZIM_DIR="zim-out"
HEAP="${ZIM_BUILD_HEAP:-1800}"
BASE_URL=""
SERVE=0
VERIFY=0
SKIP_BUILD=0
SERVE_PORT=8081
MIRROR_HOSTS="$(cfg mirror_hosts)"
ASSET_PREFIXES="$(cfg asset_prefixes)"
# Substrings excluded from --verify failures. Empty by default: the site now applies
# baseUrl everywhere a build can reach, so a broken reference is a real defect.
VERIFY_IGNORE=""
PACKAGE_IMAGE="${DOCUSAURUS2ZIM_IMAGE:-docusaurus2zim:latest}"
KIWIX_IMAGE="ghcr.io/kiwix/kiwix-serve"

usage() {
  sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
  cat <<EOF

Options:
  --name NAME          ZIM name, also the book id in the reader URL (default: $NAME)
  --title TITLE        ZIM title (default: $TITLE)
  --base-url URL       serving prefix (default: /content/<name>/)
  --out-dir DIR        site build directory (default: $OUT_DIR)
  --zim-dir DIR        where the .zim is written (default: $ZIM_DIR)
  --heap MB            node heap cap for the build (default: $HEAP)
  --skip-build         reuse an existing --out-dir
  --serve              serve the result with kiwix-serve on :$SERVE_PORT
  --verify             probe every internal link on a sample of pages
  --mirror-hosts LIST  comma-separated hosts whose images are copied into the ZIM
                       (default: $MIRROR_HOSTS; pass "" to disable)
  --asset-prefixes L   comma-separated root-absolute asset prefixes to re-point at
                       baseUrl (default: $ASSET_PREFIXES; pass "" to disable)
  --verify-ignore L    comma-separated substrings excluded from --verify failures
                       (default: none)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name) NAME="$2"; shift 2 ;;
    --title) TITLE="$2"; shift 2 ;;
    --base-url) BASE_URL="$2"; shift 2 ;;
    --out-dir) OUT_DIR="$2"; shift 2 ;;
    --zim-dir) ZIM_DIR="$2"; shift 2 ;;
    --heap) HEAP="$2"; shift 2 ;;
    --skip-build) SKIP_BUILD=1; shift ;;
    --serve) SERVE=1; shift ;;
    --verify) VERIFY=1; shift ;;
    --mirror-hosts) MIRROR_HOSTS="$2"; shift 2 ;;
    --asset-prefixes) ASSET_PREFIXES="$2"; shift 2 ;;
    --verify-ignore) VERIFY_IGNORE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# Operates on the site repo, which is the working directory - not on this tool's
# own location, which may be anywhere.
ROOT="$PWD"
[[ -f "$CONFIG" ]] || { echo "no $CONFIG; run from a Docusaurus site repo, or set DOCUSAURUS2ZIM_CONFIG" >&2; exit 1; }
CONFIG_ABS="$(cd "$(dirname "$CONFIG")" && pwd)/$(basename "$CONFIG")"
: "${BASE_URL:=/content/$NAME/}"
[[ "$BASE_URL" == */ ]] || BASE_URL="$BASE_URL/"

command -v docker >/dev/null || { echo "docker is required" >&2; exit 1; }
docker info >/dev/null 2>&1 || {
  echo "docker daemon unreachable (on WSL, enable integration for this distro)" >&2
  exit 1
}

# ---------------------------------------------------------------- build
# docusaurus.config.js takes its baseUrl from DOCS_BASE_URL, so a subpath build needs
# no patched copy of the config.
if [[ $SKIP_BUILD -eq 0 ]]; then
  echo "==> building with baseUrl $BASE_URL (heap ${HEAP}MB)"
  rm -rf "$OUT_DIR"

  # Overrides are applied by a generated wrapper config rather than by editing the
  # site's own. Docusaurus loads the config through its own transpiler, and that
  # transpiles the nested require too, so the wrapper can import the real config and
  # mutate the object - no textual patching, and nothing to change in the site repo.
  BUILD_CONFIG="docusaurus.config.js"
  if [[ "$ONLY_CURRENT" == "true" || -n "$CONFIG_OVERRIDES" ]]; then
    BUILD_CONFIG=".docusaurus2zim.config.js"
    trap 'rm -f "$ROOT/.docusaurus2zim.config.js"' EXIT
    cat > "$BUILD_CONFIG" <<WRAPPER
// Generated by docusaurus2zim. Safe to delete.
const base = require("./docusaurus.config.js");
const config = base.default ?? base;

// The docs plugin may be configured through a preset or listed directly.
function docsOptions(c) {
  for (const preset of c.presets ?? []) {
    if (Array.isArray(preset) && preset[1] && preset[1].docs) return preset[1].docs;
  }
  for (const plugin of c.plugins ?? []) {
    if (Array.isArray(plugin) && /plugin-content-docs/.test(String(plugin[0])) && plugin[1]) {
      return plugin[1];
    }
  }
  return null;
}

if (${ONLY_CURRENT_JS}) {
  const docs = docsOptions(config);
  if (!docs) throw new Error("docusaurus2zim: no docs plugin options found to override");
  docs.onlyIncludeVersions = ["current"];
  // Leaving config for an excluded version behind trips Docusaurus validation.
  if (docs.versions) docs.versions = { current: docs.versions.current };
}

for (const [path, value] of Object.entries(${CONFIG_OVERRIDES_JS})) {
  const keys = path.split(".");
  let node = config;
  for (const key of keys.slice(0, -1)) {
    if (node[key] == null) node[key] = {};
    node = node[key];
  }
  node[keys[keys.length - 1]] = value;
}

module.exports = config;
WRAPPER
    echo "==> using generated override config ($BUILD_CONFIG)"
  fi

  DOCS_BASE_URL="$BASE_URL" NODE_OPTIONS="--max-old-space-size=$HEAP" \
    npx docusaurus build --config "$BUILD_CONFIG" --out-dir "$OUT_DIR"
else
  [[ -d "$OUT_DIR" ]] || { echo "$OUT_DIR does not exist" >&2; exit 1; }
  echo "==> reusing $OUT_DIR"
fi

# ------------------------------------------------- mirror external assets
# Device images live on flasher.meshtastic.org, so a build-from-source ZIM shows gaps
# where the hardware pages expect pictures. Pull them in and point at the copies.
if [[ -n "$MIRROR_HOSTS" ]]; then
  python3 - "$OUT_DIR" "$BASE_URL" "$MIRROR_HOSTS" <<'MIRROR'
import os, re, subprocess, sys

out_dir, base_url, hosts = sys.argv[1], sys.argv[2], sys.argv[3].split(",")
EXT = (".svg", ".png", ".jpg", ".jpeg", ".webp", ".gif", ".ico")
host_alt = "|".join(re.escape(h) for h in hosts)
pattern = re.compile("https://(" + host_alt + ")(/[^\\s\"'<>()\\\\]+)")

scanned = [
    os.path.join(d, n)
    for d, _, names in os.walk(out_dir)
    for n in names
    if n.endswith((".html", ".js", ".css"))
]

targets = set()
for path in scanned:
    text = open(path, encoding="utf-8", errors="replace").read()
    for host, resource in pattern.findall(text):
        if resource.lower().endswith(EXT):
            targets.add((host, resource))

if not targets:
    print("==> no external assets to mirror")
    sys.exit()

fetched = failed = 0
for host, resource in sorted(targets):
    local = os.path.join(out_dir, "zim-external", host, resource.lstrip("/"))
    if os.path.exists(local):
        continue
    os.makedirs(os.path.dirname(local), exist_ok=True)
    r = subprocess.run(["curl", "-sfL", "-m", "30", "-o", local, "https://" + host + resource])
    if r.returncode == 0:
        fetched += 1
    else:
        failed += 1
        if os.path.exists(local):
            os.remove(local)

# Rewrite the containing directories, not just the filenames: components build image
# URLs at runtime from a bare prefix, so rewriting only complete URLs leaves the
# hydrated page pointing back at the network. Absolute under baseUrl, because a shared
# JS chunk has no single page depth to be relative to.
prefixes = sorted(
    {(host, resource.rsplit("/", 1)[0] + "/") for host, resource in targets},
    key=lambda hp: len(hp[1]),
    reverse=True,
)

rewrites = 0
for path in scanned:
    text = open(path, encoding="utf-8", errors="replace").read()
    new = text
    for host, prefix in prefixes:
        new = new.replace(
            "https://" + host + prefix,
            base_url + "zim-external/" + host + prefix,
        )
    if new != text:
        open(path, "w", encoding="utf-8").write(new)
        rewrites += 1

print("==> mirrored %d external assets (%d failed), rewrote %d files" % (fetched, failed, rewrites))
MIRROR
fi

# ------------------------------------------------- stray root-absolute assets
# MDX gets baseUrl from the site's remark plugin, but raw paths written inside React
# components do not, so they still point outside the book. Only asset prefixes are
# touched here; route-shaped links are left alone, since those are the site's to fix.
if [[ -n "$ASSET_PREFIXES" ]]; then
  python3 - "$OUT_DIR" "$BASE_URL" "$ASSET_PREFIXES" <<'STRAY'
import os, sys

out_dir, base_url, prefixes = sys.argv[1], sys.argv[2], sys.argv[3].split(",")
scanned = [
    os.path.join(d, n)
    for d, _, names in os.walk(out_dir)
    for n in names
    if n.endswith((".html", ".js", ".css"))
]

rewrites = 0
for path in scanned:
    text = open(path, encoding="utf-8", errors="replace").read()
    new = text
    for prefix in prefixes:
        # quoted and unquoted attribute forms; the HTML minifier drops the quotes
        for lead in ('"', "'", "=", "("):
            new = new.replace(lead + prefix, lead + base_url.rstrip("/") + prefix)
    if new != text:
        open(path, "w", encoding="utf-8").write(new)
        rewrites += 1

print("==> re-pointed stray asset paths in %d files" % rewrites)
STRAY
fi

# ------------------------------------------------------------- redirects
REDIRECTS="$OUT_DIR/.zim-redirects.tsv"
# Optional site-supplied cover; package.py falls back to the favicon, then a flat square.
ILLUSTRATION_REL="zim-illustration.png"

python3 - "$OUT_DIR" "$REDIRECTS" <<'PY'
import os, sys

out_dir, redirects_path = sys.argv[1], sys.argv[2]

# Pages are stored at their route ("page/"), so the file name and the slash-less form
# both redirect there: raw HTML hrefs bypass trailingSlash, and a ZIM has no server to
# normalise them the way the live site does.
rows = []
for dirpath, _, names in os.walk(out_dir):
    if "index.html" not in names:
        continue
    rel = os.path.relpath(dirpath, out_dir).replace(os.sep, "/")
    if rel == ".":
        continue
    target = f"{rel}/"
    title = rel.rsplit("/", 1)[-1].replace("-", " ")
    rows.append(f"{rel}/index.html\t{title}\t{target}")
    rows.append(f"{rel}\t{title}\t{target}")
with open(redirects_path, "w", encoding="utf-8") as fh:
    fh.write("\n".join(rows) + "\n")
print(f"==> {len(rows)} redirects written")
PY

# ---------------------------------------------------------------- package
mkdir -p "$ZIM_DIR"
ZIM_FILE="$ZIM_DIR/$NAME.zim"
rm -f "$ZIM_FILE"
echo "==> packaging $ZIM_FILE"
docker run --rm --user "$(id -u):$(id -g)" \
  -v "$ROOT:/work" -v "$CONFIG_ABS:/config.json:ro" -w /work "$PACKAGE_IMAGE" \
  --config /config.json \
  --build-dir "/work/$OUT_DIR" \
  --output "/work/$ZIM_FILE" \
  --redirects "/work/$REDIRECTS" \
  --illustration "$ILLUSTRATION_REL" \
  --main-path "$WELCOME" \
  --name "$NAME" \
  --title "$TITLE" \
  --description "$DESCRIPTION" \
  --language "$LANGUAGE" \
  --creator "$CREATOR" \
  --publisher "$PUBLISHER" \
  --exclude "$EXCLUDE" \
  --prune-prefixes "$PRUNE_PREFIXES" \
  --index-selector "$INDEX_SELECTOR"


echo "==> $(du -h "$ZIM_FILE" | cut -f1)  $ZIM_FILE"

# ---------------------------------------------------------------- serve
if [[ $SERVE -eq 1 || $VERIFY -eq 1 ]]; then
  docker rm -f "zim-$NAME" >/dev/null 2>&1 || true
  docker run -d --name "zim-$NAME" -p "$SERVE_PORT:8080" \
    -v "$ROOT/$ZIM_DIR:/data" "$KIWIX_IMAGE" "$NAME.zim" >/dev/null
  sleep 5
  echo "==> serving http://localhost:$SERVE_PORT/content/$NAME/$WELCOME"
fi

if [[ $VERIFY -eq 1 ]]; then
  python3 - "$SERVE_PORT" "$NAME" "$OUT_DIR" "$VERIFY_IGNORE" <<'PY'
import os, posixpath, random, re, subprocess, sys

port, name, out_dir = sys.argv[1], sys.argv[2], sys.argv[3]
ignore = [i for i in (sys.argv[4].split(",") if len(sys.argv) > 4 else []) if i]
book = f"/content/{name}"
SKIP = ("http://", "https://", "//", "#", "mailto:", "data:", "javascript:")

def fetch(url):
    """Page bodies only; decoded leniently since a ZIM also holds binary entries."""
    r = subprocess.run(["curl", "-s", "-m", "25", "-w", "\n%{http_code}",
                        f"http://localhost:{port}{url}"], capture_output=True)
    raw, _, code = r.stdout.rpartition(b"\n")
    return raw.decode("utf-8", "replace"), code.decode("ascii", "replace")

def status(url):
    """-L so a "page/" redirect counts as reachable, which is how a browser sees it."""
    r = subprocess.run(["curl", "-sL", "-o", "/dev/null", "-m", "25",
                        "-w", "%{http_code}", f"http://localhost:{port}{url}"],
                       capture_output=True, text=True)
    return r.stdout.strip()

def join(base, ref):
    """posixpath.normpath eats the trailing slash, and the slash is the whole point."""
    joined = posixpath.join(base, ref)
    trailing = joined.endswith("/")
    out = posixpath.normpath(joined)
    return out + "/" if trailing and not out.endswith("/") else out

pages = []
for dirpath, _, names in os.walk(out_dir):
    if "index.html" in names:
        rel = os.path.relpath(os.path.join(dirpath, "index.html"), out_dir).replace(os.sep, "/")
        pages.append(rel)
random.seed(1)
sample = ["index.html"] + random.sample(pages, min(12, len(pages)))

checked = broken = 0
failures = []
for page in sample:
    url = f"{book}/{page}"
    body, code = fetch(url)
    if code != "200":
        failures.append((code, url)); continue
    base = posixpath.dirname(url) + "/"
    refs = set()
    for m in re.finditer(r'(?:href|src)=(["\']?)([^"\'> ]+)\1', body):
        ref = m.group(2)
        if ref.startswith(SKIP) or ":" in ref.split("/")[0]:
            continue                      # custom schemes such as meshtastic:///
        refs.add(join(base, ref.split("#")[0].split("?")[0]))
    for ref in refs:
        code = status(ref)
        checked += 1
        if code != "200":
            broken += 1; failures.append((code, ref))

ignored = [f for f in failures if any(i in f[1] for i in ignore)]
real = [f for f in failures if f not in ignored]
print(f"==> verified {len(sample)} pages, {checked} references, "
      f"{len(real)} broken, {len(ignored)} ignored")
for code, url in real[:15]:
    print(f"    {code}  {url}")
if ignored:
    print(f"    ({len(ignored)} ignored, e.g. {ignored[0][1]} - site-side absolute path)")
sys.exit(1 if real else 0)
PY
fi
