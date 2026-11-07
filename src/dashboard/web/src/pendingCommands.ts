import { createContext, useContext } from 'react';
import type { CommandName } from './native-types';

// Whether a command that a button sends once per press is still waiting for the host's answer (see oneShot.ts). App provides it, so
// a button anywhere on the page stays off from the press until the answer, and a double-click is one request.
export const PendingCommands = createContext<(command: CommandName) => boolean>(() => false);

export const usePendingCommand = () => useContext(PendingCommands);
