#!/usr/bin/env bash
# Build a Docusaurus site into a Kiwix ZIM.
#
# A ZIM serves entries, not directories, and the reader mounts a book under a URL
# prefix. Two things follow, and this script handles both:
#
#   1. by default the book is relative, like an openZIM book, and works at any mount
#      point: the site is built with a placeholder baseUrl, and relativize.mjs turns
#      every use of it into a relative path (HTML, CSS) or the mount point found at
#      load time (the JavaScript). With --base-url the site is built for that one
#      prefix instead, and works there only;
#   2. every page is stored at its route, "page/", and both "page/index.html" and
#      "page" redirect there, because the reader has no server to normalise them.
#
# Packaging runs in Docker (the image built from this repo's Dockerfile), or with a
# local Python under --no-docker. --serve/--verify always need Docker, for kiwix-serve.
#
#   docusaurus2zim/build.sh                   build, package
#   docusaurus2zim/build.sh --serve           also serve it on :8081
#   docusaurus2zim/build.sh --skip-build      repackage the existing out-dir
#   docusaurus2zim/build.sh --no-docker       package without Docker
#
# Run from the root of a Docusaurus site that has a docusaurus2zim.json, or point
# DOCUSAURUS2ZIM_CONFIG at one.
#
set -euo pipefail

