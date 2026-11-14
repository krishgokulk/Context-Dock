// DetachedPetManager.swift
// Context-Dock
//
// Manager coordinating all floating desktop Pet companions (#342).
// Multiple detached Pets can coexist over the shared DoraX engine and conversation stores.

import AppKit
import Combine
import Foundation

@MainActor
final class DetachedPetManager: ObservableObject {
    static let shared = DetachedPetManager()

    @Published private(set) var activeControllers: [AppPetID: DetachedPetController] = [:]

    private init() {}

    /// True if a desktop companion is currently detached for this Pet.
    func isDetached(petID: AppPetID) -> Bool {
        activeControllers[petID.normalized] != nil
    }

    /// True if a desktop companion is currently detached for this bundle ID.
    func isDetached(bundleID: String) -> Bool {
        guard let petID = AppPetID(dockBundleID: bundleID) else { return false }
        return isDetached(petID: petID)
    }

    /// Detach a Pet icon onto the desktop at the specified coordinates.
    @discardableResult
    func detachPet(
        petID: AppPetID,
        appName: String,
        icon: NSImage? = nil,
        at screenPoint: CGPoint = .zero
    ) -> DetachedPetController {
        let normalizedID = petID.normalized

        // If already detached, bring to front and optionally move
        if let existing = activeControllers[normalizedID] {
            if screenPoint != .zero {
                existing.panel.setFrameOrigin(screenPoint)
            }
            existing.show()
            return existing
        }

        let bundleID = petID.bundleID ?? petID.dockBundleID
        let controller = DetachedPetController(
            petID: normalizedID,
            appName: appName,
            bundleID: bundleID,
            initialPosition: screenPoint == .zero
                ? DetachedPetController.defaultScreenPosition(slot: activeControllers.count)
                : screenPoint,
            appIcon: icon
        )

        activeControllers[normalizedID] = controller
        controller.show()

        // Persist detached state
        let record = DetachedPetRecord(
            petID: normalizedID,
            appName: appName,
            bundleID: bundleID,
            position: screenPoint
        )
        DetachedPetStore.upsertRecord(record)

        return controller
    }

    /// Reattach a detached companion back to the Dock without losing conversation or memory.
    func reattachPet(petID: AppPetID) {
        let normalizedID = petID.normalized
        guard let controller = activeControllers.removeValue(forKey: normalizedID) else { return }

        controller.close()
        DetachedPetStore.removeRecord(for: normalizedID)
    }

    /// Close all detached Pet companions.
    func closeAll() {
        for (_, controller) in activeControllers {
            controller.close()
        }
        activeControllers.removeAll()
    }

    /// Restore all previously detached Pet companions from persistent storage.
    func restoreDetachedPets() {
        let records = DetachedPetStore.loadRecords()
        for record in records {
            let controller = DetachedPetController(
                petID: record.petID,
                appName: record.appName,
                bundleID: record.bundleID,
                initialPosition: record.position == .zero
                    ? DetachedPetController.defaultScreenPosition(slot: activeControllers.count)
                    : record.position,
                pinnedBubbles: record.pinnedBubbles
            )
            controller.viewModel.mascotState = record.mascotState
            controller.viewModel.microBarState = record.microBarState
            activeControllers[record.petID] = controller
            controller.show()
        }
    }
}
