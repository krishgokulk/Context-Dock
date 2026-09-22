// Context-DockTests/CapabilityRiskGateTests.swift
//
// The one question every approval path asks. It is worth its own test because the answer was
// written as a list of two levels, and the list had a hole in it: `.critical` — the level
// reserved for the most dangerous things — was the only one above `.low` that ran unasked.

import Foundation
import Testing

@testable import Context_Dock

struct CapabilityRiskGateTests {
    @Test("Only the lowest level runs without being asked")
    func everyLevelAboveLowRequiresApproval() {
        // Iterated rather than listed, deliberately: a level added later fails this test
        // instead of quietly inheriting "no approval needed", which is how .critical was
        // missed in the first place.
        for level in AICapabilityRiskLevel.allCases {
            #expect(level.requiresApproval == (level != .low), "\(level.rawValue)")
        }
    }

    @Test("The most dangerous level is not the one that skips the gate")
    func criticalAsksFirst() {
        #expect(AICapabilityRiskLevel.critical.requiresApproval)
        #expect(AICapabilityRiskLevel.high.requiresApproval)
        #expect(AICapabilityRiskLevel.medium.requiresApproval)
        #expect(AICapabilityRiskLevel.low.requiresApproval == false)
    }

    @Test("A plugin's risk still lands on a level that asks")
    func pluginRiskMapsAboveTheGate() {
        // PluginCapability avoided .critical while it was exempt. Now that it is not, the
        // mapping can carry the distinction again — but the guarantee is the same either way:
        // anything above a plugin's `read` asks.
        #expect(PluginCapability.riskLevel(.read).requiresApproval == false)
        for risk in [PluginRisk.low, .medium, .high] {
            #expect(PluginCapability.riskLevel(risk).requiresApproval, "\(risk.rawValue)")
        }
    }
}
