#!/usr/bin/env python3
import os
import subprocess


def main():
    pid_file = "/tmp/context-dock-caffeinate.pid"
    if os.path.isfile(pid_file):
        try:
            old_pid = int(open(pid_file).read().strip())
            subprocess.run(["/bin/kill", str(old_pid)], capture_output=True)
        except Exception:
            pass
        try:
            os.remove(pid_file)
        except Exception:
            pass

    val = os.environ.get("DORAX_ACTION_VALUE", "stop").strip()
    if val == "stop":
        print("Keep Awake disabled")
        return

    secs = int(val) if val.isdigit() else 0
    args = ["/usr/bin/caffeinate", "-dimsu"] + (["-t", str(secs)] if secs > 0 else [])
    proc = subprocess.Popen(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, stdin=subprocess.DEVNULL, start_new_session=True)
    with open(pid_file, "w") as fh:
        fh.write(str(proc.pid))
    print(f"Keep Awake started ({secs}s)" if secs > 0 else "Keep Awake active indefinitely")


if __name__ == "__main__":
    main()
