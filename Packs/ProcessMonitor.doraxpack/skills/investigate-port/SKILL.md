---
name: investigate-port
description: Diagnose why a localhost dev port is occupied and safely identify the owning process before stopping it.
---

# Investigate Occupied Port

1. Run `Listening Ports` or call `@process-port-monitor.inspect-port` for the target port (e.g. `3000`, `5173`, `8080`).
2. Identify the PID, executable path, and parent process.
3. Confirm whether the process is a stale dev server (e.g. `node`, `python3`, `ruby`, `vite`, `next-server`).
4. Offer a graceful `SIGTERM` first and ask the owner for confirmation before sending any kill signal.
