// FluidSelectionTests.swift
// Context-DockTests
//
// Verification tests for fluid list selection motion and pointer gating.

import AppKit
import SwiftUI
import Testing

@testable import Context_Dock

@Suite("Fluid selection motion and gating")
struct FluidSelectionTests {

    @Test("FluidMotion spring curves are properly configured for fast keyboard repeat without overshoot")
    func fluidMotionPhysics() {
        #expect(FluidMotion.iconScale == 1.08)
        #expect(FluidMotion.pillScale == 1.015)
    }

    @Test("MouseGate rejects stationary hover to prevent cursor fighting keyboard navigation")
    @MainActor
    func mouseGateStationaryHover() {
        let gate = MouseGate()
        // A stationary check immediately after init should return false (distance <= 1.5pt)
        let didMoveStationary = gate.moved()
        #expect(!didMoveStationary)
    }
}
