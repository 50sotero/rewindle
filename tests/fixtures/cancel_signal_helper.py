"""Disposable console helper for the cooperative Ctrl-Break integration test."""

from __future__ import annotations

import signal
import time


def handle_break(_signal_number, _frame) -> None:
    print("ctrl_break_received", flush=True)
    print("cleanup_complete", flush=True)
    raise SystemExit(130)


signal.signal(signal.SIGBREAK, handle_break)
print("ready", flush=True)
while True:
    time.sleep(0.05)
