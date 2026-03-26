/**
 * ILauncher TypeScript/JavaScript API
 * Provides access to all Apple app data and system information
 */

import { exec } from 'child_process';
import { promisify } from 'util';

const execAsync = promisify(exec);

export class ILauncherAPI {
  // MARK: - Media API

  static async mediaGetInfo(): Promise<{ title?: string; artist?: string; state?: string }> {
    const script = `
      tell application "Music"
        if player state is not stopped then
          return {title:(name of current track), artist:(artist of current track), state:(player state as text)}
        end if
      end tell
    `;
    return await this.runAppleScript(script);
  }

  static async mediaGetTitle(): Promise<string> {
    const info = await this.mediaGetInfo();
    return info.title || '';
  }

  static async mediaGetArtist(): Promise<string> {
    const info = await this.mediaGetInfo();
    return info.artist || '';
  }

  static async mediaPlay(): Promise<void> {
    await this.sendKeyCode(16);
  }

  static async mediaPause(): Promise<void> {
    await this.sendKeyCode(16);
  }

  static async mediaNext(): Promise<void> {
    await this.sendKeyCode(17);
  }

  static async mediaPrev(): Promise<void> {
    await this.sendKeyCode(18);
  }

  // MARK: - Calendar API

  static async calendarGetEvents(limit: number = 10): Promise<any[]> {
    // Would use AppleScript to get events
    return [];
  }

  static async calendarGetNextEvent(): Promise<any> {
    const events = await this.calendarGetEvents(1);
    return events[0] || null;
  }

  // MARK: - Mail API

  static async mailGetUnreadCount(): Promise<number> {
    const script = 'tell application "Mail" to count of (every message of inbox whose read status is false)';
    const result = await this.runAppleScript(script);
    return parseInt(result) || 0;
  }

  static async mailGetRecent(limit: number = 10): Promise<any[]> {
    return [];
  }

  // MARK: - Battery API

  static async batteryGetLevel(): Promise<number> {
    const result = await this.runShell("pmset -g batt | grep -Eo '\\d+%' | cut -d% -f1");
    return parseInt(result) || 0;
  }

  static async batteryIsCharging(): Promise<boolean> {
    try {
      await this.runShell("pmset -g batt | grep -q 'AC Power'");
      return true;
    } catch {
      return false;
    }
  }

  static async batteryGetInfo(): Promise<{ level: number; charging: boolean }> {
    return {
      level: await this.batteryGetLevel(),
      charging: await this.batteryIsCharging()
    };
  }

  // MARK: - Network API

  static async networkGetSSID(): Promise<string> {
    const script = "/System/Library/PrivateFrameworks/Apple80211.framework/Versions/Current/Resources/airport -I | awk '/ SSID/ {print substr($0, index($0, $2))}'";
    return await this.runShell(script);
  }

  static async networkGetIP(): Promise<string> {
    return await this.runShell("ipconfig getifaddr en0");
  }

  static async networkIsConnected(): Promise<boolean> {
    try {
      await this.runShell("ping -c 1 -W 1 8.8.8.8");
      return true;
    } catch {
      return false;
    }
  }

  // MARK: - System API

  static async systemGetHostname(): Promise<string> {
    return await this.runShell("hostname");
  }

  static async systemGetUptime(): Promise<number> {
    const result = await this.runShell("sysctl -n kern.boottime | awk '{print $4}' | sed 's/,//'");
    const bootTime = parseInt(result);
    return Math.floor(Date.now() / 1000) - bootTime;
  }

  static async systemGetCPUCount(): Promise<number> {
    const result = await this.runShell("sysctl -n hw.ncpu");
    return parseInt(result) || 0;
  }

  // MARK: - App API

  static async appGetFrontmost(): Promise<{ name: string; bundle: string }> {
    const script = `
      tell application "System Events"
        set frontApp to first application process whose frontmost is true
        return {name:(name of frontApp), bundle:(bundle identifier of frontApp)}
      end tell
    `;
    return await this.runAppleScript(script);
  }

  static async appLaunch(name: string): Promise<void> {
    await this.runShell(`open -a "${name}"`);
  }

  static async appIsRunning(name: string): Promise<boolean> {
    try {
      await this.runShell(`pgrep -x "${name}"`);
      return true;
    } catch {
      return false;
    }
  }

  // MARK: - Clipboard API

  static async clipboardGet(): Promise<string> {
    return await this.runShell("pbpaste");
  }

  static async clipboardSet(text: string): Promise<void> {
    await this.runShell(`echo "${text}" | pbcopy`);
  }

  // MARK: - Notification API

  static async notify(title: string, message: string): Promise<void> {
    const script = `display notification "${message}" with title "${title}"`;
    await this.runAppleScript(script);
  }

  // MARK: - Volume API

  static async volumeGet(): Promise<number> {
    const result = await this.runAppleScript("output volume of (get volume settings)");
    return parseInt(result) || 0;
  }

  static async volumeSet(level: number): Promise<void> {
    await this.runAppleScript(`set volume output volume ${level}`);
  }

  static async volumeMute(): Promise<void> {
    await this.runAppleScript("set volume output muted true");
  }

  static async volumeUnmute(): Promise<void> {
    await this.runAppleScript("set volume output muted false");
  }

  // MARK: - Weather API

  static async weatherGet(location: string = ''): Promise<string> {
    try {
      const result = await this.runShell(`curl -s "wttr.in/${location}?format=j1"`);
      const data = JSON.parse(result);
      const current = data.current_condition[0];
      return `${current.temp_C}°C ${current.weatherDesc[0].value}`;
    } catch {
      return '';
    }
  }

  // MARK: - Helper Methods

  private static async runShell(command: string): Promise<string> {
    const { stdout } = await execAsync(command);
    return stdout.trim();
  }

  private static async runAppleScript(script: string): Promise<any> {
    try {
      const { stdout } = await execAsync(`osascript -e '${script}'`);
      return stdout.trim();
    } catch (error) {
      return null;
    }
  }

  private static async sendKeyCode(code: number): Promise<void> {
    await this.runAppleScript(`tell application "System Events" to key code ${code}`);
  }
}

// Export convenience namespaces
export const media = ILauncherAPI;
export const calendar = ILauncherAPI;
export const mail = ILauncherAPI;
export const battery = ILauncherAPI;
export const network = ILauncherAPI;
export const system = ILauncherAPI;
export const app = ILauncherAPI;
export const clipboard = ILauncherAPI;
export const notify = ILauncherAPI.notify;
export const volume = ILauncherAPI;
export const weather = ILauncherAPI;

// Example usage
if (require.main === module) {
  (async () => {
    console.log('=== ILauncher TypeScript API Demo ===\n');

    console.log(`Media: ${await media.mediaGetTitle()}`);
    console.log(`Battery: ${await battery.batteryGetLevel()}%`);
    console.log(`WiFi: ${await network.networkGetSSID()}`);
    console.log(`Unread Mail: ${await mail.mailGetUnreadCount()}`);
    console.log(`Hostname: ${await system.systemGetHostname()}`);
  })();
}
