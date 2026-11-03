const assert = require("node:assert/strict");
const { fixRemarkRoutePaths } = require("../remark-route.cjs");

const glossary = function remarkGlossaryTerms() {};
const other = function remarkOther() {};

function site(routePath) {
  return {
    presets: [
      [
        "classic",
        {
          docs: {
            remarkPlugins: [
              [other, { routePath: "/other/" }],
              [glossary, { glossaryPath: "glossary/glossary.json", routePath }],
            ],
          },
        },
      ],
    ],
  };
}

// The relative book's placeholder is carried into a remark plugin's raw href.
let config = site("/docs/terms/");
assert.equal(fixRemarkRoutePaths(config, "/__d2z_root__/"), 2);
assert.equal(config.presets[0][1].docs.remarkPlugins[0][1].routePath, "/__d2z_root__/other/");
assert.equal(config.presets[0][1].docs.remarkPlugins[1][1].routePath, "/__d2z_root__/docs/terms/");

// A one-prefix build gets that prefix; a root build is already right.
config = site("/docs/terms/");
assert.equal(fixRemarkRoutePaths(config, "/content/x/"), 2);
assert.equal(config.presets[0][1].docs.remarkPlugins[1][1].routePath, "/content/x/docs/terms/");
config = site("/docs/terms/");
assert.equal(fixRemarkRoutePaths(config, "/"), 0);
assert.equal(config.presets[0][1].docs.remarkPlugins[1][1].routePath, "/docs/terms/");

// Already carrying baseUrl, or routePath: null (the plugin registers no route), is left alone.
config = site("/content/x/docs/terms/");
assert.equal(fixRemarkRoutePaths(config, "/content/x/"), 1);
assert.equal(config.presets[0][1].docs.remarkPlugins[1][1].routePath, "/content/x/docs/terms/");
config = site(null);
assert.equal(fixRemarkRoutePaths(config, "/content/x/"), 1);
assert.equal(config.presets[0][1].docs.remarkPlugins[1][1].routePath, null);

// Docs options listed directly, rather than through a preset, are found too.
config = {
  plugins: [["plugin-content-docs", { remarkPlugins: [[glossary, { routePath: "/terms/" }]] }]],
};
assert.equal(fixRemarkRoutePaths(config, "/content/x/"), 1);
assert.equal(config.plugins[0][1].remarkPlugins[0][1].routePath, "/content/x/terms/");

console.log("remark-route: all checks passed");
