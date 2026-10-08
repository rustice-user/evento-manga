// Gera dist/function.zip (index.mjs) para o deploy na Neon Function.  Uso: node build.mjs
import { build } from 'esbuild';
import { readFile, rm, mkdir, writeFile } from 'node:fs/promises';
import { execSync } from 'node:child_process';

await rm('dist', { recursive: true, force: true });
await mkdir('dist');

// HTML importado como texto, sem indentação (bundle menor; quebras de linha preservadas).
const htmlText = {
  name: 'html-text',
  setup(b) {
    b.onLoad({ filter: /\.html$/ }, async (args) => ({
      contents: (await readFile(args.path, 'utf8')).replace(/^[ \t]+/gm, ''),
      loader: 'text',
    }));
  },
};

await build({
  entryPoints: ['src/index.js'], bundle: true, platform: 'node', target: 'node24', format: 'esm',
  minify: true, outfile: 'dist/index.mjs', plugins: [htmlText],
});
execSync('zip -q -9 -j dist/function.zip dist/index.mjs');
const zip = await readFile('dist/function.zip');
await writeFile('dist/function.zip.b64', zip.toString('base64'));
console.log(`dist/function.zip: ${zip.length} bytes (base64 ${Math.ceil(zip.length / 3) * 4})`);
