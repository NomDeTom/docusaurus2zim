// Make a Docusaurus build work at any mount point, the way openZIM books do.
//
// The site is built with baseUrl set to a placeholder (ROOT below), so every place the
// mount point was baked in can be found afterwards:
//
//   HTML, CSS    the placeholder becomes a relative path from that file ("../../").
//   JavaScript   the router's routes, component links and webpack's public path need
//                the real mount point, since they are used from every page. Each string
//                holding the placeholder becomes an expression that fills it in at load
//                time, from globalThis.__D2Z_ROOT__. That needs a real parser: some of
//                those strings are object keys, where an expression is not valid.
//   every page   gets a first script that sets __D2Z_ROOT__ to its relative path
//                resolved against its own address: the book finds its own mount point.
//
// Absolute URLs that carried the placeholder (canonical links, the sitemap) get the
// site's real root back. Anything still holding the placeholder afterwards is listed.
//
// Run from the site root, which is how acorn is found: through @docusaurus/core's
// webpack, which every Docusaurus site has.
//
//   node relativize.mjs <out-dir>

import fs from "node:fs";
import path from "node:path";
import { createRequire } from "node:module";

export const ROOT = "/__d2z_root__/";

const outDir = path.resolve(process.argv[2] ?? "build-zim");
// acorn, from the site's own install: never a direct dependency, but always one step
// behind the site's bundler. Each entry is a chain of packages to resolve through.
function findAcorn() {
  const routes = [
    [],                                  // hoisted, or a direct dependency
    ["@docusaurus/core", "webpack"],     // Docusaurus
    ["vitepress", "vite", "terser"],     // VitePress: vite's minifier uses acorn
    ["vite", "terser"],
    ["webpack"],
  ];
  for (const chain of routes) {
    try {
      let req = createRequire(path.join(process.cwd(), "package.json"));
      for (const pkg of chain) req = createRequire(req.resolve(`${pkg}/package.json`));
      return req("acorn");
    } catch {}
  }
  throw new Error("relativize: no acorn found through the site's install (run it from the site root)");
}
const acorn = findAcorn();

const TEXT = /\.(html|css|js|mjs|json|xml|txt|svg|webmanifest)$/;
// "https://site/__d2z_root__/x" -> "https://site/x": absolute URLs keep the real root.
const ABSOLUTE = /(https?:\/\/[A-Za-z0-9.-]+(?::\d+)?)\/__d2z_root__\//g;
// The placeholder at the start of a path: not preceded by anything that could be part
// of a URL, so "https://site/__d2z_root__/" (handled above) is never touched here.
const LEADING = /(?<![\w.:/%-])\/__d2z_root__\//g;
// The runtime root, as an expression. Outside a page (a worker) it falls back to "/".
const RUNTIME = '(globalThis.__D2Z_ROOT__||"/")';
// The placeholder as the rewrite's own split() argument: the same string value, spelled
// with escaped slashes so neither the leftover check nor a second pass sees it.
const MARK = '"\\/__d2z_root__\\/"';

function* walk(dir) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) yield* walk(p);
    else yield p;
  }
}

// The relative path from a file's directory back to the book root: "", "../", "../../".
// A page is stored at its route and served as "route/", so its directory is its depth.
function upFrom(file) {
  const rel = path.relative(outDir, path.dirname(file));
  return rel ? "../".repeat(rel.split(path.sep).length) : "./";
}

function rootScript(prefix) {
  return `<script>globalThis.__D2Z_ROOT__=new URL(${JSON.stringify(prefix)},location.href).pathname</script>`;
}

// --- JavaScript ---------------------------------------------------------------------

function parse(src) {
  const opts = { ecmaVersion: "latest", allowHashBang: true, allowReturnOutsideFunction: true };
  try { return acorn.parse(src, { ...opts, sourceType: "script" }); }
  catch { return acorn.parse(src, { ...opts, sourceType: "module" }); }
}

// Every node, with its parent and the key it sits under.
function visit(node, parent, key, fn) {
  if (!node || typeof node.type !== "string") return;
  fn(node, parent, key);
  for (const k of Object.keys(node)) {
    const v = node[k];
    if (Array.isArray(v)) v.forEach((c) => visit(c, node, k, fn));
    else if (v && typeof v.type === "string") visit(v, node, k, fn);
  }
}

const KEYED = new Set(["Property", "MethodDefinition", "PropertyDefinition"]);

