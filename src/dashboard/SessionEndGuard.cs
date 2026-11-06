using System;
using System.Reflection;
using System.Windows;

namespace ResticBackuper.Dashboard
{
    // Keeps Rewindle running through a sign-out or shutdown that is then cancelled, without ever holding one up.
    //
    // When Windows asks whether the session may end (WM_QUERYENDSESSION), WPF's hidden application window raises
    // Application.SessionEnding and, unless that is cancelled, shuts the application down at once, before Windows has
    // decided anything. If another app, or the person on the "apps are preventing" screen, then cancels the sign-out or
    // shutdown, Rewindle is already gone and nothing watches the backups until the next sign-in. Cancelling SessionEnding
    // would keep it, but would make Rewindle one of the apps that hold up a sign-out.
    //
    // The guard answers the question itself on that same hidden window, ahead of WPF: yes, the session may end. WPF then
    // never starts its own shutdown, and the guard waits for Windows' decision (WM_ENDSESSION). A session that ends runs
    // sessionEnded before the message returns, because Windows may end the process as soon as it does; one that was
    // cancelled runs sessionEndCancelled and Rewindle carries on as it was.
    //
    // The hidden window and its hook list are WPF's own, reached by reflection (.NET Framework 4.8 no longer changes). If
    // any of it cannot be found, TryInstall returns null and the application keeps WPF's behaviour.
    internal sealed class SessionEndGuard
    {
        private const int WmQueryEndSession = 0x0011;
        private const int WmEndSession = 0x0016;

        private readonly Action sessionEnded;
        private readonly Action sessionEndCancelled;
        // The hidden window holds its hooks by weak reference, so the guard keeps the delegate alive itself.
        private Delegate hook;

        private SessionEndGuard(Action sessionEnded, Action sessionEndCancelled)
        {
            this.sessionEnded = sessionEnded;
            this.sessionEndCancelled = sessionEndCancelled;
        }

        // Installs the guard on the application's hidden window, which WPF creates when Application.Run starts, so this is
        // called from the main window's SourceInitialized or later. Returns null when the window or its hooks cannot be found.
        public static SessionEndGuard TryInstall(Application application, Action sessionEnded, Action sessionEndCancelled)
        {
            if (application == null || sessionEnded == null || sessionEndCancelled == null)
            {
                return null;
            }
            try
            {
                FieldInfo hiddenWindowField = typeof(Application).GetField(
                    "_parkingHwnd",
                    BindingFlags.Instance | BindingFlags.NonPublic);
                object hiddenWindow = hiddenWindowField == null ? null : hiddenWindowField.GetValue(application);
                if (hiddenWindow == null)
                {
                    return null;
                }
                Type hookType = hiddenWindow.GetType().Assembly.GetType("MS.Win32.HwndWrapperHook", false);
                if (hookType == null)
                {
                    return null;
                }
                MethodInfo addHook = hiddenWindow.GetType().GetMethod(
                    "AddHook",
                    BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic,
                    null,
                    new Type[] { hookType },
                    null);
                MethodInfo filter = typeof(SessionEndGuard).GetMethod(
                    "FilterMessage",
                    BindingFlags.Instance | BindingFlags.NonPublic);
                if (addHook == null || filter == null)
                {
                    return null;
                }
                SessionEndGuard guard = new SessionEndGuard(sessionEnded, sessionEndCancelled);
                guard.hook = Delegate.CreateDelegate(hookType, guard, filter, false);
                if (guard.hook == null)
                {
                    return null;
                }
                addHook.Invoke(hiddenWindow, new object[] { guard.hook });
                return guard;
            }
            catch (Exception)
            {
                return null;
            }
        }

        private IntPtr FilterMessage(IntPtr window, int message, IntPtr wParam, IntPtr lParam, ref bool handled)
        {
            if (message == WmQueryEndSession)
            {
                // Always yes: Rewindle never holds up a sign-out or shutdown. Handled, so WPF does not shut down now.
                handled = true;
                return new IntPtr(1);
            }
            if (message == WmEndSession)
            {
                if (wParam != IntPtr.Zero)
                {
                    sessionEnded();
                }
                else
                {
                    sessionEndCancelled();
                }
            }
            return IntPtr.Zero;
        }
    }
}
