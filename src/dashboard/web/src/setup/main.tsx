import React from 'react';
import '@fontsource-variable/inter';
import '@fontsource-variable/jetbrains-mono';
import { createRoot } from 'react-dom/client';
import SetupApp from './SetupApp';
import '../../styles/beautifului.css';
import '../../styles/app.css';
import '../../styles/setup.css';

window.addEventListener('error', event => console.error('[Rewindle Setup] Uncaught error.', event.error ?? event.message));
window.addEventListener('unhandledrejection', event => console.error('[Rewindle Setup] Unhandled promise rejection.', event.reason));

class SetupErrorBoundary extends React.Component<{ children: React.ReactNode }, { failed: boolean }> {
  state = { failed: false };
  static getDerivedStateFromError() { return { failed: true }; }
  componentDidCatch(error: unknown) { console.error('[Rewindle Setup] The wizard failed to draw.', error); }
  render() {
    if (!this.state.failed) return this.props.children;
    return (
      <div className="setup-loading" role="alert">
        <img src="./rewindle-icon.svg" alt="" width="48" height="48" />
        <p><strong>Rewindle Setup ran into a problem showing this page.</strong></p>
        <p>Nothing was changed. Close Setup and open it again.</p>
      </div>
    );
  }
}

async function start() {
  // Outside the setup program there is no PC to describe. The dev server (`npm run dev:setup`) and the `setup-demo` build
  // mode answer the wizard with invented sample computers instead. The condition is a build-time constant, so the build that
  // ships inside Rewindle Setup drops this import and carries no sample data (installer/setup/build.ps1 checks that).
  if (import.meta.env.DEV || import.meta.env.MODE === 'setup-demo') {
    if (!window.chrome?.webview && !window.rewindleSetupNative) {
      const { installSetupSampleBridge } = await import('./mock/mockSetupBridge');
      installSetupSampleBridge();
    }
  }
  createRoot(document.getElementById('root')!).render(<React.StrictMode><SetupErrorBoundary><SetupApp /></SetupErrorBoundary></React.StrictMode>);
}

void start();
