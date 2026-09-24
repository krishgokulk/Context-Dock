import AppKit
import ObjectiveC

/// In the test host, every Apple Event fails at once with "not permitted" (-1743) — the same
/// answer a person gets for declining the Automation prompt — instead of being sent.
///
/// Why: the suite is offline, and on a CI runner nobody answers macOS's "Context-Dock wants to
/// control …" prompt. Each Apple Event then waited out its 120-second timeout on the main
/// thread, stalling whichever test happened to be running. The app sends Apple Events from
/// about thirty files, so the block is applied once, here, to the three AppKit entry points
/// they all go through, rather than to each caller.
///
/// Installed only when `AppDelegate.isHostingTests`; the app a person launches never has it.
enum TestHostAppleEventBlocker {
    private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true
        swap(NSAppleScript.self,
             #selector(NSAppleScript.executeAndReturnError(_:)),
             #selector(NSAppleScript.testHost_executeAndReturnError(_:)))
        swap(NSAppleScript.self,
             #selector(NSAppleScript.executeAppleEvent(_:error:)),
             #selector(NSAppleScript.testHost_executeAppleEvent(_:error:)))
        swap(NSAppleEventDescriptor.self,
             #selector(NSAppleEventDescriptor.sendEvent(options:timeout:)),
             #selector(NSAppleEventDescriptor.testHost_sendEvent(options:timeout:)))
    }

    private static func swap(_ type: AnyClass, _ original: Selector, _ replacement: Selector) {
        guard let a = class_getInstanceMethod(type, original),
              let b = class_getInstanceMethod(type, replacement)
        else { return }
        method_exchangeImplementations(a, b)
    }

    static let notPermitted: [String: Any] = [
        NSAppleScript.errorNumber: -1743,
        NSAppleScript.errorMessage: "Apple Events are blocked in the test host.",
    ]
}

extension NSAppleScript {
    @objc fileprivate func testHost_executeAndReturnError(
        _ errorInfo: AutoreleasingUnsafeMutablePointer<NSDictionary?>?
    ) -> NSAppleEventDescriptor {
        errorInfo?.pointee = TestHostAppleEventBlocker.notPermitted as NSDictionary
        return NSAppleEventDescriptor.null()
    }

    @objc fileprivate func testHost_executeAppleEvent(
        _ event: NSAppleEventDescriptor,
        error errorInfo: AutoreleasingUnsafeMutablePointer<NSDictionary?>?
    ) -> NSAppleEventDescriptor {
        errorInfo?.pointee = TestHostAppleEventBlocker.notPermitted as NSDictionary
        return NSAppleEventDescriptor.null()
    }
}

extension NSAppleEventDescriptor {
    @objc fileprivate func testHost_sendEvent(
        options: NSAppleEventDescriptor.SendOptions, timeout: TimeInterval
    ) throws -> NSAppleEventDescriptor {
        throw NSError(domain: NSOSStatusErrorDomain, code: -1743, userInfo: [
            NSLocalizedDescriptionKey: "Apple Events are blocked in the test host.",
        ])
    }
}
