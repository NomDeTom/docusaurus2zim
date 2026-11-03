// A remark plugin option named routePath is often written straight into an <a href>
// (docusaurus-plugin-glossary does this in its GlossaryTerm component), rather than
// through Docusaurus's Link or useBaseUrl. A route such as "/docs/terms/" therefore
// stays root-absolute, and in a book mounted under /wiki/content/<name>/ it points
// outside the book. Carry the build's baseUrl into those options, so a relative
// book's placeholder reaches relativize.mjs, and a --base-url build has the prefix.
//
// Only remarkPlugins options are changed: a plugin's own routePath registers a
// Docusaurus route, which must stay a route, not a baseUrl path.

function fixRemarkRoutePaths(config, baseUrl) {
  if (typeof baseUrl !== "string" || !baseUrl) return 0;
  if (baseUrl[baseUrl.length - 1] !== "/") baseUrl += "/";
  const seen = new Set();
  let fixed = 0;

  function fixEntry(entry) {
    if (!Array.isArray(entry)) return;
    const options = entry[1];
    if (!options || typeof options !== "object") return;
    const route = options.routePath;
    // null means a route is deliberately not registered, and a relative path is not
    // ours to reinterpret: carry only root-absolute routes.
    if (typeof route !== "string" || route[0] !== "/" || route.startsWith(baseUrl)) return;
    options.routePath = baseUrl + route.replace(/^\/+/, "");
    fixed++;
  }

  function visit(node) {
    if (!node || typeof node !== "object" || seen.has(node)) return;
    seen.add(node);
    if (Array.isArray(node)) {
      for (const item of node) visit(item);
      return;
    }
    if (Array.isArray(node.remarkPlugins)) {
      for (const entry of node.remarkPlugins) fixEntry(entry);
    }
    for (const key of Object.keys(node)) visit(node[key]);
  }

  visit(config);
  return fixed;
}

module.exports = { fixRemarkRoutePaths };
