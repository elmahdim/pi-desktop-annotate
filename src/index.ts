import { getMarkdownTheme, type ExtensionAPI } from '@earendil-works/pi-coding-agent';
import { Container, Image, Markdown, Spacer, Text } from '@earendil-works/pi-tui';
import { spawn, type ChildProcess } from 'node:child_process';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
// A new module identity avoids reusing the pre-loadFeedback native ESM cache on /reload.
import { loadFeedbackIfPresent } from './feedback.mjs';

const root = dirname(dirname(fileURLToPath(import.meta.url)));

export default function desktopAnnotate(pi: ExtensionAPI) {
  // One persisted multimodal message: no duplicate screenshots in UI-only entries.
  pi.registerMessageRenderer('desktop-annotate', (message, { outputPad }, theme) => {
    const view = new Container();
    const blocks = typeof message.content === 'string' ? [{ type: 'text' as const, text: message.content }] : message.content;
    const presentation = (message.details as { presentation?: string[] } | undefined)?.presentation;
    let textIndex = 0;
    for (const block of blocks) {
      if (block.type === 'text') {
        view.addChild(new Markdown(presentation?.[textIndex++] ?? block.text, outputPad, 1, getMarkdownTheme()));
      } else if (block.type === 'image') {
        if (pi.getSettings().terminal?.showImages === false) {
          view.addChild(new Text(theme.fg('dim', 'Evidence image attached · previews disabled in settings'), outputPad, 0));
        } else {
          view.addChild(new Image(block.data, block.mimeType, { fallbackColor: text => theme.fg('dim', text) }, { maxWidthCells: pi.getSettings().terminal?.imageWidthCells ?? 80, maxHeightCells: 24 }));
        }
        view.addChild(new Spacer(1));
      }
    }
    return view;
  });
  type Run = { child?: ChildProcess; directory?: string; native?: boolean; cancelled: boolean; done: Promise<void> };
  let active: Run | undefined;
  // The app is launched via LaunchServices (`open`) so it is its own TCC responsible process;
  // that detaches it from our `open` child, so we signal it by the PID it writes at startup.
  const readAppPid = async (directory: string): Promise<number | undefined> => {
    try { const pid = Number.parseInt(await readFile(join(directory, 'app.pid'), 'utf8'), 10); return Number.isInteger(pid) ? pid : undefined; }
    catch { return undefined; }
  };
  const signalApp = async (directory: string | undefined, signal: NodeJS.Signals) => {
    if (!directory) return;
    const pid = await readAppPid(directory);
    if (pid !== undefined) { try { process.kill(pid, signal); } catch { /* already gone */ } }
  };
  const stop = async () => {
    const current = active;
    if (!current) return;
    current.cancelled = true;
    await signalApp(current.directory, 'SIGTERM');
    current.child?.kill('SIGTERM');
    const timer = setTimeout(() => { void signalApp(current.directory, 'SIGKILL'); current.child?.kill('SIGKILL'); }, 2000);
    try { await current.done; } finally { clearTimeout(timer); }
  };
  pi.on('session_shutdown', stop);
  pi.registerCommand('annotate', {
    description: 'Open native live desktop notes. /annotate cancel closes them without sending.',
    handler: async (args, ctx) => {
      if (args.trim() === 'cancel') { await stop(); return; }
      if (args.trim()) { ctx.ui.notify('Usage: /annotate or /annotate cancel', 'warning'); return; }
      if (!ctx.hasUI) throw new Error('Desktop Annotate requires an interactive Pi session and a graphical desktop.');
      if (process.platform !== 'darwin') { ctx.ui.notify('The native companion currently requires macOS 14 or newer.', 'error'); return; }
      if (active) {
        if (active.native) await signalApp(active.directory, 'SIGUSR1');
        ctx.ui.notify('Desktop annotations are already open. Restoring the toolbar if minimized.', 'info');
        return;
      }
      if (!ctx.model?.input.includes('image')) { ctx.ui.notify('Select an image-capable model before sending visual feedback.', 'warning'); return; }
      let settle!: () => void;
      const current: Run = { cancelled: false, done: new Promise<void>(resolve => { settle = resolve; }) };
      active = current;
      let directory: string | undefined;
      const run = async (command: string, args: string[], env: NodeJS.ProcessEnv = process.env) => {
        if (current.cancelled) return;
        let errors = '';
        const child = spawn(command, args, { env, stdio: ['ignore', 'ignore', 'pipe'] });
        current.child = child;
        child.stderr?.on('data', chunk => { errors = (errors + String(chunk)).slice(-4000); });
        await new Promise<void>((resolve, reject) => {
          child.once('error', reject);
          child.once('exit', code => code === 0 || current.cancelled ? resolve() : reject(new Error(`Native companion exited (${code}). ${errors}`)));
        });
        current.child = undefined;
      };
      try {
        ctx.ui.setStatus('desktop-annotate', '◉ Preparing native desktop notes');
        // Incremental local build; only recompiles after native source changes.
        await run(process.execPath, [join(root, 'scripts/build-native.mjs')]);
        if (current.cancelled) return;
        directory = await mkdtemp(join(tmpdir(), 'pi-annotate-'));
        current.directory = directory;
        if (current.cancelled) return;
        ctx.ui.setStatus('desktop-annotate', '◉ Live desktop notes');
        ctx.ui.notify('pi-desktop-annotate: choose a desktop or window to annotate. Nothing is shared until you send.', 'info');
        current.native = true;
        // LaunchServices launch: the app becomes its own TCC responsible process, so its own
        // Screen Recording grant applies regardless of the (possibly sandboxed) launcher. `open -W`
        // waits for the app to quit; the output path travels via argv since `open` drops our env.
        await run('/usr/bin/open', ['-n', '-W', '-a', join(root, 'build/Pi Desktop Annotate.app'), '--args', '--output', directory]);
        if (current.cancelled) return;
        const feedback = await loadFeedbackIfPresent(directory);
        if (current.cancelled) return;
        if (!feedback) {
          ctx.ui.notify('Annotation cancelled. Nothing sent.', 'info');
          return;
        }
        const { content, presentation } = feedback;
        pi.sendMessage({ customType: 'desktop-annotate', content, details: { presentation }, display: true }, { triggerTurn: true, deliverAs: 'followUp' });
      } catch (error) {
        if (!current.cancelled) ctx.ui.notify(`Desktop Annotate: ${error instanceof Error ? error.message : String(error)}`, 'error');
      } finally {
        try { if (directory) await rm(directory, { recursive: true, force: true }); }
        finally {
          if (active === current) active = undefined;
          settle();
          ctx.ui.setStatus('desktop-annotate', undefined);
        }
      }
    },
  });
}
