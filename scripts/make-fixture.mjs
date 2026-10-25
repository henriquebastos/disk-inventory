import fs from 'node:fs';
import path from 'node:path';

const root = process.argv[2];
if (!root || !path.isAbsolute(root) || process.argv.length !== 3) {
  throw new Error('Usage: node make-fixture.mjs NEW_ABSOLUTE_DIRECTORY');
}
fs.mkdirSync(root, { mode: 0o700 });
let files = 0;
for (let directory = 0; directory < 128; directory++) {
  const parent = path.join(root, `branch-${String(directory).padStart(3, '0')}`);
  fs.mkdirSync(parent);
  for (let file = 0; file < 256; file++) {
    fs.writeFileSync(path.join(parent, `file-${String(file).padStart(3, '0')}`), file % 16 === 0 ? 'x' : '');
    files++;
  }
}
const flat = path.join(root, 'flat');
fs.mkdirSync(flat);
for (let file = 0; file < 16384; file++) {
  fs.writeFileSync(path.join(flat, `file-${String(file).padStart(5, '0')}`), file % 16 === 0 ? 'x' : '');
  files++;
}
let deep = path.join(root, 'deep');
for (let level = 0; level < 100; level++) {
  fs.mkdirSync(deep);
  fs.writeFileSync(path.join(deep, 'leaf'), 'x');
  files++;
  deep = path.join(deep, 'd');
}
const sparse = fs.openSync(path.join(root, 'sparse'), 'wx');
fs.ftruncateSync(sparse, 1024 ** 3);
fs.writeSync(sparse, Buffer.from('x'), 0, 1, 1024 ** 3 - 1);
fs.closeSync(sparse);
for (let index = 0; index < 64; index++) {
  fs.linkSync(path.join(root, 'branch-000', 'file-000'), path.join(root, `branch-${String(index).padStart(3, '0')}`, 'shared'));
}
fs.symlinkSync(root, path.join(root, 'cycle'));
fs.symlinkSync('/Applications', path.join(root, 'outside'));
fs.writeFileSync(path.join(root, 'tabs\tand\nnewlines'), 'x');
fs.writeFileSync(path.join(root, '日本語'), 'x');
console.log(JSON.stringify({ root, ordinaryFiles: files, hardlinks: 64, symlinks: 2, sparseLogicalBytes: 1024 ** 3 }));
