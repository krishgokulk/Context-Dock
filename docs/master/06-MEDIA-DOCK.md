# 06 — Media Dock

> **Status: DRAFT / under review — written against current code (audit-clean).** Not merged yet.
> Tags: `[code]` verified in source · `[owner]` owner's stated knowledge · `[?]` needs confirmation.

---

## 1. One job

**Media Dock = the media layer.** `[code — PRODUCT_LAYERS.md]` Show current media state and
media actions, and control what's playing. **Not** a chat surface, **not** universal search —
only media state and media actions.

---

## 2. What the user sees

Now-playing state — title, artist, album, playing/paused — and transport controls
(play/pause, next, previous, seek). `[code — MediaDockEngine.swift]`

---

## 3. How it works

- **`MediaDockEngine`** (`@MainActor`, `ObservableObject`) publishes `title`, `artist`,
  `album`, `isPlaying`, refreshed on a timer. `[code]`
- **`MediaRemoteBridge`** talks to macOS's **private `MediaRemote` framework**, loaded via
  `dlopen` — **never linked directly** against the private framework. `[code]` Commands
  (`MRCommand`): play, pause, togglePlayPause, nextTrack, previousTrack, beginSeekForward,
  endSeekForward, … This is how DoraX reads and controls system-wide media (any player, not
  just one app).
- **`MediaPlayerObserver` / `MediaInfoProvider`** observe/provide the now-playing info.
- **`AppleMusicMCPCapabilities`** exposes Apple Music as MCP capabilities for the AI engine —
  so media is also reachable *as a capability* from chat, not only from this dock.
- Surfaced in the dock via `LauncherView+L2UnifiedDockRow.swift`. `[code]`

---

## 4. Boundaries

- Not chat, not search. Media state + controls only.
- Note the **two ways media is reached**: the Media Dock (this surface, direct control) and
  the AI engine capability (`AppleMusicMCPCapabilities`). Keep them consistent but distinct.

---

## 5. Engineering map

| Concern | File |
|---|---|
| Dock engine / published state | `Services/MediaDockEngine.swift` |
| Private-framework bridge | `Services/MediaRemoteBridge.swift` |
| Now-playing observation | `Services/MediaPlayerObserver.swift`, `Services/MediaInfoProvider.swift` |
| Apple Music as MCP capability | `AI/AppleMusicMCPCapabilities.swift` |
| Dock row | `Search/LauncherView+L2UnifiedDockRow.swift` |

---

## 6. Known gaps / open questions

1. **Private-framework risk.** `MediaRemote` is private; `dlopen` avoids a link-time
   dependency but the symbols can change between macOS releases, and App Store distribution
   disallows private frameworks. Confirm this is beta/direct-distribution only. `[code] [risk]`
2. **Timer-based refresh** — polling vs event-driven now-playing updates; a timer can lag or
   waste cycles. `[?]`
3. **Scope creep risk** — the layer rule says media only; guard against it growing chat/search.
4. **No tests.** `[gap]`

---

*End of draft. Redline directly; merges after owner confirmation.*
