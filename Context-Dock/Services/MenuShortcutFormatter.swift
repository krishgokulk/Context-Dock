//
//  MenuShortcutFormatter.swift
//  Context-Dock
//
//  Shared formatting/execution mapping for AX menu shortcuts.
//

import CoreGraphics
import Foundation

enum MenuShortcutFormatter {
    static func display(char: String?, modifiers: Int) -> String? {
        guard let raw = char, !raw.isEmpty,
              let scalar = raw.unicodeScalars.first else { return nil }

        var output = ""
        if modifiers & 4 != 0 { output += "⌃" }
        if modifiers & 2 != 0 { output += "⌥" }
        if modifiers & 1 != 0 { output += "⇧" }
        if modifiers & 16 != 0 { output += "🌐" }
        if modifiers & 8 == 0 { output += "⌘" }
        output += keyName(for: scalar.value, fallback: raw)
        return output
    }

    static func keyName(for scalar: UInt32, fallback: String) -> String {
        switch scalar {
        case 8: return "⌫"
        case 127: return "⌦"
        case 13: return "↩"
        case 3: return "⌅"
        case 27: return "⎋"
        case 9: return "⇥"
        case 32: return "Space"
        case 63232: return "↑"
        case 63233: return "↓"
        case 63234: return "←"
        case 63235: return "→"
        case 63236...63270:
            return "F\(scalar - 63235)"
        case 63272: return "⌦"
        case 63273: return "Home"
        case 63275: return "End"
        case 63276: return "Page Up"
        case 63277: return "Page Down"
        default:
            return fallback.uppercased()
        }
    }

    static func virtualKeyCode(for scalar: UInt32) -> CGKeyCode {
        let lower = scalar >= 65 && scalar <= 90 ? scalar + 32 : scalar
        if let printable = printableKeyCodes[lower] {
            return printable
        }
        if let special = specialKeyCodes[scalar] {
            return special
        }
        return 0xFFFF
    }

    private static let printableKeyCodes: [UInt32: CGKeyCode] = [
        UInt32(("a" as UnicodeScalar).value): 0,  UInt32(("s" as UnicodeScalar).value): 1,
        UInt32(("d" as UnicodeScalar).value): 2,  UInt32(("f" as UnicodeScalar).value): 3,
        UInt32(("h" as UnicodeScalar).value): 4,  UInt32(("g" as UnicodeScalar).value): 5,
        UInt32(("z" as UnicodeScalar).value): 6,  UInt32(("x" as UnicodeScalar).value): 7,
        UInt32(("c" as UnicodeScalar).value): 8,  UInt32(("v" as UnicodeScalar).value): 9,
        UInt32(("b" as UnicodeScalar).value): 11, UInt32(("q" as UnicodeScalar).value): 12,
        UInt32(("w" as UnicodeScalar).value): 13, UInt32(("e" as UnicodeScalar).value): 14,
        UInt32(("r" as UnicodeScalar).value): 15, UInt32(("y" as UnicodeScalar).value): 16,
        UInt32(("t" as UnicodeScalar).value): 17, UInt32(("1" as UnicodeScalar).value): 18,
        UInt32(("2" as UnicodeScalar).value): 19, UInt32(("3" as UnicodeScalar).value): 20,
        UInt32(("4" as UnicodeScalar).value): 21, UInt32(("6" as UnicodeScalar).value): 22,
        UInt32(("5" as UnicodeScalar).value): 23, UInt32(("=" as UnicodeScalar).value): 24,
        UInt32(("9" as UnicodeScalar).value): 25, UInt32(("7" as UnicodeScalar).value): 26,
        UInt32(("-" as UnicodeScalar).value): 27, UInt32(("8" as UnicodeScalar).value): 28,
        UInt32(("0" as UnicodeScalar).value): 29, UInt32(("]" as UnicodeScalar).value): 30,
        UInt32(("o" as UnicodeScalar).value): 31, UInt32(("u" as UnicodeScalar).value): 32,
        UInt32(("[" as UnicodeScalar).value): 33, UInt32(("i" as UnicodeScalar).value): 34,
        UInt32(("p" as UnicodeScalar).value): 35, UInt32(("l" as UnicodeScalar).value): 37,
        UInt32(("j" as UnicodeScalar).value): 38, UInt32(("'" as UnicodeScalar).value): 39,
        UInt32(("k" as UnicodeScalar).value): 40, UInt32((";" as UnicodeScalar).value): 41,
        UInt32(("\\" as UnicodeScalar).value): 42, UInt32(("," as UnicodeScalar).value): 43,
        UInt32(("/" as UnicodeScalar).value): 44, UInt32(("n" as UnicodeScalar).value): 45,
        UInt32(("m" as UnicodeScalar).value): 46, UInt32(("." as UnicodeScalar).value): 47,
        UInt32(("`" as UnicodeScalar).value): 50
    ]

    private static let specialKeyCodes: [UInt32: CGKeyCode] = [
        8: 51,
        127: 117,
        13: 36,
        3: 76,
        27: 53,
        9: 48,
        32: 49,
        63232: 126,
        63233: 125,
        63234: 123,
        63235: 124,
        63236: 122,
        63237: 120,
        63238: 99,
        63239: 118,
        63240: 96,
        63241: 97,
        63242: 98,
        63243: 100,
        63244: 101,
        63245: 109,
        63246: 103,
        63247: 111,
        63248: 105,
        63249: 107,
        63272: 117,
        63273: 115,
        63275: 119,
        63276: 116,
        63277: 121
    ]
}
