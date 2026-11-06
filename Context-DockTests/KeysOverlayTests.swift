// KeysOverlayTests.swift
// Context-DockTests
//
// Unit tests for Task UI/UX 2/5 (#332): Keys overlay (shortcuts reference) and DockKeyMap.

import Carbon.HIToolbox
import Foundation
import Testing

@testable import Context_Dock

@Suite("Keys Overlay & DockKeyMap (#332)", .serialized)
@MainActor
struct KeysOverlayTests {

    @Test("⌘/ and ⌘? trigger the Keys overlay; bare ? only triggers when allowed")
    func keysOverlayKeyRule() {
        // ⌘/ opens/toggles everywhere
        #expect(
            DockKeyRules.isKeysOverlayKey(
                keyCode: 44, command: true, control: false, option: false, shift: false
            )
        )
        // ⇧⌘/ (⌘?) opens/toggles everywhere
        #expect(
            DockKeyRules.isKeysOverlayKey(
                keyCode: 44, command: true, control: false, option: false, shift: true
            )
        )
        // Extra modifiers (⌃ or ⌥) disqualify
        #expect(
            !DockKeyRules.isKeysOverlayKey(
                keyCode: 44, command: true, control: true, option: false, shift: false
            )
        )
        #expect(
            !DockKeyRules.isKeysOverlayKey(
                keyCode: 44, command: true, control: false, option: true, shift: false
            )
        )
        // Bare / never triggers
        #expect(
            !DockKeyRules.isKeysOverlayKey(
                keyCode: 44, command: false, control: false, option: false, shift: false,
                allowsBareQuestionMark: true
            )
        )
        // Bare ? (⇧/) is rejected while typing in a field, accepted on resting dock / open overlay
        #expect(
            !DockKeyRules.isKeysOverlayKey(
                keyCode: 44, command: false, control: false, option: false, shift: true,
                allowsBareQuestionMark: false
            )
        )
        #expect(
            DockKeyRules.isKeysOverlayKey(
                keyCode: 44, command: false, control: false, option: false, shift: true,
                allowsBareQuestionMark: true
            )
        )
    }

    @Test("DockKeyMap groups active bindings across all four surfaces from canonical rules")
    func canonicalGroupsPresent() {
        DockKeyMap.resetRegisteredBindings()
        let groups = DockKeyMap.groups(settings: .shared)
        let surfaces = groups.map(\.surface)

        #expect(surfaces.contains(.launch))
        #expect(surfaces.contains(.navigation))
        #expect(surfaces.contains(.dock))
        #expect(surfaces.contains(.chatAndClipboard))

        let all = groups.flatMap(\.bindings)
        // Scope toggle (⌘), swipes, expand, menu refresh (⌘R), and overlay toggle (⌘/)
        #expect(all.contains { $0.id == "nav.commandTap" && $0.keys == ["⌘"] })
        #expect(all.contains { $0.id == "nav.verticalSwipe" && $0.keys == ["↕", "Swipe"] })
        #expect(all.contains { $0.id == "nav.horizontalSwipe" && $0.keys == ["↔", "Swipe"] })
        #expect(all.contains { $0.id == "dock.menuReread" && $0.keys == ["⌘", "R"] })
        #expect(all.contains { $0.id == "dock.keysOverlay" && $0.keys == ["⌘", "/"] })
        #expect(all.contains { $0.id == "chat.expand" && $0.keys == ["↗", "Expand"] })
        #expect(all.contains { $0.id == "clipboard.paste" && $0.keys == [DockKey.returnKey.symbol] })
    }

    @Test("Changing AppSettings hotkeys or toggles updates DockKeyMap live without drift")
    func liveAppSettingsSync() {
        let settings = AppSettings.shared
        let savedDoubleCmd = settings.useDoubleCommandGlobalContext
        let savedDoubleOpt = settings.useDoubleOptionLaunch
        let savedAppChatKey = settings.appChatHotkeyKeyCode
        let savedAppChatMods = settings.appChatHotkeyModifiers
        defer {
            settings.useDoubleCommandGlobalContext = savedDoubleCmd
            settings.useDoubleOptionLaunch = savedDoubleOpt
            settings.appChatHotkeyKeyCode = savedAppChatKey
            settings.appChatHotkeyModifiers = savedAppChatMods
            DockKeyMap.resetRegisteredBindings()
        }

        settings.useDoubleCommandGlobalContext = true
        settings.useDoubleOptionLaunch = true
        let activeLaunchIDs = DockKeyMap.groups(settings: settings)
            .first { $0.surface == .launch }?
            .bindings.map(\.id) ?? []
        #expect(activeLaunchIDs.contains("launch.doubleCommand"))
        #expect(activeLaunchIDs.contains("launch.doubleOption"))

        // Turning off ⌥⌥ removes it immediately from active bindings
        settings.useDoubleOptionLaunch = false
        let updatedLaunchIDs = DockKeyMap.groups(settings: settings)
            .first { $0.surface == .launch }?
            .bindings.map(\.id) ?? []
        #expect(!updatedLaunchIDs.contains("launch.doubleOption"))

        // Changing App Pet hotkey to ⌘⌥P (keyCode 35 = P) updates keycaps live
        settings.appChatHotkeyKeyCode = 35
        settings.appChatHotkeyModifiers = UInt32(cmdKey | optionKey)
        let appPetBinding = DockKeyMap.groups(settings: settings)
            .first { $0.surface == .launch }?
            .bindings.first { $0.id == "launch.appPet" }
        #expect(appPetBinding?.keys == ["⌘", "⌥", "P"])
    }

    @Test("Registering a new binding updates the overlay groups with no extra edit")
    func dynamicBindingRegistration() {
        DockKeyMap.resetRegisteredBindings()
        defer { DockKeyMap.resetRegisteredBindings() }

        let custom = DockKeyBinding(
            id: "dock.customTestBinding",
            surface: .dock,
            keys: ["⌘", "⇧", "T"],
            title: "Custom Test Action",
            subtitle: "Added dynamically"
        )
        DockKeyMap.register(custom)

        let dockGroup = DockKeyMap.groups(settings: .shared).first { $0.surface == .dock }
        #expect(dockGroup?.bindings.contains(custom) == true)

        DockKeyMap.unregister(id: custom.id)
        let afterRemoval = DockKeyMap.groups(settings: .shared).first { $0.surface == .dock }
        #expect(afterRemoval?.bindings.contains { $0.id == custom.id } == false)
    }

    @Test("Showing and dismissing Keys overlay preserves exact prior surface and prompt state")
    func overlayPreservesExactPriorState() {
        let prompt = AppChatPromptModel()
        let presentation = CornerChatPresentation(appChat: prompt)
        presentation.frontmostTargetProvider = { nil }

        presentation.showFrontmostApp(
            target: CornerChatTarget(
                name: "Safari",
                bundleID: "com.apple.Safari",
                suggestions: [],
                summary: "Safari"
            )
        )
        prompt.query = "open tab"
        prompt.focusedMenuIndex = 0
        prompt.focusedPillIndex = 1

        let priorMode = presentation.mode
        let priorVisible = presentation.isVisible
        let priorPhase = prompt.phase
        let priorQuery = prompt.query
        let priorMenuIndex = prompt.focusedMenuIndex
        let priorPillIndex = prompt.focusedPillIndex

        #expect(!presentation.isShowingKeysOverlay)

        // Show overlay
        presentation.toggleKeysOverlay()
        #expect(presentation.isShowingKeysOverlay)
        #expect(presentation.mode == priorMode)
        #expect(presentation.isVisible == priorVisible)
        #expect(prompt.phase == priorPhase)
        #expect(prompt.query == priorQuery)
        #expect(prompt.focusedMenuIndex == priorMenuIndex)
        #expect(prompt.focusedPillIndex == priorPillIndex)

        // Dismiss overlay — returns to exact prior state
        presentation.dismissKeysOverlay()
        #expect(!presentation.isShowingKeysOverlay)
        #expect(presentation.mode == priorMode)
        #expect(presentation.isVisible == priorVisible)
        #expect(prompt.phase == priorPhase)
        #expect(prompt.query == priorQuery)
        #expect(prompt.focusedMenuIndex == priorMenuIndex)
        #expect(prompt.focusedPillIndex == priorPillIndex)
    }
}
