Example site configurations. Copy one into your site repo as `docusaurus2zim.json`, or leave
it here and point `DOCUSAURUS2ZIM_CONFIG` at it. Both leave `base_url` empty, which builds a
relative book that works at any mount point; see "The base URL" in the main README.

## mermaid.json — a VitePress site, not Docusaurus

`build.sh` does not apply (its build half is Docusaurus-specific), but `relativize.mjs` and
`package.py` do. VitePress bakes its `base` in the same way Docusaurus bakes `baseUrl`, so the
site is built with the same placeholder and made relative the same way. Built from mermaid
`develop` @ 56219a3 (mermaid 11.16.0, matching the live editor):

```sh
cd packages/mermaid
pnpm --filter ./src/docs prefetch
npx typedoc --skipErrorChecking src/defaultConfig.ts src/config.ts src/mermaid.ts   # docs:code, minus the typecheck that fails on this checkout
npx prettier --write ./src/docs/config/setup
rm -rf src/vitepress && npx tsx scripts/docs.cli.mts --vitepress
pnpm --filter ./src/vitepress install --no-frozen-lockfile --ignore-scripts
cd src/vitepress
# Optional, for tight memory: render 8 pages at a time rather than 64. The generated
# config is recreated by the docs.cli step above, so this is redone after it.
sed -i "s|^  base: '/',|  base: '/',\n  buildConcurrency: 8,|" .vitepress/config.ts
NODE_OPTIONS=--max-old-space-size=3500 npx vitepress build --base /__d2z_root__/
node /path/to/docusaurus2zim/relativize.mjs .vitepress/dist   # from src/vitepress, where it finds acorn
# Python 3.14 with requirements.txt, e.g. the micromamba env in the main README:
python3 /path/to/docusaurus2zim/package.py --config /path/to/docusaurus2zim/examples/mermaid.json \
  --build-dir .vitepress/dist --output mermaid-docs.zim
```

Result (2026-09-29): 654 pages → 11 MB ZIM, 2157 items, relative. `relativize.mjs` rewrote
all 654 pages and 574 strings in 565 scripts, with nothing left over. Checked in a browser
with the book served at both `/content/mermaid-docs/` and `/wiki/content/mermaid-docs/`:
diagrams render client-side from the bundled mermaid (112 on the flowchart page), sidebar
navigation works, and the site's FlexSearch box returns results offline. There were no
failed requests and no page errors. VitePress's default `cleanUrls: false` is what makes the
`.html` paths line up with the ones the live editor links to; do not turn it on for this
site.

**Memory.** The build peaks at about 4.2 GB (3.3 GB resident plus swap). It happens while
Vite bundles the server-side copy of all 654 pages together with Mermaid's own source, not
while rendering, so `buildConcurrency` barely changes it. In a 6 GB WSL with VS Code open,
that fills swap completely. Close other things, or give WSL more memory. Every page also
logs one `ReferenceError: window is not defined` from a shared component during
server-side rendering; the pages are complete regardless.
