Example site configurations. Copy one into your site repo as `docusaurus2zim.json`.

## mermaid.json — a VitePress site, not Docusaurus

`build.sh` does not apply (its build half is Docusaurus-specific); only `package.py` is used.
Built 2026-09-22 from mermaid `develop` @ 56219a3 (mermaid 11.16.0, matching the live editor):

```sh
cd packages/mermaid
pnpm --filter ./src/docs prefetch
npx typedoc --skipErrorChecking src/defaultConfig.ts src/config.ts src/mermaid.ts   # docs:code, minus the typecheck that fails on this checkout
npx prettier --write ./src/docs/config/setup
rm -rf src/vitepress && npx tsx scripts/docs.cli.mts --vitepress
pnpm --filter ./src/vitepress install --no-frozen-lockfile --ignore-scripts
cd src/vitepress && NODE_OPTIONS=--max-old-space-size=3500 npx vitepress build --base /wiki/content/mermaid-docs/
python3 package.py --config examples/mermaid.json --build-dir src/vitepress/.vitepress/dist --output mermaid-docs.zim
```

Result: 654 pages, 101 MB build → 11 MB ZIM, 2157 items. Served by kiwix-serve, every
`syntax/<diagram>.html` resolves at the path the live editor links to, all assets resolve, and
full-text search hits the right pages. VitePress's default `cleanUrls: false` is what makes the
`.html` paths line up — do not turn it on for this site. Diagrams in the docs render client-side
from the bundled mermaid; confirmed in a browser, not by `--verify`.
