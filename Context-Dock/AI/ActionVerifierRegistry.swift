import Foundation

/// Inventory of capability outcomes DoraX can independently read back.
/// Execution and verification remain separate: this registry declares coverage, while the
/// executor performs the read-only check after the action returns.
enum ActionVerifierRegistry {
    struct Descriptor: Equatable {
        let capabilityID: String
        let requiredInputKeys: Set<String>
        let evidenceSource: String
    }

    private static let descriptors: [String: Descriptor] = {
        let values = [
            Descriptor(capabilityID: "reminders.create", requiredInputKeys: ["title"], evidenceSource: "Reminders read-back"),
            Descriptor(capabilityID: "reminders.complete", requiredInputKeys: ["title"], evidenceSource: "Reminders read-back"),
            Descriptor(capabilityID: "reminders.delete", requiredInputKeys: ["title"], evidenceSource: "Reminders read-back"),
            Descriptor(capabilityID: "calendar.create", requiredInputKeys: ["title"], evidenceSource: "Calendar read-back"),
            Descriptor(capabilityID: "notes.create", requiredInputKeys: ["title"], evidenceSource: "Notes search read-back"),
            Descriptor(capabilityID: "finder.newFolder", requiredInputKeys: ["destination", "name"], evidenceSource: "filesystem metadata"),
            Descriptor(capabilityID: "finder.trash", requiredInputKeys: ["path"], evidenceSource: "filesystem metadata"),
        ]
        return Dictionary(uniqueKeysWithValues: values.map { ($0.capabilityID, $0) })
    }()

    static func descriptor(for capabilityID: String?) -> Descriptor? {
        capabilityID.flatMap { descriptors[$0] }
    }

    static var registeredCapabilityIDs: Set<String> { Set(descriptors.keys) }
}
