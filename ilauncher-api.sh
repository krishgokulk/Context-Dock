#!/bin/bash

# ILauncher API Library for Extensions
# Source this file in your extension scripts to access native APIs
# Usage: source ilauncher-api.sh

# MEDIA API
media_get_info() {
    osascript -l JavaScript <<'EOF' 2>/dev/null
ObjC.import('stdlib');
ObjC.import('AppKit');

// Try MPNowPlayingInfoCenter
try {
    const app = Application.currentApplication();
    app.includeStandardAdditions = true;

    // Get from Music.app
    const music = Application('Music');
    if (music.running() && music.playerState() !== 'stopped') {
        const track = music.currentTrack();
        return JSON.stringify({
            title: track.name(),
            artist: track.artist(),
            album: track.album(),
            state: music.playerState(),
            duration: track.duration(),
            position: music.playerPosition()
        });
    }

    // Get from Spotify
    const spotify = Application('Spotify');
    if (spotify.running() && spotify.playerState() !== 'stopped') {
        const track = spotify.currentTrack();
        return JSON.stringify({
            title: track.name(),
            artist: track.artist(),
            album: track.album(),
            state: spotify.playerState(),
            duration: track.duration() / 1000,
            position: spotify.playerPosition()
        });
    }
} catch(e) {}

return JSON.stringify({});
EOF
}

media_get_title() {
    media_get_info | jq -r '.title // empty' 2>/dev/null
}

media_get_artist() {
    media_get_info | jq -r '.artist // empty' 2>/dev/null
}

media_get_album() {
    media_get_info | jq -r '.album // empty' 2>/dev/null
}

media_get_state() {
    media_get_info | jq -r '.state // "stopped"' 2>/dev/null
}

media_play() {
    osascript -e 'tell application "System Events" to key code 16' 2>/dev/null
}

media_pause() {
    osascript -e 'tell application "System Events" to key code 16' 2>/dev/null
}

media_next() {
    osascript -e 'tell application "System Events" to key code 17' 2>/dev/null
}

media_prev() {
    osascript -e 'tell application "System Events" to key code 18' 2>/dev/null
}

# BATTERY API
battery_get_level() {
    pmset -g batt | grep -Eo '\d+%' | cut -d% -f1
}

battery_is_charging() {
    pmset -g batt | grep -q 'AC Power' && echo "true" || echo "false"
}

battery_get_info() {
    local level=$(battery_get_level)
    local charging=$(battery_is_charging)
    echo "{\"level\": $level, \"charging\": $charging, \"percentage\": \"${level}%\"}"
}

# NETWORK API
network_get_ssid() {
    /System/Library/PrivateFrameworks/Apple80211.framework/Versions/Current/Resources/airport -I | awk '/ SSID/ {print substr($0, index($0, $2))}'
}

network_get_ip() {
    ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo ""
}

network_is_connected() {
    ping -c 1 -W 1 8.8.8.8 >/dev/null 2>&1 && echo "true" || echo "false"
}

# SYSTEM API
system_get_hostname() {
    hostname
}

system_get_uptime() {
    sysctl -n kern.boottime | awk '{print $4}' | sed 's/,//' | xargs -I {} date -r {} +%s | xargs -I {} echo $(( $(date +%s) - {} ))
}

system_get_uptime_formatted() {
    local uptime_seconds=$(system_get_uptime)
    local days=$((uptime_seconds / 86400))
    local hours=$(( (uptime_seconds % 86400) / 3600 ))
    local minutes=$(( (uptime_seconds % 3600) / 60 ))
    echo "${days}d ${hours}h ${minutes}m"
}

system_get_cpu_count() {
    sysctl -n hw.ncpu
}

system_get_memory_total() {
    sysctl -n hw.memsize | awk '{print $1 / 1024 / 1024 / 1024 " GB"}'
}

system_get_memory_used() {
    vm_stat | perl -ne '/page size of (\d+)/ and $size=$1; /Pages active:\s+(\d+)/ and printf("%.2f GB\n", $1 * $size / 1073741824);'
}

system_get_load() {
    sysctl -n vm.loadavg | awk '{print $2, $3, $4}'
}

# APP API
app_get_frontmost() {
    osascript <<'EOF' 2>/dev/null
tell application "System Events"
    set frontApp to first application process whose frontmost is true
    set appName to name of frontApp
    set appBundleID to bundle identifier of frontApp
    return appName & "|" & appBundleID
end tell
EOF
}

app_get_frontmost_name() {
    app_get_frontmost | cut -d'|' -f1
}

app_get_frontmost_bundle() {
    app_get_frontmost | cut -d'|' -f2
}

app_is_running() {
    local app_name="$1"
    pgrep -x "$app_name" >/dev/null 2>&1 && echo "true" || echo "false"
}

app_launch() {
    local app_name="$1"
    open -a "$app_name" 2>/dev/null
}

# CLIPBOARD API
clipboard_get() {
    pbpaste
}

clipboard_set() {
    echo "$1" | pbcopy
}

clipboard_clear() {
    echo -n "" | pbcopy
}

# NOTIFICATION API
notify() {
    local title="$1"
    local message="$2"
    osascript -e "display notification \"$message\" with title \"$title\"" 2>/dev/null
}

# SCREEN API
screen_get_count() {
    system_profiler SPDisplaysDataType | grep -c "Resolution:"
}