# Values come from the site's config, under "defaults"; the flags themselves are
# declared in offliner-definition.json, the Zimfarm offliner contract. The config may
# live outside the site repo, so the Docker packaging step mounts it separately
# rather than assuming it is under $ROOT.
CONFIG="${DOCUSAURUS2ZIM_CONFIG:-docusaurus2zim.json}"
cfg() {
  # No config yet reads as empty, so --help works anywhere; a real run stops at the
  # config check below.
  python3 -c "
import json, sys
try:
    v = json.load(open(sys.argv[1]))['defaults'].get(sys.argv[2], '')
except FileNotFoundError:
    v = ''
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
NO_DOCKER=0
SERVE_PORT=8081
MIRROR_HOSTS="$(cfg mirror_hosts)"
ASSET_PREFIXES="$(cfg asset_prefixes)"
# Substrings excluded from --verify failures. Empty by default: the site now applies
# baseUrl everywhere a build can reach, so a broken reference is a real defect.
VERIFY_IGNORE=""
PACKAGE_IMAGE="${DOCUSAURUS2ZIM_IMAGE:-docusaurus2zim:latest}"
KIWIX_IMAGE="ghcr.io/kiwix/kiwix-serve"

usage() {
  # The header comment, however long it grows: line 2 up to the first non-comment line.
  awk 'NR == 1 { next } !/^#/ { exit } { sub(/^# ?/, ""); print }' "$0"
  cat <<EOF

Options:
  --name NAME          ZIM name, also the book id in the reader URL (default: $NAME)
  --title TITLE        ZIM title (default: $TITLE)
  --base-url URL       build for this one serving prefix only, e.g. /content/<name>/
                       (default: none: a relative book that works at any mount)
  --out-dir DIR        site build directory (default: $OUT_DIR)
  --zim-dir DIR        where the .zim is written (default: $ZIM_DIR)
  --heap MB            node heap cap for the build (default: $HEAP)
  --skip-build         reuse an existing --out-dir
  --no-docker          package with this machine's Python instead of the image; needs
                       requirements.txt installed (\$DOCUSAURUS2ZIM_PYTHON picks the
                       interpreter) and libmagic + libcairo. Not with --serve/--verify.
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
    --no-docker) NO_DOCKER=1; shift ;;
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
# No base URL: a relative book. The build uses a placeholder, which relativize.mjs
# replaces everywhere afterwards; it must match ROOT there.
RELATIVE=0
if [[ -z "$BASE_URL" ]]; then
  RELATIVE=1
  BASE_URL="/__d2z_root__/"
fi
[[ "$BASE_URL" == */ ]] || BASE_URL="$BASE_URL/"

if [[ $NO_DOCKER -eq 1 ]]; then
  PYTHON="${DOCUSAURUS2ZIM_PYTHON:-python3}"
  [[ $SERVE -eq 0 && $VERIFY -eq 0 ]] ||
    { echo "--serve/--verify run kiwix-serve in Docker; drop them with --no-docker" >&2; exit 2; }
  "$PYTHON" -c "import zimscraperlib" 2>/dev/null ||
    { echo "$PYTHON has no zimscraperlib: pip install -r $(dirname "$0")/requirements.txt" >&2; exit 1; }
else
  command -v docker >/dev/null || { echo "docker is required (or --no-docker)" >&2; exit 1; }
  docker info >/dev/null 2>&1 || {
    echo "docker daemon unreachable (on WSL, enable integration for this distro, or --no-docker)" >&2
    exit 1
  }
fi

# ---------------------------------------------------------------- build
# The generated wrapper config sets baseUrl. DOCS_BASE_URL is also passed, for sites
# (Meshtastic's) whose own config reads it.
if [[ $SKIP_BUILD -eq 0 ]]; then
  if [[ $RELATIVE -eq 1 ]]; then
    echo "==> building a relative book (placeholder baseUrl $BASE_URL, heap ${HEAP}MB)"
  else
    echo "==> building for baseUrl $BASE_URL only (heap ${HEAP}MB)"
  fi
  rm -rf "$OUT_DIR"

  # Overrides are applied by a generated wrapper config rather than by editing the
  # site's own. Docusaurus loads the config through its own transpiler, and that
  # transpiles the nested require too, so the wrapper can import the real config and
  # mutate the object - no textual patching, and nothing to change in the site repo.
  # Always generated, since it is also what sets baseUrl: not every site reads it
  # from the environment.
  RELATIVE_JS=$([[ $RELATIVE -eq 1 ]] && echo true || echo false)
  BUILD_CONFIG=".docusaurus2zim.config.js"
  trap 'rm -f "$ROOT/.docusaurus2zim.config.js"' EXIT
  cat > "$BUILD_CONFIG" <<WRAPPER
// Generated by docusaurus2zim. Safe to delete.
const base = require("./docusaurus.config.js");
const config = base.default ?? base;

config.baseUrl = "${BASE_URL}";
// A relative book is served under a mount point it was never built for, which is what
// this banner checks for. relativize.mjs makes the routes right, so it would misfire.
if (${RELATIVE_JS}) config.baseUrlIssueBanner = false;

// Analytics cannot reach anything from a ZIM, and only leaves 404s behind: drop the
// plugins, whether listed directly or switched on through the classic preset.
const ANALYTICS = /plugin-(vercel-analytics|google-gtag|google-analytics|google-tag-manager)/;
const pluginName = (p) => String(Array.isArray(p) ? p[0] : p);
config.plugins = (config.plugins ?? []).filter((p) => !ANALYTICS.test(pluginName(p)));
for (const preset of config.presets ?? []) {
  if (Array.isArray(preset) && preset[1]) {
    for (const k of ["gtag", "googleAnalytics", "googleTagManager"]) delete preset[1][k];
  }
}

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
  echo "==> using generated config ($BUILD_CONFIG)"

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

# ------------------------------------------------- absolute self-links
# Docs imported from other repos link back to the site by its full URL, which
# leaves the book. Anything that resolves inside the build is made relative; the
# rest is listed, since a self-link with no page behind it is stale on the live
# site too. The site URL is read from the canonical link, so nothing to configure.
python3 - "$OUT_DIR" "$BASE_URL" "$WELCOME" <<'SELF'
import os, re, sys
from urllib.parse import unquote

out_dir, base_url, welcome = sys.argv[1], sys.argv[2], sys.argv[3]
base = "/" + base_url.strip("/") + "/" if base_url.strip("/") else "/"
home = open(os.path.join(out_dir, welcome), encoding="utf-8", errors="replace").read()
m = re.search(r'rel=["\']?canonical["\']?\s+href=["\']?(https?://[^"\'\s>]+)', home)
site = m.group(1)[: -len(base)] if m and m.group(1).endswith(base) else None
if not site:
    print("==> self-links: no canonical URL on the welcome page, skipping")
    sys.exit(0)

def resolves(path):
    """A route ("docs/x/"), a file, or a route without its slash."""
    rel = unquote(path.split("#")[0].split("?")[0]).strip("/")
    if not rel:
        return True
    full = os.path.join(out_dir, rel)
    return os.path.isfile(full) or os.path.isfile(os.path.join(full, "index.html"))

host = re.sub(r"^https?://", "", site)
link = re.compile(
    r'(?<=[="\'(])https?://' + re.escape(host)
    + r'(?:(' + re.escape(base) + r'|/)([^"\'\s>)]*))?(?=["\'\s>)])'
)
rewritten, files = 0, 0
missing = {}
for d, _, names in os.walk(out_dir):
    for n in names:
        if not n.endswith((".html", ".js", ".css", ".xml")):
            continue
        path = os.path.join(d, n)
        text = open(path, encoding="utf-8", errors="replace").read()
        def sub(mm):
            global rewritten
            rest = mm.group(2) or ""
            if not resolves(rest):
                missing.setdefault(rest, os.path.relpath(path, out_dir))
                return mm.group(0)
            rewritten += 1
            return base + rest
        new = link.sub(sub, text)
        if new != text:
            open(path, "w", encoding="utf-8").write(new)
            files += 1
print(f"==> self-links: {rewritten} made relative in {files} files ({site})")
if missing:
    print(f"==> self-links: {len(missing)} left absolute, no page in the build:")
    for target, where in sorted(missing.items())[:20]:
        print(f"      /{target}   <- {where}")
SELF

# ------------------------------------------------------------- relative paths
# Last of the content rewrites: everything above writes paths under $BASE_URL, and
# this turns the placeholder into relative paths and a mount point found at load time.
if [[ $RELATIVE -eq 1 ]]; then
  node "$(cd "$(dirname "$0")" && pwd)/relativize.mjs" "$OUT_DIR"
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
# The same package.py either way; only where it runs, and so how paths are spelled, differs.
if [[ $NO_DOCKER -eq 1 ]]; then
  PACKAGE=("$PYTHON" "$(cd "$(dirname "$0")" && pwd)/package.py" --config "$CONFIG_ABS")
  W="$ROOT"
else
  PACKAGE=(docker run --rm --user "$(id -u):$(id -g)"
    -v "$ROOT:/work" -v "$CONFIG_ABS:/config.json:ro" -w /work "$PACKAGE_IMAGE"
    --config /config.json)
  W=/work
fi
"${PACKAGE[@]}" \
  --build-dir "$W/$OUT_DIR" \
  --output "$W/$ZIM_FILE" \
  --redirects "$W/$REDIRECTS" \
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
