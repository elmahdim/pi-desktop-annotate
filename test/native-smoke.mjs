import { spawn } from 'node:child_process';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import assert from 'node:assert/strict';
import { loadBundle } from '../src/feedback.mjs';
const root = dirname(dirname(fileURLToPath(import.meta.url)));
async function run(command, args) {
  await new Promise((resolve, reject) => {
    const child = spawn(command, args, { cwd: root, stdio: 'inherit' });
    const timer = setTimeout(() => { child.kill('SIGKILL'); reject(new Error('Native test timed out')); }, 120000);
    child.once('error', error => { clearTimeout(timer); reject(error); });
    child.once('exit', code => { clearTimeout(timer); code === 0 ? resolve() : reject(new Error(`Native test exited ${code}`)); });
  });
}
const directory = await mkdtemp(join(tmpdir(), 'pi-native-smoke-'));
try {
  await run(process.execPath, ['scripts/build-native.mjs']);
  await run(join(root, 'build/Pi Desktop Annotate.app/Contents/MacOS/PiDesktopAnnotate'), ['--self-test', directory]);
  const content = await loadBundle(directory);
  assert.equal(content.filter(item => item.type === 'image').length, 2);
  const text = content.filter(item => item.type === 'text').map(item => item.text).join('\n');
  assert.match(text, /First popup evidence/);
  assert.match(text, /Later application state/);
  assert.deepEqual(content.map(item => item.type), ['text', 'text', 'image', 'text', 'image']);
  const cropped = await loadBundle(join(directory, 'cropped'));
  assert.equal(cropped.filter(item => item.type === 'image').length, 2);
  assert.match(cropped.filter(item => item.type === 'text').map(item => item.text).join('\n'), /Cropped detail/);
  const mixed = await loadBundle(join(directory, 'mixed'));
  assert.equal(mixed.filter(item => item.type === 'image').length, 3);
  console.log('Pi handoff passed: full-frame, cropped, and mixed evidence loaded with matching notes');
} finally { await rm(directory, { recursive: true, force: true }); }
