// Bundles injected.ts (against Playwright's sources in ./playwright) and record.ts into
// IIFE scripts in ./out. Run by apple/scripts/build-agent-browser.sh.
import fs from 'node:fs';
import path from 'node:path';
import esbuild from 'esbuild';

const here = path.dirname(new URL(import.meta.url).pathname);
const pw = path.join(here, 'playwright', 'packages');

// Playwright imports its overlay CSS as text (`highlight.css?inline`).
const inlineCSS = {
  name: 'inline-css',
  setup(build) {
    build.onLoad({ filter: /\.css$/ }, async args => {
      const css = await esbuild.transform(await fs.promises.readFile(args.path), { loader: 'css', minify: true });
      return { loader: 'text', contents: css.code };
    });
  },
};

const alias = {
  '@injected': path.join(pw, 'injected', 'src'),
  '@isomorphic': path.join(pw, 'isomorphic'),
  '@protocol': path.join(pw, 'protocol', 'src'),
};

const common = { bundle: true, format: 'iife', platform: 'browser', target: 'safari17', minify: true, legalComments: 'none', logLevel: 'warning' };

await esbuild.build({
  ...common,
  entryPoints: [path.join(here, 'injected.ts')],
  outfile: path.join(here, 'out', 'playwright-injected.js'),
  alias,
  plugins: [inlineCSS],
  tsconfigRaw: { compilerOptions: { useDefineForClassFields: false } },
});
await esbuild.build({
  ...common,
  entryPoints: [path.join(here, 'record.ts')],
  outfile: path.join(here, 'out', 'rrweb-record.js'),
});
