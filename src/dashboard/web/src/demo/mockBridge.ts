// A stand-in for the desktop app's message bridge, answering with sample data. It lets the interface run
// in an ordinary browser (`npm run dev`, or the `demo` build mode) without a backup installation, and it
// is how the interface can be shown without exposing anyone's real folders or history.
//
// It only ever changes the in-memory sample. Every command that would touch a backup, a schedule, a
// folder or the file system is refused with "Sample data is read-only." This module is reached only
// through the guarded dynamic import in main.tsx, so the build that ships inside the desktop app does
// not contain it.
import type { CommandName, DashboardState, NativeCommand, NativeMessage, NativeWebView } from '../native-types';
import { createSampleRunDetails, createSampleState, formatBytes, formatDuration } from './demoState';

const READ_ONLY = 'Sample data is read-only.';
// The desktop host re-sends state about once a second. The app treats 15 seconds of silence as a lost
// connection and then refuses commands, so the sample must keep talking.
const HEARTBEAT_MS = 1000;
// How long one pass of the animation preview takes.
const PREVIEW_SECONDS = 26;
const PAGES = ['Protection', 'Activity', 'Restore', 'Settings'];
const THEMES = ['System', 'Midnight', 'Daylight'];
const MOTIONS = ['System', 'Full', 'Reduced'];
const PREVIEW_PHASES = [0.9, 0.94, 0.97];

type Listener = (event: MessageEvent<NativeMessage>) => void;
type Payload = Record<string, string | boolean> | undefined;

const prefers = (query: string) => typeof window.matchMedia === 'function' && window.matchMedia(query).matches;

export function installSampleBridge(): void {
  let state: DashboardState = createSampleState();
  const idleStatus = JSON.stringify(state.status);
  const listeners = new Set<Listener>();
  let previewStartedAt = 0;

  const applyPreferences = () => {
    state.dark = state.theme === 'Midnight' ? true : state.theme === 'Daylight' ? false : prefers('(prefers-color-scheme: dark)');
    state.reducedMotion = state.motion === 'Reduced' ? true : state.motion === 'Full' ? false : prefers('(prefers-reduced-motion: reduce)');
  };

  // The same shape of progress the desktop app shows for its labeled animation preview.
  const applyPreview = () => {
    const seconds = (Date.now() - previewStartedAt) / 1000;
    const progress = (seconds % PREVIEW_SECONDS) / PREVIEW_SECONDS;
    state.status = {
      ...state.status, key: 'preview', title: 'Backup in progress', detail: 'This is an animation preview. No backup is running.',
      badge: 'PREVIEW', active: true, success: false, failure: false, cancelled: false,
      phaseIndex: PREVIEW_PHASES.filter(limit => progress >= limit).length, phaseLabel: 'Preview telemetry', progress, estimated: true, runId: '',
      files: Math.round(12480 * progress).toLocaleString(), bytes: formatBytes(4.9e9 * progress), speed: `${(18 + 9 * Math.sin(seconds)).toFixed(1)} MiB/s`,
      elapsed: formatDuration(progress * 372), errors: '0', etaTitle: 'Time remaining', eta: formatDuration((1 - progress) * 372), etaHint: '',
    };
  };

  const post = (message: NativeMessage) => {
    // The wire carries JSON, so the page always receives a fresh copy and never shares the sample's objects.
    const data = JSON.parse(JSON.stringify(message)) as NativeMessage;
    listeners.forEach(listener => listener({ data } as MessageEvent<NativeMessage>));
  };

  const publish = () => {
    applyPreferences();
    if (state.preview) applyPreview();
    state.updated = `Updated ${new Date().toLocaleTimeString(undefined, { hour12: false })}`;
    post({ type: 'state', state });
  };

  const togglePreview = () => {
    state.preview = !state.preview;
    if (state.preview) {
      previewStartedAt = Date.now();
    } else {
      state.status = JSON.parse(idleStatus) as DashboardState['status'];
    }
    const toggle = state.actions.togglePreview;
    if (toggle) toggle.label = state.preview ? 'Stop preview' : 'Preview animation';
  };

  // Returns why a command was refused, or null when the sample handled it.
  const handle = (command: CommandName, payload: Payload): string | null => {
    switch (command) {
      case 'ready':
      case 'refresh':
        return null;
      case 'navigate': {
        const page = String(payload?.page ?? '');
        if (!PAGES.includes(page)) return 'The requested dashboard page is invalid.';
        state.page = page as DashboardState['page'];
        return null;
      }
      case 'setTheme': {
        const theme = String(payload?.theme ?? '');
        if (!THEMES.includes(theme)) return 'The requested dashboard theme is invalid.';
        state.theme = theme as DashboardState['theme'];
        return null;
      }
      case 'setMotion': {
        const motion = String(payload?.motion ?? '');
        if (!MOTIONS.includes(motion)) return 'The requested motion preference is invalid.';
        state.motion = motion as DashboardState['motion'];
        return null;
      }
      case 'selectRun': {
        const run = state.history.find(item => item.id === String(payload?.runId ?? ''));
        if (!run) return 'The requested backup run is unavailable.';
        state.selectedRunId = run.id;
        return null;
      }
      case 'viewRunDetails': {
        const id = String(payload?.runId ?? state.selectedRunId ?? '');
        const run = state.history.find(item => item.id === id);
        if (!run) return 'The requested backup run is unavailable.';
        state.selectedRunId = run.id;
        state.runDetails = createSampleRunDetails(run);
        return null;
      }
      case 'closeRunDetails':
        state.runDetails = null;
        return null;
      case 'togglePreview':
        togglePreview();
        return null;
      default:
        return READ_ONLY;
    }
  };

  const receive = (command: NativeCommand) => {
    const refusal = handle(command.command, command.payload);
    post({ type: 'result', id: command.id, ok: refusal === null, ...(refusal === null ? {} : { message: refusal }) });
    publish();
  };

  const bridge: NativeWebView = {
    // Answered on the next turn, like a message that crosses to the host and back.
    postMessage(message) { window.setTimeout(() => receive(message), 0); },
    addEventListener(_type, listener) { listeners.add(listener); },
    removeEventListener(_type, listener) { listeners.delete(listener); },
  };
  window.rewindleNative = bridge;
  window.setInterval(publish, HEARTBEAT_MS);
}
