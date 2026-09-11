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

- **baseUrl.** A reader mounts a book under a URL prefix, and a Docusaurus site is a single-page
  app: rewriting built HTML is not enough, because the router re-renders every link from its own
  absolute routes once it hydrates. The site is built with `baseUrl` set to the serving prefix.
- **Entries, not directories.** A ZIM resolves entries, so every `page/` needs a redirect to
  `page/index.html`.
- **Both slash forms.** Raw HTML in MDX and in config strings bypasses `trailingSlash`, so pages
  are also reachable without the trailing slash — and, in the other direction, `trailingSlash`
  decorates *asset* links too, so `file.pdf/` redirects to `file.pdf`. A live site has a server
  to paper over both; a ZIM does not.
- **External images.** Assets served from another host are copied in and their URLs re-pointed,
  including the bare directory prefix, because components build image URLs from it at runtime.
- **Stray root-absolute assets.** Raw paths inside React components miss `baseUrl` and are
  re-pointed.
- **Pruning and exclusion.** Unreferenced files under chosen prefixes are never added; glob
  patterns drop anything else. Nothing is deleted from the build directory.
- **PDF full text**, via `zimscraperlib`'s pymupdf integration.
- **Verification.** `--verify` serves the result and probes every internal reference on a sample
  of pages, failing on any break.

## Usage

From the root of a Docusaurus site containing a `docusaurus2zim.json`:

```sh
docker build -t docusaurus2zim:latest /path/to/docusaurus2zim
/path/to/docusaurus2zim/build.sh --verify
```

```
build.sh                build and package
build.sh --verify       also serve and probe every internal link
build.sh --skip-build   repackage an existing out-dir
build.sh --serve        serve the result on :8081
```

The config need not live in the site repo — point at one anywhere:

```sh
DOCUSAURUS2ZIM_CONFIG=/path/to/docusaurus2zim/examples/meshtastic.json \
  /path/to/docusaurus2zim/build.sh --verify
```

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
    "index_selector": "main",
    "prune_prefixes": "design/,documents/",
    "exclude": "",
    "asset_prefixes": "/img/",
    "mirror_hosts": "",
    "only_current_version": true
  }
}
```

Every key is also a command-line flag, which takes precedence.

`only_current_version` sets `DOCS_ONLY_CURRENT` for the build; the site's
`docusaurus.config.js` decides what to do with it, e.g.:

```js
...(process.env.DOCS_ONLY_CURRENT ? { onlyIncludeVersions: ["current"] } : {}),
```

`prune_prefixes` and `exclude` answer different questions. Pruning asks *"is anything
referencing this?"*; exclusion asks *"do we want this?"*. Prefer pruning for content that is
merely unlinked — a glob that removes a file some page links to will strand that link, and
`--verify` will say so.

## Requirements

Docker, and Node for the Docusaurus build itself. The packaging step runs entirely in the
container, so no local Python, `libmagic` or `libzim` is needed.

## Status

Extracted from a working pipeline for the Meshtastic documentation site, where it produces a
98 MB book from a 257 MB build with zero broken references. Interfaces may still move.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).
