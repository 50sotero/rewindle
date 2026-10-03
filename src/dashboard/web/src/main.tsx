import React from 'react';
import '@fontsource-variable/inter';
import '@fontsource-variable/jetbrains-mono';
import { createRoot } from 'react-dom/client';
import App, { AppErrorBoundary } from './App';
import '../styles/beautifului.css';
import '../styles/app.css';
import '../styles/restore-flow.css';

// Failures outside a render (an event handler, a promise nobody awaited) are not caught by a boundary and would pass without a
// trace. They are logged, so anyone who attaches the browser's tools to the page can see them; nothing is sent to the host.
window.addEventListener('error', event => console.error('[Rewindle] Uncaught error.', event.error ?? event.message));
window.addEventListener('unhandledrejection', event => console.error('[Rewindle] Unhandled promise rejection.', event.reason));

async function start() {
  // Outside the desktop app there is no backup state to show. The dev server (`npm run dev`) and the
  // `demo` build mode (`npm run build:demo`) answer the app's bridge with sample data instead. The
  // condition is a build-time constant, so the build that ships inside the desktop app drops this
  // import entirely and carries no sample data.
  if (import.meta.env.DEV || import.meta.env.MODE === 'demo') {
    if (!window.chrome?.webview && !window.rewindleNative) {
      const { installSampleBridge } = await import('./demo/mockBridge');
      installSampleBridge();
    }
  }
  // The outermost boundary: when nothing smaller caught a failure, the window shows what happened and a way to reload it
  // instead of going blank.
  createRoot(document.getElementById('root')!).render(<React.StrictMode><AppErrorBoundary><App /></AppErrorBoundary></React.StrictMode>);
}

void start();
