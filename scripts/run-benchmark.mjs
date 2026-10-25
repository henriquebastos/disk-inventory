import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { performance } from 'node:perf_hooks';

const [binaryArg, root, outputArg, resume] = process.argv.slice(2);
if (!binaryArg || !root || !outputArg || (resume && resume !== '--resume') || process.argv.length > 6) {
  throw new Error('Usage: node run-benchmark.mjs BINARY ABSOLUTE_ROOT OUTPUT_DIRECTORY [--resume]');
}
if (!path.isAbsolute(root)) throw new Error('ROOT must be absolute');
const binary = fs.realpathSync(binaryArg);
const output = path.resolve(outputArg);
const manifest = {
  version: 1,
  root,
  binarySha256: crypto.createHash('sha256').update(fs.readFileSync(binary)).digest('hex'),
};
const manifestPath = path.join(output, 'manifest.json');
if (resume) {
  if (JSON.stringify(JSON.parse(fs.readFileSync(manifestPath, 'utf8'))) !== JSON.stringify(manifest)) {
    throw new Error('Resume requires the same root, executable and benchmark version');
  }
} else {
  fs.mkdirSync(output, { mode: 0o700 });
  fs.writeFileSync(manifestPath, JSON.stringify(manifest, null, 2) + '\n', { mode: 0o600 });
}
const snapshot = path.join(output, 'map.bin');
const saved = path.join(output, 'results.jsonl');
const identityFields = ['entries', 'files', 'dirs', 'other', 'skipped_symlinks', 'skipped_mounts', 'skipped_firmlinks', 'errors', 'duplicate_dirs', 'allocated_bytes'];
const records = fs.existsSync(saved)
  ? fs.readFileSync(saved, 'utf8').trim().split('\n').filter(Boolean).map(JSON.parse)
  : [];
const identity = row => JSON.stringify(identityFields.map(key => row[key]));
let expected = records.length ? identity(records[0]) : undefined;
if (records.some(row => identity(row) !== expected)) throw new Error('Saved accounting differs between runs');

function run(name, args) {
  const existing = records.find(row => row.name === name);
  if (existing) return existing;
  const begin = performance.now();
  const result = spawnSync(binary, args, { encoding: 'utf8', timeout: 120_000, maxBuffer: 1024 * 1024 });
  const wall_ms = performance.now() - begin;
  fs.writeFileSync(path.join(output, `${name}.tsv`), result.stdout ?? '', { mode: 0o600 });
  fs.writeFileSync(path.join(output, `${name}.stderr`), result.stderr ?? '', { mode: 0o600 });
  if (result.error || result.status !== 0) {
    throw new Error(`${name}: ${result.error ?? result.stderr ?? result.status}`);
  }
  const [headers, values] = result.stdout.trim().split('\n').map(line => line.split('\t'));
  const row = Object.fromEntries(headers.map((key, index) => [
    key, key === 'root_hex' || key === 'method' ? values[index] : Number(values[index]),
  ]));
  if (Object.values(row).some(value => typeof value === 'number' && !Number.isFinite(value))) {
    throw new Error(`${name}: invalid numeric metric`);
  }
  if (Buffer.from(row.root_hex, 'hex').toString() !== root || row.errors || row.skipped_firmlinks || row.duplicate_dirs) {
    throw new Error(`${name}: invalid scope or incomplete scan; inspect raw output`);
  }
  if (expected && identity(row) !== expected) {
    throw new Error(`${name}: tree accounting changed; do not compare these timings`);
  }
  expected ??= identity(row);
  const record = { name, ...row, wall_ms };
  records.push(record);
  fs.appendFileSync(saved, JSON.stringify(record) + '\n', { mode: 0o600 });
  return record;
}

run('preflight', ['--method', 'bulk', '--workers', '1', '--root', root]);
const variants = [
  ['bulk', 1], ['stat', 1], ['bulk', 2], ['stat', 2],
  ['bulk', 4], ['stat', 4], ['bulk', 8], ['stat', 8],
];
for (let round = 0; round < 3; round++) {
  const order = round === 0 ? variants : round === 1 ? [...variants].reverse() : [...variants.slice(4), ...variants.slice(0, 4)];
  for (const [method, workers] of order) {
    run(`round-${round + 1}-${method}-${workers}`, [
      '--method', method, '--workers', String(workers), '--root', root, '--snapshot', snapshot, '--queries',
    ]);
  }
}
for (let repeat = 0; repeat < 3; repeat++) run(`load-${repeat + 1}`, ['--load', snapshot, '--queries']);
const median = values => [...values].sort((a, b) => a - b)[Math.floor(values.length / 2)];
const metrics = (rows, fields) => Object.fromEntries(fields.map(key => [key, median(rows.map(row => row[key]))]));
const summary = {
  root,
  entries: records[0].entries,
  allocated_bytes: records[0].allocated_bytes,
  allAccountingMatched: true,
  cacheConditions: 'Warm/mixed caches; bulk preflight; no cache purge; alternating method/worker order',
  samplesPerVariant: 3,
  snapshotBytes: fs.statSync(snapshot).size,
  variants: variants.map(([method, workers]) => ({
    method, workers,
    ...metrics(records.filter(row => row.name.startsWith('round-') && row.method === method && row.workers === workers),
      ['scan_ms', 'aggregation_ms', 'snapshot_ms', 'query_ms', 'total_ms', 'wall_ms', 'peak_rss_bytes']),
  })),
  load: metrics(records.filter(row => row.method === 'load'), ['load_ms', 'query_ms', 'total_ms', 'wall_ms', 'peak_rss_bytes']),
};
fs.writeFileSync(path.join(output, 'summary.json'), JSON.stringify(summary, null, 2) + '\n', { mode: 0o600 });
console.log(JSON.stringify(summary, null, 2));
