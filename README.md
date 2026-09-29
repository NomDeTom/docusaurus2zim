# docusaurus2zim

Build a [Docusaurus](https://docusaurus.io) site into a [Kiwix](https://kiwix.org) ZIM for
offline reading.

Docusaurus already produces a complete static site — its own theme, navigation, versioning and
React components. This packages that build as-is, rather than scraping the site and rendering it
through a replacement UI. What it adds is the ZIM-specific knowledge the static build has no
reason to have.

## Why not `zimwriterfs`

`zimwriterfs` packs a directory and, in its own README's words, does "nothing more, nothing
less". Its only indexing control is all-or-nothing (`--withoutFTIndex`), and `getIndexData`
appears nowhere in its sources — so libzim's default HTML indexer runs on every item. That means
every page's chrome is indexed: on one real site, searching the word in the footer copyright
matched **all 746 pages**.

This uses [`zimscraperlib`](https://github.com/openzim/python-scraperlib) instead and attaches
per-item index data, so only the text inside a chosen CSS selector is indexed. On that same site
the figure went from 746 to 7 — and the 7 are pages that genuinely discuss the term.

## What it handles

- **Relative paths, so a book works at any mount point.** A reader mounts a book under a URL
  prefix that differs between Kiwix at a server's root, Kiwix under a prefix, and the desktop
  and mobile readers. openZIM books cope by linking relatively, and so do these, which takes
  more work for a Docusaurus site than for static HTML. See [The base URL](#the-base-url).
- **Analytics removed.** Vercel, Google gtag, Google Analytics and Google Tag Manager plugins
  are dropped from the build: they cannot reach anything offline and only leave 404s.
- **Pages live at their route.** `page/index.html` is stored as the entry `page/`, with the
  file name redirecting to it. The client router only knows the route: a redirect the other way
  round is a 302 to a URL it cannot match, and the page hydrates into the site's own not-found.
- **Both slash forms.** Raw HTML in MDX and in config strings bypasses `trailingSlash`, so pages
  are also reachable without the trailing slash — and, in the other direction, `trailingSlash`
  decorates *asset* links too, so `file.pdf/` redirects to `file.pdf`. A live site has a server
  to paper over both; a ZIM does not.
- **External images.** Assets served from another host are copied in and their URLs re-pointed,
  including the bare directory prefix, because components build image URLs from it at runtime.
- **Stray root-absolute assets.** Raw paths inside React components miss `baseUrl` and are
  re-pointed.
- **Absolute self-links.** Pages imported from other repos link back to the site by its full
  URL. Those that resolve inside the build are made relative; the rest are listed, since a
  self-link with no page behind it is stale on the live site too.
- **Pruning and exclusion.** Unreferenced files under chosen prefixes are never added; glob
  patterns drop anything else. Nothing is deleted from the build directory. A static image that
  Docusaurus has already copied to `assets/` under a hashed name counts as unreferenced when its
  only mention is in a page's raw source, so `img/` can be pruned without losing anything.
- **Cover.** `zim-illustration.png` in the build directory if the site ships one; otherwise the
  favicon the main page declares, rendered to 48x48 (SVG, PNG, ICO); otherwise a flat square.
- **PDF full text**, via `zimscraperlib`'s pymupdf integration.
- **Verification.** `--verify` serves the result and probes every internal reference on a sample
  of pages, failing on any break.

## Usage

From the root of a Docusaurus site containing a `docusaurus2zim.json`, with the site's own
dependencies installed and current (`pnpm install`, `npm ci` or `yarn`, whichever the site
uses). A `node_modules` older than the site's `package.json` fails inside the Docusaurus
build with a "Cannot find module" error for a plugin, which looks like a docusaurus2zim
problem but is not.

```sh
docker build -t docusaurus2zim:latest /path/to/docusaurus2zim
/path/to/docusaurus2zim/build.sh --verify
```

```
build.sh                build and package
build.sh --verify       also serve and probe every internal link on a sample of pages
build.sh --skip-build   repackage an existing out-dir
build.sh --serve        serve the result on :8081
build.sh --no-docker    package with a local Python instead of the container
build.sh --help         every option, with its current default
```

The other options are `--name`, `--title`, `--base-url`, `--out-dir`, `--zim-dir`,
`--heap`, `--mirror-hosts`, `--asset-prefixes` and `--verify-ignore`. `--help` works
anywhere, even outside a site repo.

The config need not live in the site repo — point at one anywhere:

```sh
DOCUSAURUS2ZIM_CONFIG=/path/to/docusaurus2zim/examples/meshtastic.json \
  /path/to/docusaurus2zim/build.sh --verify
```

The build goes to `build-zim/` and the book to `zim-out/<name>.zim`, both in the site repo.
Add them to its `.gitignore`, or pass `--out-dir` and `--zim-dir` to put them elsewhere.

| Environment variable | Default | Meaning |
|---|---|---|
| `DOCUSAURUS2ZIM_CONFIG` | `docusaurus2zim.json` | the site config to use |
| `DOCUSAURUS2ZIM_IMAGE` | `docusaurus2zim:latest` | the packaging image |
| `DOCUSAURUS2ZIM_PYTHON` | `python3` | the interpreter for `--no-docker` |
| `ZIM_BUILD_HEAP` | `1800` | Node heap cap for the Docusaurus build, in MB (same as `--heap`) |

## The base URL

Docusaurus bakes `baseUrl` into the build in three places. It is in the pre-rendered HTML.
It is in the router's routes and the links compiled into React components, which the router
compares with the full page address once the page hydrates. And it is in webpack's path for
loading the rest of the scripts. A plain Docusaurus build therefore works at one mount point
only; anywhere else, every page shows "Your Docusaurus site did not load properly".

**By default the book is relative, and works at any mount point.** The site is built with
a placeholder `baseUrl`, and `relativize.mjs` replaces it everywhere:

- in HTML, CSS, feeds and other files, with a path relative to that file (`../../`);
- in JavaScript, where a relative path cannot work, because the routes are used from every
  page: each string holding the placeholder is rewritten, with a real parser (some are object
  keys), to fill in the mount point at load time;
- on every page, a first script finds that mount point by resolving the page's relative path
  against its own address.

Canonical and sitemap URLs get the site's real root back. Any file still holding the
placeholder is listed, and the build stops there. Docusaurus's own base-URL banner is turned
off, since the book is always served under a mount point it was not built for. The
Meshtastic docs, built once, work under both `/content/<name>/` (kiwix-serve at a server's
root) and `/wiki/content/<name>/` (the Irate-Box hub).

**`--base-url` builds for one mount point instead**, the old behaviour, if you want it. The
book then works at that prefix only. If you do, ignore the path the banner suggests:
Docusaurus makes it by adding a slash to the current address.

## Configuration

Values live in the site's `docusaurus2zim.json`; the flag *declarations* live in this repo's
`offliner-definition.json`, following the openZIM
[Zimfarm](https://github.com/openzim/zimfarm) offliner contract so the same surface can be driven
by a farm later.

```json
{
  "defaults": {
    "name": "example-docs",
    "title": "Example Documentation",
    "description": "Example documentation, offline",
    "language": "eng",
    "creator": "Example",
    "publisher": "Example",
    "base_url": "",
    "index_selector": "main",
    "prune_prefixes": "design/,documents/",
    "exclude": "",
    "asset_prefixes": "/img/",
    "mirror_hosts": "",
    "only_current_version": true,
    "docusaurus_overrides": {}
  }
}
```

Every key is also a command-line flag, which takes precedence.

### Overriding the site's Docusaurus config

**The site repo needs no changes.** Overrides are applied by a wrapper config generated at build
time and passed to `docusaurus build --config`. The wrapper `require`s the real config and mutates
the object — Docusaurus loads configs through its own transpiler, and that covers the nested
require, so this works even for a config that mixes CJS and ESM and cannot be loaded by plain
Node. No textual patching, and nothing left behind: the wrapper is removed on exit.

`only_current_version: true` drops archived documentation versions, setting
`onlyIncludeVersions: ["current"]` on whichever preset or plugin carries the docs options, and
trimming `versions` to match — leaving config for an excluded version behind trips Docusaurus
validation.

For anything else, `docusaurus_overrides` takes dotted paths into the config object:

```json
"docusaurus_overrides": {
  "themeConfig.algolia": null,
  "themeConfig.footer.copyright": ""
}
```

`prune_prefixes` and `exclude` answer different questions. Pruning asks *"is anything
referencing this?"*; exclusion asks *"do we want this?"*. Prefer pruning for content that is
merely unlinked — a glob that removes a file some page links to will strand that link, and
`--verify` will say so.

## Requirements

Node, for the Docusaurus build itself, and one of the two ways to package it:

- **Docker** (the default). The packaging step runs in the image, so no local Python,
  `libmagic` or `libzim` is needed. `--serve` and `--verify` also need Docker, for
  `kiwix-serve`.
- **A local Python, with `--no-docker`.** The pinned `zimscraperlib` needs Python 3.14, plus
  `libmagic` and `libcairo`. A micromamba (or conda) env provides all three:

  ```sh
  micromamba create -n zim -c conda-forge python=3.14 cairo libmagic pip
  ~/micromamba/envs/zim/bin/pip install -r /path/to/docusaurus2zim/requirements.txt
  DOCUSAURUS2ZIM_PYTHON=~/micromamba/envs/zim/bin/python \
    /path/to/docusaurus2zim/build.sh --no-docker
  ```

## Known limitations

- **`--verify` checks links, not hydration.** It reads `href` and `src` in the HTML the
  server returns, on the main page and 12 others. A link that only exists once the
  JavaScript runs gets through.
- **`--serve` and `--verify` check `/content/<name>/` only.** That is fine for a relative book,
  which works there as it does anywhere. A `--base-url` book has to be checked on the server
  it was built for.
- **Stray root-absolute assets are only fixed under `asset_prefixes`.** These are raw paths
  written into React components without the base URL, so they never held the placeholder
  either. A path under any other prefix is left pointing outside the book, and is not
  reported.
- **JavaScript outside the page**, such as a service worker, has no page address to find the
  mount point from, and falls back to `/`. Docusaurus sites rarely ship one.
- `--serve` and `--verify` are refused with `--no-docker`.

## Status

Extracted from a working pipeline for the Meshtastic documentation site. The 2026-09-29 build
of the current docs (2.8 only) is a 58 MB book of 1,520 items and 1,942 redirects, with
172.7 MB of unreferenced files pruned. It was packaged with `--no-docker` and checked in a
browser under `/wiki` on the Irate-Box hub. Interfaces may still move.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).
