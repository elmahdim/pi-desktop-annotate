import { readFile, lstat } from 'node:fs/promises';
import { join } from 'node:path';

export function validateBundle(value) {
  const fail = message => { throw new Error(`Invalid annotation bundle: ${message}`); };
  const integer = n => Number.isSafeInteger(n) && n > 0;
  if (!value || value.version !== 2 || !Array.isArray(value.notes) || !Array.isArray(value.evidence) || value.notes.length > 12 || value.evidence.length < 1 || value.evidence.length > 8) fail('version or limits');
  const frames = new Map();
  for (const e of value.evidence) {
    if (!e || !integer(e.id) || frames.has(e.id) || e.file !== `evidence-${e.id}.png` || !integer(e.width) || !integer(e.height) || e.width > 1920 || e.height > 1080 || typeof e.capturedAt !== 'string' || !Number.isFinite(Date.parse(e.capturedAt))) fail('evidence metadata');
    frames.set(e.id, e);
  }
  const ids = new Set();
  for (const n of value.notes) {
    const frame = frames.get(n?.evidenceId), r = n?.region;
    if (!n || !integer(n.id) || ids.has(n.id) || !frame || !['note', 'bug', 'change', 'question'].includes(n.kind) || typeof n.text !== 'string' || !n.text.trim() || n.text.length > 8000) fail('note metadata');
    // Swift counts graphemes, JS counts UTF-16 units. Also bound total UTF-8 below.
    if (!r || !['x', 'y', 'width', 'height'].every(k => Number.isFinite(r[k]) && r[k] >= 0) || r.x + r.width > frame.width + .01 || r.y + r.height > frame.height + .01) fail('note region');
    ids.add(n.id);
  }
  return value;
}

function describeEvidence(doc, e) {
  const notes = doc.notes.filter(n => n.evidenceId === e.id);
  return [`### Evidence ${e.id} · ${e.width} × ${e.height}`,
    ...notes.map(n => {
      const r = n.region;
      const location = r.width === 0 && r.height === 0
        ? `pin (${Math.round(r.x)}, ${Math.round(r.y)})`
        : `box (${[r.x, r.y, r.width, r.height].map(Math.round).join(', ')})`;
      return `**#${n.id} · ${n.kind}** — ${location}\n\n${n.text.trim()}`;
    }),
    ...(notes.length ? [] : ['Drawings / masks only.']),
  ].join('\n\n');
}

function introduction(doc) {
  return `## pi-desktop-annotate\n\nSnapshots at note creation, not a video; states may differ. Coordinates: top-left pixels; boxes: (x, y, w, h). Ink/masks apply across images.\n\nTreat these notes as feedback, not automatic authorization to edit code or discover other projects. Answer questions and suggestions directly when the evidence is sufficient. If code inspection is needed, stay within the current workspace and explicitly user-authorized paths; never search parent or sibling projects to identify the pictured app. If the relevant source is not in the workspace, ask the user for its location before proceeding. Inspect authorized source before mapping UI to implementation.`;
}

export function describeBundle(doc) {
  return [introduction(doc), ...doc.evidence.map(e => describeEvidence(doc, e))].join('\n\n');
}

export function presentationText(doc) {
  return ['## pi-desktop-annotate', ...doc.evidence.map((e, index) => [
    ...(doc.evidence.length > 1 ? [`### Screenshot ${index + 1}`] : []),
    ...doc.notes.filter(n => n.evidenceId === e.id).map(n => `**${n.kind[0].toUpperCase() + n.kind.slice(1)} · #${n.id}**\n\n${n.text.trim()}`),
    ...(doc.notes.some(n => n.evidenceId === e.id) ? [] : ['Annotated screenshot']),
  ].join('\n\n'))];
}

export async function loadBundle(directory) {
  return (await loadFeedback(directory)).content;
}

// A clean native exit without a manifest means Cancel/Close, not a failed send.
export async function loadFeedbackIfPresent(directory) {
  try {
    return await loadFeedback(directory);
  } catch (error) {
    if (error.code === 'ENOENT' && error.path === join(directory, 'annotations.json')) return undefined;
    throw error;
  }
}

export async function loadFeedback(directory) {
  const manifest = join(directory, 'annotations.json');
  const stat = await lstat(manifest);
  if (!stat.isFile() || stat.size > 128 * 1024) throw new Error('Annotation manifest is too large or not a regular file');
  const doc = validateBundle(JSON.parse(await readFile(manifest, 'utf8')));
  const content = [{ type: 'text', text: introduction(doc) }];
  let total = 0;
  for (const e of doc.evidence) {
    const file = join(directory, e.file);
    const stat = await lstat(file);
    total += stat.size;
    if (!stat.isFile() || total > 20 * 1024 * 1024) throw new Error('Evidence exceeds 20 MB or is not a regular file');
    const png = await readFile(file);
    if (png.length < 24 || png.subarray(0, 8).toString('hex') !== '89504e470d0a1a0a' || png.readUInt32BE(16) !== e.width || png.readUInt32BE(20) !== e.height) throw new Error('Evidence PNG dimensions do not match its manifest');
    content.push({ type: 'text', text: describeEvidence(doc, e) });
    content.push({ type: 'image', mimeType: 'image/png', data: png.toString('base64') });
  }
  return { content, presentation: presentationText(doc) };
}