screen_get_resolution() {
    system_profiler SPDisplaysDataType | grep "Resolution:" | head -1 | awk '{print $2 " x " $4}'
}

# VOLUME API
volume_get() {
    osascript -e "output volume of (get volume settings)"
}

volume_set() {
    local level="$1"
    osascript -e "set volume output volume $level"
}

volume_mute() {
    osascript -e "set volume output muted true"
}

volume_unmute() {
    osascript -e "set volume output muted false"
}

volume_is_muted() {
    osascript -e "output muted of (get volume settings)" | grep -q "true" && echo "true" || echo "false"
}

# BRIGHTNESS API (requires sudo or specific permissions)
brightness_get() {
    # This requires additional tools like brightness-cli
    echo "0"
}

brightness_set() {
    # This requires additional tools like brightness-cli
    :
}

# WIFI API
wifi_on() {
    networksetup -setairportpower en0 on
}

wifi_off() {
    networksetup -setairportpower en0 off
}

wifi_is_on() {
    networksetup -getairportpower en0 | grep -q "On" && echo "true" || echo "false"
}

# BLUETOOTH API
bluetooth_is_on() {
    defaults read /Library/Preferences/com.apple.Bluetooth ControllerPowerState 2>/dev/null | grep -q "1" && echo "true" || echo "false"
}

# TIME API
time_get_epoch() {
    date +%s
}

time_get_iso() {
    date -u +"%Y-%m-%dT%H:%M:%SZ"
}

time_get_formatted() {
    local format="${1:-%Y-%m-%d %H:%M:%S}"
    date +"$format"
}

# WEATHER API (requires external service)
weather_get() {
    local location="${1:-}"
    curl -s "wttr.in/$location?format=j1" 2>/dev/null | jq -r '.current_condition[0] | "\(.temp_C)°C \(.weatherDesc[0].value)"' 2>/dev/null
}

weather_get_temp() {
    local location="${1:-}"
    curl -s "wttr.in/$location?format=%t" 2>/dev/null
}

# PROCESS API
process_list() {
    ps aux | awk 'NR>1 {print $2, $11}'
}

process_kill() {
    local pid="$1"
    kill "$pid" 2>/dev/null
}

process_cpu_usage() {
    ps aux | sort -nrk 3,3 | head -n 5
}

process_memory_usage() {
    ps aux | sort -nrk 4,4 | head -n 5
}

# DISK API
disk_get_usage() {
    df -h / | awk 'NR==2 {print $5}'
}

disk_get_free() {
    df -h / | awk 'NR==2 {print $4}'
}

disk_get_total() {
    df -h / | awk 'NR==2 {print $2}'
}

# CALENDAR API
calendar_get_date() {
    date +"%Y-%m-%d"
}

calendar_get_day_of_week() {
    date +"%A"
}

calendar_get_week_number() {
    date +"%V"
}

# HELP
ilauncher_api_help() {
    cat <<'HELP'
ILauncher API - Available Functions:

MEDIA:
  media_get_info                - Get full media info (JSON)
  media_get_title               - Get current track title
  media_get_artist              - Get current artist
  media_get_album               - Get current album
  media_get_state               - Get playback state
  media_play                    - Play
  media_pause                   - Pause
  media_next                    - Next track
  media_prev                    - Previous track

BATTERY:
  battery_get_level             - Get battery percentage
  battery_is_charging           - Check if charging
  battery_get_info              - Get full battery info (JSON)

NETWORK:
  network_get_ssid              - Get WiFi SSID
  network_get_ip                - Get local IP
  network_is_connected          - Check internet connectivity

SYSTEM:
  system_get_hostname           - Get hostname
  system_get_uptime             - Get uptime (seconds)
  system_get_uptime_formatted   - Get uptime (formatted)
  system_get_cpu_count          - Get CPU count
  system_get_memory_total       - Get total memory
  system_get_memory_used        - Get used memory
  system_get_load               - Get system load

APP:
  app_get_frontmost             - Get frontmost app
  app_get_frontmost_name        - Get frontmost app name
  app_get_frontmost_bundle      - Get frontmost app bundle ID
  app_is_running <name>         - Check if app is running
  app_launch <name>             - Launch application

CLIPBOARD:
  clipboard_get                 - Get clipboard content
  clipboard_set <text>          - Set clipboard content
  clipboard_clear               - Clear clipboard

NOTIFICATION:
  notify <title> <message>      - Send notification

VOLUME:
  volume_get                    - Get volume level
  volume_set <level>            - Set volume (0-100)
  volume_mute                   - Mute volume
  volume_unmute                 - Unmute volume
  volume_is_muted               - Check if muted

DISK:
  disk_get_usage                - Get disk usage percentage
  disk_get_free                 - Get free disk space
  disk_get_total                - Get total disk space

TIME:
  time_get_epoch                - Get Unix timestamp
  time_get_iso                  - Get ISO 8601 timestamp
  time_get_formatted [format]   - Get formatted time

WEATHER:
  weather_get [location]        - Get weather info
  weather_get_temp [location]   - Get temperature

EXAMPLE USAGE:
  #!/bin/bash
  source ilauncher-api.sh

  # Get current playing song
  title=$(media_get_title)
  artist=$(media_get_artist)
  echo "♫ $title - $artist"

  # Get battery status
  level=$(battery_get_level)
  echo "🔋 $level%"

  # Get WiFi info
  ssid=$(network_get_ssid)
  echo "📶 $ssid"
HELP
}
