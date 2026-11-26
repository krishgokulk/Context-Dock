#!/usr/bin/env python3
import os
import subprocess
import sys


def main():
    nid = os.environ.get("DORAX_ACTION_VALUE", "").strip()
    if not nid:
        subprocess.run(["/usr/bin/open", "-a", "Notes"], check=False, timeout=4)
        print("Opened Notes")
        return
    as_code = '''
on run argv
    set targetID to item 1 of argv
    tell application "Notes"
        activate
        try
            show note id targetID
        end try
    end tell
end run
'''
    subprocess.run(["/usr/bin/osascript", "-e", as_code, "--", nid], capture_output=True, text=True, timeout=5)
    print("Opened note in Apple Notes")


if __name__ == "__main__":
    main()
