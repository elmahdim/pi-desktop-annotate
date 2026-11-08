import { spawn } from 'node:child_process';
import { mkdir, readFile, writeFile, rm, access } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

let child;
let cancelled = false;
for (const signal of ['SIGTERM', 'SIGINT', 'SIGHUP']) process.on(signal, () => { cancelled = true; child?.kill(signal); });
async function run(command, args) {
  if (cancelled) process.exit(130);
  const status = await new Promise((resolve, reject) => {
    child = spawn(command, args, { stdio: 'inherit' });
    child.once('error', reject);
    child.once('exit', (code) => resolve(code ?? 130));
  });
  child = undefined;
  if (status !== 0 || cancelled) process.exit(cancelled ? 130 : status);
}
const root = dirname(dirname(fileURLToPath(import.meta.url)));
if (process.platform !== 'darwin') throw new Error('The native companion currently requires macOS 14 or newer.');
const app = join(root, 'build/Pi Desktop Annotate.app');
const contents = join(app, 'Contents');
const files = ['Capture.swift', 'UI.swift', 'Model.swift', 'main.swift'].map(file => join(root, 'native', file));
const sources = await Promise.all(files.map(file => readFile(file)));
const hash = createHash('sha256').update(process.arch).update('macos14-swift5-v1');
for (const source of sources) hash.update(source);
hash.update(await readFile(fileURLToPath(import.meta.url)));
const fingerprint = hash.digest('hex');
let previous;
try {
  await access(join(contents, 'MacOS/PiDesktopAnnotate'));
  await access(join(contents, 'Info.plist'));
  previous = await readFile(join(root, 'build/.source-hash'), 'utf8');
} catch {}
if (previous !== fingerprint) {
  await mkdir(join(contents, 'MacOS'), { recursive: true });
  await run('/usr/bin/xcrun', ['swiftc', '-swift-version', '5', '-O', '-target', `${process.arch === 'arm64' ? 'arm64' : 'x86_64'}-apple-macos14.0`, ...files, '-o', join(contents, 'MacOS/PiDesktopAnnotate')]);
  await writeFile(join(contents, 'Info.plist'), `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.pi.desktop-annotate</string>
<key>CFBundleName</key><string>Pi Desktop Annotate</string>
<key>CFBundleExecutable</key><string>PiDesktopAnnotate</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.2.0</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSScreenCaptureUsageDescription</key><string>Keep local screen evidence for notes you explicitly send to Pi. No audio or video recording is saved.</string>
</dict></plist>`);
  await rm(join(contents, '.source-hash'), { force: true });
  await run('/usr/bin/codesign', ['--force', '--sign', '-', '--identifier', 'local.pi.desktop-annotate', app]);
  await writeFile(join(root, 'build/.source-hash'), fingerprint);
}
console.log(join(contents, 'MacOS/PiDesktopAnnotate'));
