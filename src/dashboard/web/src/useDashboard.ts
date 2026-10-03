import { useCallback, useEffect, useRef, useState, type FocusEvent } from 'react';
import { PROTECTED_COMMANDS, type CommandName, type DashboardState, type NativeMessage, type Notice } from './native-types';

// The host sends a state about once a second, and a heartbeat at least every five seconds when there is nothing new to show
// (an unchanged state, or a window nobody can see). Past this much silence the page stops trusting what it shows.
const STALE_AFTER_MS = 15000;
const CHECK_EVERY_MS = 3000;
// A check that runs this much later than it was due means the computer slept (or the window was frozen), not that the host went quiet.
const OVERDUE_MS = 5000;
// How long a notice that is not an error stays up: about 80 ms a character, which is a comfortable pace to read at, and never
// less than 8 seconds. An error stays until it is dismissed, or until the command it reports works (see `failure` below).
const noticeDuration = (text: string) => Math.max(8000, text.length * 80);
// Said when the host refused or failed a command and gave no reason of its own. The host gives one with every refusal, so this only
// stands in for an answer that left it out: a refusal nobody can see reads as the button doing nothing.
const UNEXPLAINED_FAILURE = 'That action could not be completed. Refresh and try again.';

export type NoticeHold = (held: boolean) => void;

/**
 * Handlers that keep a notice up while the pointer or the keyboard focus is on it, so it is not taken away mid-sentence. Spread
 * them onto the notice's element; they do nothing without a `hold` (the sample-data bridge, a dialog that is not given one).
 */
export function noticeHoldProps(hold?: NoticeHold) {
  if (!hold) return {};
  return {
    onMouseEnter: () => hold(true),
    onMouseLeave: () => hold(false),
    onFocus: () => hold(true),
    // Focus that moves between the notice's own controls is still on the notice.
    onBlur: (event: FocusEvent<HTMLElement>) => { if (!event.currentTarget.contains(event.relatedTarget as Node | null)) hold(false); },
  };
}

export function useDashboard() {
  const [state, setState] = useState<DashboardState | null>(null);
  const [notice, setNotice] = useState<Notice | null>(null);
  const [connected, setConnected] = useState(false);
  const lastMessage = useRef(0);
  // The newest state as text, so one that says what the page already shows is not rendered again.
  const lastState = useRef('');
  const sequence = useRef(0);
  const noticeSequence = useRef(0);
  // Who asked to hear how a command ended. The host answers every command, and for most the new state says it all, but a
  // command it refuses (or one that changes nothing) is never published, so the caller that needs to react says so here.
  const awaiting = useRef(new Map<string, (ok: boolean) => void>());
  // Which command each request that is still waiting for its answer was, so an answer can say what it is an answer to.
  const asked = useRef(new Map<string, CommandName>());
  // The notice that is an error from a command, and which command: an error stays until it is dismissed, so when the same command
  // works later, what the page said about it is out of date and goes. (Said by the page itself, with no command, it stays.)
  const failure = useRef<{ notice: number; command: CommandName } | null>(null);
  const say = useCallback((text: string, error: boolean, command?: CommandName) => {
    const id = ++noticeSequence.current;
    failure.current = error && command ? { notice: id, command } : null;
    setNotice({ id, text, error });
  }, []);
  const send = useCallback((command: CommandName, payload?: Record<string, string | boolean>, onResult?: (ok: boolean) => void) => {
    const native = window.rewindleNative ?? window.chrome?.webview;
    if (!native) { say('Open the desktop app to use backup controls.', true); onResult?.(false); return; }
    // Only a command that changes or reads the backup plan waits for a live link. Moving between pages, the theme, picking a run,
    // closing a dialog and the like only touch what the page shows, so a stale link does not stop them.
    if (PROTECTED_COMMANDS.has(command) && lastMessage.current && Date.now() - lastMessage.current > STALE_AFTER_MS) {
      say('The dashboard has lost its connection. Refresh before changing your backup plan.', true);
      onResult?.(false);
      return;
    }
    const id = String(++sequence.current);
    asked.current.set(id, command);
    if (onResult) awaiting.current.set(id, onResult);
    native.postMessage({ type: 'command', id, command, payload });
  }, [say]);
  useEffect(() => {
    const native = window.rewindleNative ?? window.chrome?.webview;
    if (!native) return;
    const receive = (event: MessageEvent<NativeMessage>) => {
      const message = event.data;
      if (message.type === 'state') {
        lastMessage.current = Date.now();
        setConnected(true);
        const text = JSON.stringify(message.state);
        if (text === lastState.current) return;
        lastState.current = text;
        setState(message.state);
      } else if (message.type === 'heartbeat') {
        lastMessage.current = Date.now();
        setConnected(true);
      } else if (message.type === 'result') {
        const command = asked.current.get(message.id);
        asked.current.delete(message.id);
        const done = awaiting.current.get(message.id);
        if (done) { awaiting.current.delete(message.id); done(message.ok); }
        if (message.message) say(message.message, !message.ok, command);
        else if (!message.ok) say(UNEXPLAINED_FAILURE, true, command);
        else if (command && failure.current?.command === command) {
          const stale = failure.current.notice;
          failure.current = null;
          setNotice(current => current?.id === stale ? null : current);
        }
      }
    };
    native.addEventListener('message', receive);
    send('ready');
    let due = Date.now() + CHECK_EVERY_MS;
    const heartbeat = window.setInterval(() => {
      const now = Date.now(), overdue = now - due;
      due = now + CHECK_EVERY_MS;
      // The silence since the last message says nothing after a sleep: ask the host to announce the state again before judging it.
      // A page nobody can see has its timers slowed on purpose, which looks the same, but it needs no new state until it is shown
      // (the host sends one then), so it does not ask.
      if (overdue > OVERDUE_MS) { if (!document.hidden) send('ready'); return; }
      if (lastMessage.current && now - lastMessage.current > STALE_AFTER_MS) setConnected(false);
    }, CHECK_EVERY_MS);
    return () => { native.removeEventListener('message', receive); clearInterval(heartbeat); };
  }, [send, say]);
  // Whether the pointer or keyboard focus is on the notice, which stops it from timing out. The timer starts over, in full, when
  // the hold ends, so what was being read gets its whole time again.
  const [noticeHeld, setNoticeHeld] = useState(false);
  // A notice that is dismissed or replaced takes any hold on it with it (nothing says "pointer left" for an element that is gone),
  // so the next one starts running.
  useEffect(() => { setNoticeHeld(false); }, [notice]);
  useEffect(() => {
    if (!notice || notice.error || noticeHeld) return;
    const timeout = setTimeout(() => setNotice(null), noticeDuration(notice.text));
    return () => clearTimeout(timeout);
  }, [notice, noticeHeld]);
  const holdNotice = useCallback<NoticeHold>(held => setNoticeHeld(held), []);
  const dismissNotice = useCallback(() => setNotice(null), []);
  return { state, connected, send, notice, dismissNotice, holdNotice };
}
