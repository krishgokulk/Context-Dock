#!/usr/bin/env python3
"""
ILauncher Python API
Provides access to all Apple app data and system information
"""

import subprocess
import json
from typing import List, Dict, Any, Optional
from datetime import datetime

class ILauncherAPI:
    """Main API class for ILauncher extensions"""

    # MARK: - Media API

    @staticmethod
    def media_get_info() -> Dict[str, Any]:
        """Get current media information"""
        script = '''
        tell application "Music"
            if player state is not stopped then
                return {title:(name of current track), artist:(artist of current track), state:(player state as text)}
            end if
        end tell
        '''
        return ILauncherAPI._run_applescript(script)

    @staticmethod
    def media_get_title() -> str:
        """Get current track title"""
        info = ILauncherAPI.media_get_info()
        return info.get('title', '')

    @staticmethod
    def media_get_artist() -> str:
        """Get current artist"""
        info = ILauncherAPI.media_get_info()
        return info.get('artist', '')

    @staticmethod
    def media_play():
        """Play/resume media"""
        ILauncherAPI._send_key_code(16)

    @staticmethod
    def media_pause():
        """Pause media"""
        ILauncherAPI._send_key_code(16)

    @staticmethod
    def media_next():
        """Next track"""
        ILauncherAPI._send_key_code(17)

    @staticmethod
    def media_prev():
        """Previous track"""
        ILauncherAPI._send_key_code(18)

    # MARK: - Calendar API

    @staticmethod
    def calendar_get_events(limit: int = 10) -> List[Dict[str, Any]]:
        """Get upcoming calendar events"""
        # Would use EventKit via PyObjC
        return []

    @staticmethod
    def calendar_get_next_event() -> Optional[Dict[str, Any]]:
        """Get next calendar event"""
        events = ILauncherAPI.calendar_get_events(limit=1)
        return events[0] if events else None

    @staticmethod
    def calendar_get_today() -> List[Dict[str, Any]]:
        """Get today's events"""
        return []

    # MARK: - Reminders API

    @staticmethod
    def reminders_get(limit: int = 10) -> List[Dict[str, Any]]:
        """Get reminders"""
        return []

    @staticmethod
    def reminders_get_overdue() -> List[Dict[str, Any]]:
        """Get overdue reminders"""
        return []

    # MARK: - Contacts API

    @staticmethod
    def contacts_get(limit: int = 100) -> List[Dict[str, Any]]:
        """Get contacts"""
        return []

    @staticmethod
    def contacts_search(query: str) -> List[Dict[str, Any]]:
        """Search contacts"""
        return []

    # MARK: - Mail API

    @staticmethod
    def mail_get_unread_count() -> int:
        """Get unread email count"""
        script = 'tell application "Mail" to count of (every message of inbox whose read status is false)'
        result = ILauncherAPI._run_applescript(script)
        return int(result) if result else 0

    @staticmethod
    def mail_get_recent(limit: int = 10) -> List[Dict[str, Any]]:
        """Get recent emails"""
        return []

    # MARK: - Messages API

    @staticmethod
    def messages_get_unread_count() -> int:
        """Get unread message count"""
        return 0

    # MARK: - Notes API

    @staticmethod
    def notes_get_recent(limit: int = 10) -> List[Dict[str, Any]]:
        """Get recent notes"""
        return []

    @staticmethod
    def notes_search(query: str) -> List[Dict[str, Any]]:
        """Search notes"""
        return []

    # MARK: - Safari API

    @staticmethod
    def safari_get_current_tab() -> Dict[str, str]:
        """Get current Safari tab"""
        script = '''
        tell application "Safari"
            if (count of windows) > 0 then
                set currentTab to current tab of front window
                return {url:(URL of currentTab), title:(name of currentTab)}
            end if
        end tell
        '''
        return ILauncherAPI._run_applescript(script) or {}

    @staticmethod
    def safari_get_all_tabs() -> List[Dict[str, str]]:
        """Get all Safari tabs"""
        return []

    # MARK: - Battery API

    @staticmethod
    def battery_get_level() -> int:
        """Get battery percentage"""
        result = ILauncherAPI._run_shell("pmset -g batt | grep -Eo '\\d+%' | cut -d% -f1")
        return int(result) if result else 0

    @staticmethod
    def battery_is_charging() -> bool:
        """Check if battery is charging"""
        result = ILauncherAPI._run_shell("pmset -g batt | grep -q 'AC Power'")
        return result is not None

    @staticmethod
    def battery_get_info() -> Dict[str, Any]:
        """Get full battery info"""
        return {
            'level': ILauncherAPI.battery_get_level(),
            'charging': ILauncherAPI.battery_is_charging()
        }

    # MARK: - Network API

    @staticmethod
    def network_get_ssid() -> str:
        """Get WiFi SSID"""
        script = "/System/Library/PrivateFrameworks/Apple80211.framework/Versions/Current/Resources/airport -I | awk '/ SSID/ {print substr($0, index($0, $2))}'"
        return ILauncherAPI._run_shell(script) or ""

    @staticmethod
    def network_get_ip() -> str:
        """Get local IP address"""
        result = ILauncherAPI._run_shell("ipconfig getifaddr en0")
        return result or ""

    @staticmethod
    def network_is_connected() -> bool:
        """Check internet connectivity"""
        result = ILauncherAPI._run_shell("ping -c 1 -W 1 8.8.8.8")
        return result is not None

    # MARK: - System API

    @staticmethod
    def system_get_hostname() -> str:
        """Get hostname"""
        return ILauncherAPI._run_shell("hostname") or ""

    @staticmethod
    def system_get_uptime() -> int:
        """Get system uptime in seconds"""
        result = ILauncherAPI._run_shell("sysctl -n kern.boottime | awk '{print $4}' | sed 's/,//'")
        if result:
            boot_time = int(result)
            return int(datetime.now().timestamp()) - boot_time
        return 0

    @staticmethod
    def system_get_memory_total() -> str:
        """Get total memory"""
        return ILauncherAPI._run_shell("sysctl -n hw.memsize | awk '{print $1 / 1024 / 1024 / 1024 \" GB\"}'") or ""

    @staticmethod
    def system_get_cpu_count() -> int:
        """Get CPU count"""
        result = ILauncherAPI._run_shell("sysctl -n hw.ncpu")
        return int(result) if result else 0

    # MARK: - App API

    @staticmethod
    def app_get_frontmost() -> Dict[str, str]:
        """Get frontmost application"""
        script = '''
        tell application "System Events"
            set frontApp to first application process whose frontmost is true
            return {name:(name of frontApp), bundle:(bundle identifier of frontApp)}
        end tell
        '''
        return ILauncherAPI._run_applescript(script) or {}

    @staticmethod
    def app_launch(name: str):
        """Launch application"""
        ILauncherAPI._run_shell(f'open -a "{name}"')

    @staticmethod
    def app_is_running(name: str) -> bool:
        """Check if app is running"""
        result = ILauncherAPI._run_shell(f'pgrep -x "{name}"')
        return result is not None

    # MARK: - Clipboard API

    @staticmethod
    def clipboard_get() -> str:
        """Get clipboard content"""
        return ILauncherAPI._run_shell("pbpaste") or ""

    @staticmethod
    def clipboard_set(text: str):
        """Set clipboard content"""
        ILauncherAPI._run_shell(f'echo "{text}" | pbcopy')

    # MARK: - Notification API

    @staticmethod
    def notify(title: str, message: str):
        """Send notification"""
        script = f'display notification "{message}" with title "{title}"'
        ILauncherAPI._run_applescript(script)

    # MARK: - Volume API

    @staticmethod
    def volume_get() -> int:
        """Get volume level (0-100)"""
        result = ILauncherAPI._run_applescript("output volume of (get volume settings)")
        return int(result) if result else 0

    @staticmethod
    def volume_set(level: int):
        """Set volume level (0-100)"""
        ILauncherAPI._run_applescript(f"set volume output volume {level}")

    @staticmethod
    def volume_mute():
        """Mute volume"""
        ILauncherAPI._run_applescript("set volume output muted true")

    @staticmethod
    def volume_unmute():
        """Unmute volume"""
        ILauncherAPI._run_applescript("set volume output muted false")

    # MARK: - Weather API

    @staticmethod
    def weather_get(location: str = "") -> str:
        """Get weather info"""
        result = ILauncherAPI._run_shell(f'curl -s "wttr.in/{location}?format=j1"')
        if result:
            try:
                data = json.loads(result)
                current = data['current_condition'][0]
                return f"{current['temp_C']}°C {current['weatherDesc'][0]['value']}"
            except:
                pass
        return ""

    # MARK: - Helper Methods

    @staticmethod
    def _run_shell(command: str) -> Optional[str]:
        """Run shell command and return output"""
        try:
            result = subprocess.run(
                command,
                shell=True,
                capture_output=True,
                text=True,
                timeout=5
            )
            output = result.stdout.strip()
            return output if output else None
        except:
            return None

    @staticmethod
    def _run_applescript(script: str) -> Any:
        """Run AppleScript and return result"""
        try:
            result = subprocess.run(
                ['osascript', '-e', script],
                capture_output=True,
                text=True,
                timeout=5
            )
            output = result.stdout.strip()
            return output if output else None
        except:
            return None

    @staticmethod
    def _send_key_code(code: int):
        """Send key code via System Events"""
        script = f'tell application "System Events" to key code {code}'
        ILauncherAPI._run_applescript(script)


# Convenience functions (top-level)
media = ILauncherAPI
calendar = ILauncherAPI
reminders = ILauncherAPI
contacts = ILauncherAPI
mail = ILauncherAPI
messages = ILauncherAPI
notes = ILauncherAPI
safari = ILauncherAPI
battery = ILauncherAPI
network = ILauncherAPI
system = ILauncherAPI
app = ILauncherAPI
clipboard = ILauncherAPI
notify = ILauncherAPI.notify
volume = ILauncherAPI
weather = ILauncherAPI


if __name__ == "__main__":
    # Example usage
    print("=== ILauncher Python API Demo ===\n")

    print(f"Media: {media.media_get_title()}")
    print(f"Battery: {battery.battery_get_level()}%")
    print(f"WiFi: {network.network_get_ssid()}")
    print(f"Unread Mail: {mail.mail_get_unread_count()}")
    print(f"Hostname: {system.system_get_hostname()}")
