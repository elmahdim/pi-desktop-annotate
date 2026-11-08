import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm, writeFile, symlink } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { validateBundle, describeBundle, loadBundle, loadFeedback, loadFeedbackIfPresent, presentationText } from '../src/feedback.mjs';
const document = () => ({ version: 2, evidence: [{ id: 1, file: 'evidence-1.png', width: 100, height: 80, capturedAt: '2026-01-01T00:00:00Z' }], notes: [{ id: 1, evidenceId: 1, kind: 'bug', text: 'Fix the popup', region: { x: 10, y: 20, width: 30, height: 40 } }] });
test('validates timestamped evidence and explains per-note association', () => {
  const result = validateBundle(document());
  assert.match(describeBundle(result), /Evidence 1 · 100 × 80/);
  assert.match(describeBundle(result), /\*\*#1 · bug\*\* — box \(10, 20, 30, 40\)/);
  assert.match(describeBundle(result), /not a video/);
});
test('feedback guidance scopes inspection without authorizing edits or project discovery', () => {
  const text = describeBundle(document());
  assert.match(text, /not automatic authorization to edit code or discover other projects/);
  assert.match(text, /Answer questions and suggestions directly/);
  assert.match(text, /never search parent or sibling projects/);
  assert.match(text, /ask the user for its location before proceeding/);
  assert.ok(!text.includes('Inspect code before mapping UI to implementation.'));
});
test('compact description groups notes by evidence and omits capture metadata', () => {
  const doc = document();
  doc.notes[0].region = { x: 10.4, y: 20.2, width: 0, height: 0 };
  doc.evidence.push({ ...doc.evidence[0], id: 2, file: 'evidence-2.png' });
  doc.notes.push({ ...doc.notes[0], id: 2, evidenceId: 2, text: 'Second state' });
  const text = describeBundle(doc);
  assert.match(text, /pin \(10, 20\)/);
  assert.ok(text.indexOf('Fix the popup') < text.indexOf('Evidence 2'));
  assert.ok(text.indexOf('Evidence 2') < text.indexOf('Second state'));
  assert.ok(!text.includes(doc.evidence[0].capturedAt));
  assert.equal(text.match(/Fix the popup/g)?.length, 1);
});
test('loader interleaves each evidence group with its image exactly once', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'pi-bundle-test-'));
  try {
    const png = Buffer.alloc(24);
    Buffer.from('89504e470d0a1a0a', 'hex').copy(png);
    png.writeUInt32BE(100, 16); png.writeUInt32BE(80, 20);
    await writeFile(join(directory, 'annotations.json'), JSON.stringify(document()));
    await writeFile(join(directory, 'evidence-1.png'), png);
    const content = await loadBundle(directory);
    assert.deepEqual(content.map(b => b.type), ['text', 'text', 'image']);
    assert.match(content[1].text, /Fix the popup/);
    assert.ok(!content[0].text.includes('Fix the popup'));
    assert.equal(content[2].data, png.toString('base64'));
    const feedback = await loadFeedback(directory);
    assert.deepEqual(feedback.content, content);
    assert.deepEqual(feedback.presentation, presentationText(document()));
    assert.match(feedback.content[1].text, /box \(10, 20, 30, 40\)/);
    assert.doesNotMatch(feedback.presentation[1], /box \(/);
  } finally { await rm(directory, { recursive: true, force: true }); }
});
test('cancel without a manifest returns no feedback; incomplete sends still fail', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'pi-cancel-test-'));
  try {
    assert.equal(await loadFeedbackIfPresent(directory), undefined);
    await writeFile(join(directory, 'annotations.json'), JSON.stringify(document()));
    await assert.rejects(loadFeedbackIfPresent(directory), { code: 'ENOENT', path: join(directory, 'evidence-1.png') });
    await writeFile(join(directory, 'annotations.json'), '{invalid');
    await assert.rejects(loadFeedbackIfPresent(directory), SyntaxError);
  } finally { await rm(directory, { recursive: true, force: true }); }
});
test('user presentation is package-branded and hides agent-only metadata', () => {
  const doc = document();
  const blocks = presentationText(doc);
  assert.deepEqual(blocks, ['## pi-desktop-annotate', '**Bug · #1**\n\nFix the popup']);
  assert.doesNotMatch(blocks.join('\n'), /Coordinates|Evidence|100 × 80|box \(|Snapshots|Desktop feedback/);
  assert.match(describeBundle(doc), /box \(10, 20, 30, 40\)/);
  doc.notes[0].text = 'Keep my text: box (1, 2, 3, 4) and ### Evidence 13';
  assert.ok(presentationText(doc)[1].includes(doc.notes[0].text));
  doc.evidence.push({ ...doc.evidence[0], id: 13, file: 'evidence-13.png' });
  assert.match(presentationText(doc)[2], /^### Screenshot 2\n\nAnnotated screenshot$/);
});
test('rejects traversal paths, duplicate frames and nonexistent references', () => {
  for (const mutate of [d => d.evidence[0].file = '../private.png', d => d.evidence.push(d.evidence[0]), d => d.notes[0].evidenceId = 99]) {
    const value = document(); mutate(value); assert.throws(() => validateBundle(value));
  }
});
test('rejects nonfinite and out-of-bounds image coordinates', () => {
  for (const region of [null, { x: NaN, y: 0, width: 1, height: 1 }, { x: 90, y: 0, width: 11, height: 1 }, { x: 0, y: -1, width: 0, height: 0 }]) {
    const value = document(); value.notes[0].region = region; assert.throws(() => validateBundle(value));
  }
});
test('bounds frame count, note count and image resolution', () => {
  for (const mutate of [d => d.notes = Array(13).fill(d.notes[0]), d => d.evidence = Array(9).fill(d.evidence[0]), d => d.evidence[0].width = 1921, d => d.evidence[0].height = 1081]) {
    const value = document(); mutate(value); assert.throws(() => validateBundle(value));
  }
});
test('allows drawing-only evidence and rejects empty note text', () => {
  assert.ok(validateBundle({ ...document(), notes: [] }));
  const value = document(); value.notes[0].text = ' '; assert.throws(() => validateBundle(value));
});
test('rejects malformed dates, invalid kinds and duplicate note IDs', () => {
  for (const mutate of [d => d.evidence[0].capturedAt = 'bad', d => d.notes[0].kind = 'unknown', d => d.notes.push(d.notes[0])]) {
    const value = document(); mutate(value); assert.throws(() => validateBundle(value));
  }
});
test('loader rejects PNG/manifest mismatch and symlinked evidence', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'pi-bundle-test-'));
  try {
    await writeFile(join(directory, 'annotations.json'), JSON.stringify(document()));
    await writeFile(join(directory, 'evidence-1.png'), Buffer.alloc(24));
    await assert.rejects(loadBundle(directory), /PNG dimensions/);
    await rm(join(directory, 'evidence-1.png'));
    await symlink(join(directory, 'annotations.json'), join(directory, 'evidence-1.png'));
    await assert.rejects(loadBundle(directory), /regular file/);
  } finally { await rm(directory, { recursive: true, force: true }); }
});
