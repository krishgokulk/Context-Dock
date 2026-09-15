// Context-Dock
//
// The manifests the Developer Inspector previews before any plugin is installed. They exist so
// the kit can be looked at by a person on a clean machine, and so the exit condition of Phase 2
// is something a test can hold: both of these validate, and both draw in every host they
// declare.
//
// Sonos is the spec's own example (§7). Its `sample` here carries a real queue, where the
// spec's copy has an empty one — an empty queue previews as the empty state, which says
// nothing about whether rows work.

import Foundation

enum PluginExamples {
    static let sonosJSON = """
    {
      "id": "sonos-now-playing", "name": "Sonos", "icon": "hifispeaker.fill",
      "keywords": ["sonos", "music"], "inputs": ["query"],
      "actions": {
        "toggle": { "type": "bash", "script": "actions/toggle.sh", "optimistic": "playing" },
        "volume": { "type": "bash", "script": "actions/volume.sh", "risk": "low" },
        "play":   { "type": "bash", "script": "actions/play.sh" },
        "openApp": { "type": "open", "app": "Sonos" }
      },
      "permissions": ["network:local"],
      "sample": {
        "room": "Kitchen +1", "playing": true, "art": "hifispeaker.fill",
        "track": "Jungle", "artist": "Casio",
        "queue": [
          { "id": "t1", "title": "Jungle", "artist": "Casio", "accessories": ["3:41"] },
          { "id": "t2", "title": "For Ever", "artist": "Casio", "accessories": ["4:12"] },
          { "id": "t3", "title": "Talkie Walkie", "artist": "Air", "accessories": ["3:58"] }
        ]
      },
      "agent": { "instructions": "Rooms, queue, volume.", "tools": ["toggle", "volume"] },
      "views": {
        "icon":   { "capsule": [ { "thumbnail": "{{art}}" }, { "waveform": "{{playing}}" } ] },
        "widget": { "family": "medium",
                    "root": { "mediaCard": { "title": "{{room}}", "track": "{{track}}",
                                             "artist": "{{artist}}", "art": "{{art}}",
                                             "transport": "toggle", "volume": "volume" } } },
        "panel":  { "vstack": [
                      { "mediaCard": { "title": "{{room}}", "track": "{{track}}",
                                       "artist": "{{artist}}", "art": "{{art}}",
                                       "transport": "toggle" } },
                      { "section": { "header": "Up next", "children": [
                          { "list": { "filter": "local", "items": "{{queue}}",
                                      "row": { "title": "{{item.title}}",
                                               "subtitle": "{{item.artist}}",
                                               "accessories": "{{item.accessories}}",
                                               "actions": [ { "title": "Play", "action": "play",
                                                              "value": "{{item.id}}" } ] } } } ] } }
                    ] },
        "window": { "width": "regular",
                    "root": { "vstack": [
                        { "title": "Up next" },
                        { "listDetail": { "items": "{{queue}}",
                                          "row": { "title": "{{item.title}}",
                                                   "subtitle": "{{item.artist}}" },
                                          "detail": { "markdown": "**{{item.title}}**",
                                                      "metadata": [ { "title": "Artist",
                                                                      "text": "{{item.artist}}" } ] } } }
                      ] } }
      }
    }
    """

    /// A second example on purpose: it exercises the half of the kit Sonos does not touch —
    /// a grid, the status words, the controls, a form and the panel states.
    static let releasesJSON = """
    {
      "id": "build-board", "name": "Build Board", "icon": "hammer.fill",
      "keywords": ["build", "ci"], "inputs": ["query"],
      "actions": {
        "rerun":  { "type": "bash", "script": "actions/rerun.sh" },
        "notify": { "type": "bash", "script": "actions/notify.sh" },
        "save":   { "type": "bash", "script": "actions/save.sh", "risk": "low" }
      },
      "sample": {
        "passing": 0.72, "watching": true, "elapsed": "04:12",
        "runs": [
          { "title": "web · main", "status": "success" },
          { "title": "api · main", "status": "running" },
          { "title": "docs · pr-91", "status": "failed" }
        ],
        "shots": [ { "art": "photo" }, { "art": "photo" }, { "art": "photo" },
                   { "art": "photo" }, { "art": "photo" }, { "art": "photo" } ]
      },
      "views": {
        "panel": { "vstack": [
            { "card": [
                { "header": { "text": "This week", "icon": "chart.bar.fill" } },
                { "hstack": [ { "stat": { "value": "72", "label": "Passing", "delta": "+4" } },
                              { "progress": { "value": "{{passing}}" } } ] },
                { "hstack": [ { "statusBadge": "running" }, { "timer": "{{elapsed}}" },
                              { "pulse": { "status": "running" } } ] }
              ] },
            { "section": { "header": "Runs", "children": [
                { "list": { "items": "{{runs}}",
                            "row": { "title": "{{item.title}}",
                                     "actions": [ { "title": "Re-run", "action": "rerun" } ] } } }
              ] } },
            { "grid": { "columns": 6, "items": "{{shots}}",
                        "cell": { "thumbnail": "{{item.art}}" } } },
            { "buttonRow": [ { "button": { "title": "Re-run all", "action": "rerun" } },
                             { "toggle": { "title": "Watch", "action": "notify",
                                           "value": "{{watching}}" } } ] },
            { "form": { "submit": "save",
                        "fields": [ { "key": "branch", "label": "Branch", "kind": "text" },
                                    { "key": "notify", "label": "Notify me", "kind": "toggle" } ] } }
          ] }
      }
    }
    """

    static let sonos: PluginManifest = decode(sonosJSON)
    static let releases: PluginManifest = decode(releasesJSON)

    static var all: [PluginManifest] { [sonos, releases] }

    /// These are compiled-in constants, so a failure here is a build-time mistake in this file
    /// rather than anything a user can cause — an empty manifest keeps the Inspector alive to
    /// say so instead of taking the app down at launch.
    private static func decode(_ json: String) -> PluginManifest {
        (try? JSONDecoder().decode(PluginManifest.self, from: Data(json.utf8)))
            ?? PluginManifest(id: "example-broken", name: "Example failed to decode")
    }
}
