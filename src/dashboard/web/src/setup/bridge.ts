// The message bridge between the setup wizard and its desktop host (installer/setup/SetupBridge.cs). The page asks with a
// request and the host answers it once; the host also sends events for work that streams (folder sizes, installer progress)
// and for a changed Windows theme. The host accepts only the commands named in SetupCommand and checks every payload again:
// nothing here is trusted by it.

export type SetupCommand =
  | 'hello' | 'getPlan' | 'browseFolder' | 'browseRepositoryFolder' | 'measureFolders' | 'cancelMeasure'
  | 'install' | 'cancelInstall' | 'uninstall' | 'openDashboard' | 'saveRecoveryKeyCopy' | 'showRecoveryKey'
  | 'copyText' | 'openUrl' | 'close';

/** The only links the page can ask for. The host maps each name to a fixed address of the project's own; the page never sends a URL. */
export type ProjectLink = 'readme' | 'issues' | 'license' | 'requirements';

export interface HostInfo {
  protocol: number;
  /** The version of the Rewindle release this setup installs. */
  version: string;
  dark: boolean;
  highContrast: boolean;
  reducedMotion: boolean;
  locale?: string;
  /** "sample" only for the browser mock, which labels itself. */
  host: 'desktop' | 'sample';
  scenario?: string;
}

export interface ThemeInfo { dark: boolean; highContrast: boolean; reducedMotion: boolean }

export interface MeasureUpdate {
  request: string;
  path: string;
  bytes: number;
  files: number;
  /** Files that are only in the cloud (OneDrive and similar), and their size. Backups refuse a folder that holds any. */
  placeholderFiles: number;
  placeholderBytes: number;
  /** Folders that could not be read (access denied) and were left out of the total. */
  skippedFolders: number;
  done: boolean;
  error: string | null;
}

export type Operation = 'install' | 'uninstall';
export type OperationStage = 'preparing' | 'elevating' | 'running';
export type OperationOutcome = 'succeeded' | 'failed' | 'cancelled' | 'blocked';

export interface OperationFinished {
  operation: Operation;
  outcome: OperationOutcome;
  /** The installer's result line (JSON), when it wrote one. */
  result: unknown;
  message: string;
  exitCode: number | null;
  /** For "blocked": the final plan, whose errors stopped the install before Windows was asked. */
  plan?: unknown;
}

export type HostEvent =
  | { event: 'theme'; data: ThemeInfo }
  | { event: 'measure'; data: MeasureUpdate }
  | { event: 'operationStage'; data: { operation: Operation; stage: OperationStage } }
  | { event: 'operationLine'; data: { operation: Operation; raw: string; line: unknown } }
  | { event: 'operationFinished'; data: OperationFinished };

export interface HostError { code: string; message: string }

export type HostMessage =
  | { type: 'response'; id: string; ok: boolean; result?: unknown; error?: HostError }
  | ({ type: 'event' } & HostEvent);

export interface PageRequest { type: 'request'; id: string; command: SetupCommand; payload?: Record<string, unknown> }

export interface SetupWebView {
  postMessage(message: PageRequest): void;
  addEventListener(type: 'message', listener: (event: MessageEvent<HostMessage>) => void): void;
  removeEventListener(type: 'message', listener: (event: MessageEvent<HostMessage>) => void): void;
}

declare global {
  interface Window { rewindleSetupNative?: SetupWebView }
}

export class BridgeError extends Error {
  code: string;
  constructor(code: string, message: string) { super(message); this.name = 'BridgeError'; this.code = code; }
}

// Long enough for the slowest honest answer (the host's own plan time-out is shorter), short enough that a page whose host
// went away says so instead of waiting for ever.
const REQUEST_TIMEOUT_MS = 150_000;

type Listener = (event: HostEvent) => void;

/** One bridge per page. Created lazily, because the browser mock installs itself before the page first asks. */
class Bridge {
  private sequence = 0;
  private pending = new Map<string, { resolve: (value: unknown) => void; reject: (error: Error) => void; timer: number }>();
  private listeners = new Set<Listener>();
  private native: SetupWebView | null = null;

  private connect(): SetupWebView | null {
    if (this.native) return this.native;
    const native = window.rewindleSetupNative ?? (window.chrome?.webview as unknown as SetupWebView | undefined) ?? null;
    if (!native) return null;
    native.addEventListener('message', event => this.receive(event.data));
    this.native = native;
    return native;
  }

  private receive(message: HostMessage) {
    if (!message || typeof message !== 'object') return;
    if (message.type === 'response') {
      const waiting = this.pending.get(message.id);
      if (!waiting) return;
      this.pending.delete(message.id);
      window.clearTimeout(waiting.timer);
      if (message.ok) waiting.resolve(message.result);
      else waiting.reject(new BridgeError(message.error?.code ?? 'failed', message.error?.message ?? 'Setup could not do that. Try again.'));
    } else if (message.type === 'event') {
      const { type: _type, ...event } = message;
      this.listeners.forEach(listener => listener(event as HostEvent));
    }
  }

  get available() { return this.connect() !== null; }

  request<T>(command: SetupCommand, payload?: Record<string, unknown>): Promise<T> {
    const native = this.connect();
    if (!native) return Promise.reject(new BridgeError('no_host', 'Rewindle Setup is not running. Open the setup program to continue.'));
    const id = String(++this.sequence);
    return new Promise<T>((resolve, reject) => {
      const timer = window.setTimeout(() => {
        this.pending.delete(id);
        reject(new BridgeError('timeout', 'Rewindle Setup did not answer in time. Try again.'));
      }, REQUEST_TIMEOUT_MS);
      this.pending.set(id, { resolve: value => resolve(value as T), reject, timer });
      native.postMessage({ type: 'request', id, command, payload });
    });
  }

  subscribe(listener: Listener): () => void {
    this.connect();
    this.listeners.add(listener);
    return () => { this.listeners.delete(listener); };
  }
}

export const bridge = new Bridge();

export const messageOf = (error: unknown) =>
  error instanceof Error ? error.message : 'Something went wrong. Try again.';
