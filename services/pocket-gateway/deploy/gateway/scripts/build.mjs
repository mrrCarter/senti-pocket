import { build } from 'esbuild';
import { mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { deflateRawSync } from 'node:zlib';

const OUTPUT_DIR = new URL('../dist/', import.meta.url);
const BUNDLE_URL = new URL('../dist/index.mjs', import.meta.url);
const ZIP_URL = new URL('../dist/gateway.zip', import.meta.url);
const ZIP_ENTRY_NAME = Buffer.from('index.mjs', 'utf8');

function crc32(bytes) {
  let crc = 0xffffffff;
  for (const byte of bytes) {
    crc ^= byte;
    for (let bit = 0; bit < 8; bit += 1) {
      crc = (crc >>> 1) ^ (0xedb88320 & -(crc & 1));
    }
  }
  return (crc ^ 0xffffffff) >>> 0;
}

function deterministicSingleFileZip(name, contents) {
  const compressed = deflateRawSync(contents, { level: 9 });
  const checksum = crc32(contents);
  const flags = 0x0800;
  const method = 8;
  const dosTime = 0;
  const dosDate = 0x0021;

  const local = Buffer.alloc(30);
  local.writeUInt32LE(0x04034b50, 0);
  local.writeUInt16LE(20, 4);
  local.writeUInt16LE(flags, 6);
  local.writeUInt16LE(method, 8);
  local.writeUInt16LE(dosTime, 10);
  local.writeUInt16LE(dosDate, 12);
  local.writeUInt32LE(checksum, 14);
  local.writeUInt32LE(compressed.byteLength, 18);
  local.writeUInt32LE(contents.byteLength, 22);
  local.writeUInt16LE(name.byteLength, 26);

  const centralOffset = local.byteLength + name.byteLength + compressed.byteLength;
  const central = Buffer.alloc(46);
  central.writeUInt32LE(0x02014b50, 0);
  central.writeUInt16LE(0x0314, 4);
  central.writeUInt16LE(20, 6);
  central.writeUInt16LE(flags, 8);
  central.writeUInt16LE(method, 10);
  central.writeUInt16LE(dosTime, 12);
  central.writeUInt16LE(dosDate, 14);
  central.writeUInt32LE(checksum, 16);
  central.writeUInt32LE(compressed.byteLength, 20);
  central.writeUInt32LE(contents.byteLength, 24);
  central.writeUInt16LE(name.byteLength, 28);
  central.writeUInt32LE((0o100644 << 16) >>> 0, 38);

  const centralSize = central.byteLength + name.byteLength;
  const end = Buffer.alloc(22);
  end.writeUInt32LE(0x06054b50, 0);
  end.writeUInt16LE(1, 8);
  end.writeUInt16LE(1, 10);
  end.writeUInt32LE(centralSize, 12);
  end.writeUInt32LE(centralOffset, 16);

  return Buffer.concat([local, name, compressed, central, name, end]);
}

await rm(OUTPUT_DIR, { recursive: true, force: true });
await mkdir(OUTPUT_DIR, { recursive: true });

await build({
  absWorkingDir: fileURLToPath(new URL('..', import.meta.url)),
  entryPoints: ['index.mjs'],
  outfile: fileURLToPath(BUNDLE_URL),
  bundle: true,
  platform: 'node',
  format: 'esm',
  target: 'node22',
  charset: 'utf8',
  legalComments: 'none',
  sourcemap: false,
  minify: false,
  logLevel: 'info',
  banner: {
    js: "import { createRequire as __createRequire } from 'node:module'; const require = __createRequire(import.meta.url);",
  },
});

const bundle = await readFile(BUNDLE_URL);
await writeFile(ZIP_URL, deterministicSingleFileZip(ZIP_ENTRY_NAME, bundle));

const artifact = await import(BUNDLE_URL.href);
if (typeof artifact.handler !== 'function') {
  throw new Error('gateway artifact does not export handler');
}
