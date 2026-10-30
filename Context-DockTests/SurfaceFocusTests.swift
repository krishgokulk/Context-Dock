// SurfaceFocusTests.swift
// Context-DockTests
//
// #318: Global Context and the frontmost app are one surface; focus is the only difference.
// One case per key/swipe/focus, so the key map and the swipes cannot drift apart.

import Testing

@testable import Context_Dock

@Suite("Surface focus")
struct SurfaceFocusTests {

    private let safariPet = AppPetID.app(bundleID: "com.apple.Safari")
    private let mailPet = AppPetID.app(bundleID: "com.apple.mail")
    private let brewPet = AppPetID.cli(command: "brew")

    @Test("⌘ zooms out from the frontmost app, back in from Global, and comes home from every selected Pet")
    func commandTapZooms() {
        #expect(SurfaceFocusRules.decide(.commandTap, from: .frontmost) == .focus(.global))
        #expect(SurfaceFocusRules.decide(.commandTap, from: .global) == .focus(.frontmost))
        #expect(SurfaceFocusRules.decide(.commandTap, from: .pet(safariPet)) == .focus(.global))
        #expect(SurfaceFocusRules.decide(.commandTap, from: .pet(mailPet)) == .focus(.global))
        #expect(SurfaceFocusRules.decide(.commandTap, from: .pet(brewPet)) == .focus(.global))
    }

    @Test("↑ / swipe down zooms out once; ↓ / swipe up zooms in to the real frontmost Pet, not the previously selected Pet; neither end wraps")
    func layersDoNotWrap() {
        #expect(SurfaceFocusRules.decide(.zoomOut, from: .frontmost) == .focus(.global))
        #expect(SurfaceFocusRules.decide(.zoomOut, from: .global) == .none)
        #expect(SurfaceFocusRules.decide(.zoomOut, from: .pet(safariPet)) == .none)
        #expect(SurfaceFocusRules.decide(.zoomIn, from: .global) == .focus(.frontmost))
        #expect(SurfaceFocusRules.decide(.zoomIn, from: .pet(safariPet)) == .focus(.frontmost))
        #expect(SurfaceFocusRules.decide(.zoomIn, from: .pet(mailPet)) == .focus(.frontmost))
        #expect(SurfaceFocusRules.decide(.zoomIn, from: .frontmost) == .none)
    }

    @Test("→ steps into a specified Pet from every focus")
    func rightArrowStepsIn() {
        for focus in [SurfaceFocus.frontmost, .global, .pet(safariPet)] {
            #expect(SurfaceFocusRules.decide(.stepIn(mailPet), from: focus) == .focus(.pet(mailPet)))
        }
    }

    @Test("← off the first app and Backspace return every selected Pet to Global; nowhere else to go from Global or the front app")
    func leavingAnAppGoesHome() {
        #expect(SurfaceFocusRules.decide(.leaveApp, from: .pet(safariPet)) == .focus(.global))
        #expect(SurfaceFocusRules.decide(.leaveApp, from: .pet(mailPet)) == .focus(.global))
        #expect(SurfaceFocusRules.decide(.leaveApp, from: .pet(brewPet)) == .focus(.global))
        #expect(SurfaceFocusRules.decide(.leaveApp, from: .global) == .none)
        #expect(SurfaceFocusRules.decide(.leaveApp, from: .frontmost) == .none)
    }

    @Test("Layer keys and swipes agree: CornerNavigation lands where SurfaceFocusRules says")
    func navigationAgreesWithFocusRules() {
        let a = CornerChatMode.frontmostApp, g = CornerChatMode.globalContext
        #expect(CornerNavigation.destination(for: .layerUp, from: a, origin: a) == g)
        #expect(CornerNavigation.destination(for: .layerDown, from: g, origin: g) == a)
        #expect(CornerNavigation.destination(for: .layerUp, from: g, origin: g) == nil)
        #expect(CornerNavigation.destination(for: .layerDown, from: a, origin: a) == nil)
        // A swipe is the same move as its key.
        #expect(CornerSwipe.classify(dx: 0, dy: 80) == .layerUp)
        #expect(CornerSwipe.classify(dx: 0, dy: -80) == .layerDown)
    }
}