function rewriteJs(src) {
  if (!src.includes(ROOT)) return { out: src, n: 0 };
  const ast = parse(src);
  const edits = [];
  visit(ast, null, null, (node, parent, key) => {
    if (node.type === "Literal" && typeof node.value === "string" && node.value.includes(ROOT)) {
      const raw = src.slice(node.start, node.end);
      // An earlier pass's marker, or a string it already wrapped: the placeholder in
      // those is meant to stay, and is filled in at load time.
      if (raw === MARK || src.startsWith(`.split(${MARK})`, node.end)) return;
      const expr = `${raw}.split(${MARK}).join(${RUNTIME})`;
      // An object key cannot be an expression unless it is a computed key.
      const isKey = parent && KEYED.has(parent.type) && key === "key" && !parent.computed;
      edits.push([node.start, node.end, isKey ? `[${expr}]` : `(${expr})`]);
      if (isKey && parent.shorthand) throw new Error("shorthand property with a string key");
    } else if (node.type === "TemplateElement" && node.value.raw.includes(ROOT)) {
      const raw = src.slice(node.start, node.end);
      edits.push([node.start, node.end, raw.split(ROOT).join("${" + RUNTIME + "}")]);
    }
  });
  let out = src;
  for (const [s, e, r] of edits.sort((a, b) => b[0] - a[0])) out = out.slice(0, s) + r + out.slice(e);
  parse(out); // the rewrite must still be valid JavaScript
  return { out, n: edits.length };
}

// --- the pass -----------------------------------------------------------------------

const stats = { html: 0, other: 0, js: 0, jsStrings: 0, absolute: 0 };
const leftovers = [];

for (const file of walk(outDir)) {
  if (!TEXT.test(file)) continue;
  let text = fs.readFileSync(file, "utf8");
  const before = text;

  text = text.replace(ABSOLUTE, (_, site) => { stats.absolute++; return `${site}/`; });

  let unwrapped = 0; // JavaScript strings still holding the placeholder unwrapped
  if (file.endsWith(".html")) {
    const up = upFrom(file);
    // Markup gets relative paths; inline scripts get the runtime root, like the bundles,
    // since a relative path is wrong inside code that builds URLs from it. (JSON data
    // blocks are markup here: nothing evaluates them as code.)
    const SCRIPT = /(<script\b[^>]*>)([\s\S]*?)(<\/script>)/g;
    let out = "", last = 0;
    for (const m of text.matchAll(SCRIPT)) {
      out += text.slice(last, m.index).replace(LEADING, up);
      const [, tag, body, close] = m;
      const open = tag.replace(LEADING, up); // the tag is markup: <script src=...>
      if (/type=["']?application\/(ld\+)?json/.test(tag)) out += open + body.replace(LEADING, up) + close;
      else {
        const js = rewriteJs(body);
        out += open + js.out + close;
        unwrapped += rewriteJs(js.out).n;
      }
      last = m.index + m[0].length;
    }
    text = out + text.slice(last).replace(LEADING, up);
    // Every page, since the bundles it loads read __D2Z_ROOT__; once, so a second
    // pass over the same out-dir (--skip-build) changes nothing.
    if (!text.includes("globalThis.__D2Z_ROOT__=new URL(")) {
      text = text.replace(/<head\b[^>]*>/, (h) => h + rootScript(up));
    }
    if (text !== before) stats.html++;
  } else if (/\.m?js$/.test(file)) {
    const { out, n } = rewriteJs(text);
    if (n) { text = out; stats.js++; stats.jsStrings += n; }
    unwrapped += rewriteJs(text).n;
  } else if (text.includes(ROOT)) {
    // Stylesheets, feeds (blog/rss.xml, atom.xml), opensearch.xml, JSON, SVG: nothing
    // runs them as page code, and each resolves its paths against its own address.
    text = text.replace(LEADING, upFrom(file));
    stats.other++;
  }

  // In JavaScript the placeholder stays inside wrapped strings, by design: what counts
  // is a string a pass would still wrap. Everywhere else, any occurrence is a miss.
  const html = file.endsWith(".html");
  // Script bodies are checked as JavaScript above; their tags are markup and count here.
  const markup = html
    ? text.replace(/(<script\b(?![^>]*application\/(?:ld\+)?json)[^>]*>)[\s\S]*?(<\/script>)/g, "$1$2")
    : text;
  const missed = /\.m?js$/.test(file) ? unwrapped > 0 : (markup.includes(ROOT) || unwrapped > 0);
  if (missed) leftovers.push(path.relative(outDir, file));
  if (text !== before) fs.writeFileSync(file, text);
}

console.log(
  `==> relative paths: ${stats.html} pages, ${stats.other} stylesheets and other files, ` +
  `${stats.js} scripts (${stats.jsStrings} strings made runtime), ` +
  `${stats.absolute} absolute URLs given the real root`,
);
if (leftovers.length) {
  console.log(`==> relative paths: ${leftovers.length} files still hold ${ROOT}:`);
  for (const f of leftovers.slice(0, 20)) console.log(`      ${f}`);
  process.exitCode = 1;
}
