import type { CommandName } from './native-types';

// Commands a button sends once per press. The host runs each of them and answers when it has (after its own dialog closes, for
// most), so a second press before that answer is never a second request the person meant: a double-click on Back up now asked
// twice, and the second ask came back as a red refusal or, after the first was declined, as a second "Start a real backup now?".
// While one is waiting for its answer, the button that sends it stays off and a second send is dropped.
// Commands that legitimately repeat are not here: moving between pages, picking a run, refreshing, zoom, copying, browsing the
// folders of a backup or the files picked for a restore, checking a folder as it is typed, and closing a dialog.
// Erasable TypeScript only, with no imports but types: tests/test_dashboard_ui_actions.py runs this file with Node as it is.

export const ONE_SHOT_COMMANDS: ReadonlySet<CommandName> = new Set<CommandName>([
  'backupNow', 'cancelBackup', 'addSource', 'removeSource', 'editSchedule', 'changeRepository', 'repairRepository',
  'reviewChanges', 'openRestore', 'checkReadiness', 'exportDiagnostics', 'retrySourceChange', 'confirmSourcePicker',
  'viewRunDetails', 'restoreFlowReview', 'restoreFlowStart', 'restoreFlowRetry',
  // Find a file: Find, Look further back and Restore this each ask the restore session (or move the flow) once per press.
  'restoreFlowFindFiles', 'restoreFlowFindMore', 'restoreFlowPickFound',
  'retentionConfigure', 'retentionCheckNow', 'retentionOpenReview', 'retentionApply',
]);

export type Send = (command: CommandName, payload?: Record<string, string | boolean>, onResult?: (ok: boolean) => void) => void;

/** The one-shot commands that were sent and have not been answered yet. */
export type InFlight = {
  /** Marks a one-shot command as sent; false when it already is (the press is dropped). Any other command is always let through. */
  begin(command: CommandName): boolean;
  end(command: CommandName): void;
  has(command: CommandName): boolean;
  /** Forgets every command still waiting, for when its answer can no longer come (the link to the host was lost and is back). */
  clear(): void;
};

export function createInFlight(): InFlight {
  const waiting = new Set<CommandName>();
  return {
    begin(command) {
      if (!ONE_SHOT_COMMANDS.has(command)) return true;
      if (waiting.has(command)) return false;
      waiting.add(command);
      return true;
    },
    end(command) { waiting.delete(command); },
    has(command) { return waiting.has(command); },
    clear() { waiting.clear(); },
  };
}

/**
 * `send`, but a one-shot command that is still waiting for its answer is not sent again. `changed` is told whenever what is waiting
 * changes, so the buttons can be drawn again. A press that is dropped hears nothing back: the press before it is the one answered.
 */
export function sendOnceAtATime(send: Send, inFlight: InFlight, changed: () => void): Send {
  return (command, payload, onResult) => {
    if (!ONE_SHOT_COMMANDS.has(command)) { send(command, payload, onResult); return; }
    if (!inFlight.begin(command)) return;
    changed();
    send(command, payload, ok => {
      inFlight.end(command);
      changed();
      onResult?.(ok);
    });
  };
}
