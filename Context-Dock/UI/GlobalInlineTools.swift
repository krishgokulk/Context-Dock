// GlobalInlineTools.swift
// Context-Dock
//
// Raycast 2.0 root-search inline intelligence & grid boards inside the single Result Sheet:
// 1. `GlobalInlineCalculator`: <0.5ms inline math, percentages, unit conversions, date math
//    ("days until 25 dec", "3 weeks from today"), and world timezones ("time in tokyo").
// 2. `EmojiSymbolsBoardCard` (`provider:emoji`): Raycast-style 8-column Emoji & Symbol grid
//    driven by the main top input bar (`<` Back + Category dropdown on the right).
// 3. `GlobalDictionaryLookup`: native macOS CoreServices dictionary lookup for `Define "<word>"`.

import AppKit
import CoreServices
import Foundation
import SwiftUI

// MARK: - 1. Inline Calculator, Units, Date Math & World Time

struct InlineCalculationResult: Equatable {
    let expressionDisplay: String
    let answerDisplay: String
    let copyValue: String
    let categoryLabel: String   // e.g. "Calculator", "Unit Conversion", "Date Math", "World Clock"
    let detailSubtitle: String
}

enum GlobalInlineCalculator {
    static let resultKind = "inlineCalculator"
    static let sectionTitle = "Answer"

    static func evaluate(_ rawQuery: String, now: Date = Date(), calendar: Calendar = .current) -> InlineCalculationResult? {
        let trimmed = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2, trimmed.count <= 120 else { return nil }
        // Never hijack file paths or URLs
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~/") || trimmed.contains("://") {
            return nil
        }

        if let dateRes = evaluateDateMath(trimmed, now: now, calendar: calendar) {
            return dateRes
        }
        if let tzRes = evaluateWorldTime(trimmed, now: now) {
            return tzRes
        }
        if let pctRes = evaluatePercentage(trimmed) {
            return pctRes
        }
        if let unitRes = evaluateUnitConversion(trimmed) {
            return unitRes
        }
        if let mathRes = evaluateMathExpression(trimmed) {
            return mathRes
        }
        return nil
    }

    static func makeRow(for query: String, now: Date = Date()) -> AppChatRow? {
        guard let result = evaluate(query, now: now) else { return nil }
        var pill = DockPill(
            id: "global-inline-calc-\(result.copyValue)",
            name: "\(result.expressionDisplay)  →  \(result.answerDisplay)",
            icon: "equal.square.fill",
            accentColorName: "orange",
            badge: result.categoryLabel,
            execute: {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(result.copyValue, forType: .string)
                DockActionFeedback.showResult("Copied \(result.copyValue)", icon: "doc.on.clipboard", success: true)
            }
        )
        pill.menuContext = "\(result.detailSubtitle) · Return copies \(result.copyValue)"
        pill.rankingKind = resultKind
        pill.resultSection = GlobalQuery.topHitSection
        pill.keyboardShortcutLabel = "Copy"
        return .dock(pill)
    }

    // MARK: Percentage ("18% of 450", "250 + 20%", "250 - 15%")

    private static func evaluatePercentage(_ input: String) -> InlineCalculationResult? {
        let lower = input.lowercased()
        let ofPattern = #"^([+-]?\d+(?:\.\d+)?)\s*%\s*(?:of)\s*([+-]?\d+(?:\.\d+)?)$"#
        if let regex = try? NSRegularExpression(pattern: ofPattern),
            let m = regex.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)),
            let r1 = Range(m.range(at: 1), in: lower),
            let r2 = Range(m.range(at: 2), in: lower),
            let pct = Double(lower[r1]),
            let base = Double(lower[r2])
        {
            let value = (pct / 100.0) * base
            let formatted = formatNumber(value)
            return InlineCalculationResult(
                expressionDisplay: "\(formatNumber(pct))% of \(formatNumber(base))",
                answerDisplay: formatted,
                copyValue: formatted,
                categoryLabel: "Percentage",
                detailSubtitle: "Percentage calculation"
            )
        }

        let deltaPattern = #"^([+-]?\d+(?:\.\d+)?)\s*([+-])\s*(\d+(?:\.\d+)?)\s*%$"#
        if let regex = try? NSRegularExpression(pattern: deltaPattern),
            let m = regex.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)),
            let rBase = Range(m.range(at: 1), in: lower),
            let rOp = Range(m.range(at: 2), in: lower),
            let rPct = Range(m.range(at: 3), in: lower),
            let base = Double(lower[rBase]),
            let pct = Double(lower[rPct])
        {
            let op = String(lower[rOp])
            let delta = base * (pct / 100.0)
            let value = op == "+" ? (base + delta) : (base - delta)
            let formatted = formatNumber(value)
            return InlineCalculationResult(
                expressionDisplay: "\(formatNumber(base)) \(op) \(formatNumber(pct))%",
                answerDisplay: formatted,
                copyValue: formatted,
                categoryLabel: "Percentage",
                detailSubtitle: "\(op == "+" ? "+" : "−")\(formatNumber(delta))"
            )
        }
        return nil
    }

    // MARK: Date Math ("days until 25 dec", "days since 1 jan", "3 weeks from today")

    private static func evaluateDateMath(_ input: String, now: Date, calendar: Calendar) -> InlineCalculationResult? {
        let lower = input.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        // "N days/weeks/months from today/now" or "N days ago"
        let offsetPattern = #"^(\d+)\s*(day|days|week|weeks|month|months|year|years)\s+(from today|from now|later|ago|before today)$"#
        if let regex = try? NSRegularExpression(pattern: offsetPattern),
            let m = regex.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)),
            let rNum = Range(m.range(at: 1), in: lower),
            let rUnit = Range(m.range(at: 2), in: lower),
            let rDir = Range(m.range(at: 3), in: lower),
            let count = Int(lower[rNum])
        {
            let unitWord = String(lower[rUnit])
            let dirWord = String(lower[rDir])
            let sign = (dirWord == "ago" || dirWord == "before today") ? -1 : 1
            let comp: Calendar.Component = {
                if unitWord.hasPrefix("week") { return .weekOfYear }
                if unitWord.hasPrefix("month") { return .month }
                if unitWord.hasPrefix("year") { return .year }
                return .day
            }()
            if let target = calendar.date(byAdding: comp, value: sign * count, to: now) {
                let df = DateFormatter()
                df.dateStyle = .full
                df.timeStyle = .none
                let formatted = df.string(from: target)
                return InlineCalculationResult(
                    expressionDisplay: input,
                    answerDisplay: formatted,
                    copyValue: formatted,
                    categoryLabel: "Date Math",
                    detailSubtitle: "Relative date"
                )
            }
        }

        // "days until <date>" / "days to <date>" / "days since <date>"
        let untilPrefixes = ["days until ", "days to ", "days till ", "days before ", "days since "]
        guard let matchedPrefix = untilPrefixes.first(where: { lower.hasPrefix($0) }) else {
            return nil
        }
        let isSince = matchedPrefix.contains("since")
        let remainder = String(lower.dropFirst(matchedPrefix.count)).trimmingCharacters(in: .whitespaces)
        guard !remainder.isEmpty else { return nil }

        let startOfToday = calendar.startOfDay(for: now)
        let currentYear = calendar.component(.year, from: startOfToday)

        if let parsed = parseFlexibleMonthDay(remainder, defaultYear: currentYear, calendar: calendar) {
            var targetDate = calendar.startOfDay(for: parsed.date)
            if !parsed.hadExplicitYear {
                if !isSince, targetDate < startOfToday,
                    let nextYear = calendar.date(byAdding: .year, value: 1, to: targetDate)
                {
                    targetDate = nextYear
                } else if isSince, targetDate > startOfToday,
                    let prevYear = calendar.date(byAdding: .year, value: -1, to: targetDate)
                {
                    targetDate = prevYear
                }
            }
            let diff = calendar.dateComponents([.day], from: isSince ? targetDate : startOfToday, to: isSince ? startOfToday : targetDate).day ?? 0
            let df = DateFormatter()
            df.dateStyle = .medium
            let answer = "\(abs(diff)) day\(abs(diff) == 1 ? "" : "s")"
            return InlineCalculationResult(
                expressionDisplay: input,
                answerDisplay: answer,
                copyValue: answer,
                categoryLabel: "Date Math",
                detailSubtitle: df.string(from: targetDate)
            )
        }
        return nil
    }

    private static func parseFlexibleMonthDay(
        _ raw: String, defaultYear: Int, calendar: Calendar
    ) -> (date: Date, hadExplicitYear: Bool)? {
        if raw == "christmas" || raw == "xmas" {
            var comps = DateComponents(year: defaultYear, month: 12, day: 25)
            comps.calendar = calendar
            return comps.date.map { ($0, false) }
        }
        if raw == "new year" || raw == "new years" {
            var comps = DateComponents(year: defaultYear + 1, month: 1, day: 1)
            comps.calendar = calendar
            return comps.date.map { ($0, true) }
        }
        if raw == "tomorrow" {
            return calendar.date(byAdding: .day, value: 1, to: Date()).map { ($0, true) }
        }
        let formatsWithYear = ["d MMM yyyy", "d MMMM yyyy", "MMM d yyyy", "MMMM d yyyy", "yyyy-MM-dd"]
        let formatsNoYear = ["d MMM", "d MMMM", "MMM d", "MMMM d"]
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.calendar = calendar
        for fmt in formatsWithYear {
            df.dateFormat = fmt
            if let d = df.date(from: raw) { return (d, true) }
        }
        for fmt in formatsNoYear {
            df.dateFormat = fmt + " yyyy"
            if let d = df.date(from: "\(raw) \(defaultYear)") { return (d, false) }
        }
        return nil
    }

    // MARK: World Clock ("time in tokyo", "london time", "utc now")

    private static let cityTimeZones: [String: (label: String, id: String)] = [
        "utc": ("UTC", "UTC"),
        "gmt": ("GMT", "GMT"),
        "london": ("London, UK", "Europe/London"),
        "uk": ("United Kingdom", "Europe/London"),
        "paris": ("Paris, France", "Europe/Paris"),
        "berlin": ("Berlin, Germany", "Europe/Berlin"),
        "dubai": ("Dubai, UAE", "Asia/Dubai"),
        "india": ("India (IST)", "Asia/Kolkata"),
        "ist": ("India (IST)", "Asia/Kolkata"),
        "mumbai": ("Mumbai, India", "Asia/Kolkata"),
        "chennai": ("Chennai, India", "Asia/Kolkata"),
        "bangalore": ("Bengaluru, India", "Asia/Kolkata"),
        "bengaluru": ("Bengaluru, India", "Asia/Kolkata"),
        "colombo": ("Colombo, Sri Lanka", "Asia/Colombo"),
        "sri lanka": ("Sri Lanka", "Asia/Colombo"),
        "singapore": ("Singapore", "Asia/Singapore"),
        "tokyo": ("Tokyo, Japan", "Asia/Tokyo"),
        "japan": ("Japan", "Asia/Tokyo"),
        "seoul": ("Seoul, South Korea", "Asia/Seoul"),
        "sydney": ("Sydney, Australia", "Australia/Sydney"),
        "new york": ("New York, USA", "America/New_York"),
        "nyc": ("New York, USA", "America/New_York"),
        "est": ("Eastern Time", "America/New_York"),
        "chicago": ("Chicago, USA", "America/Chicago"),
        "san francisco": ("San Francisco, USA", "America/Los_Angeles"),
        "sf": ("San Francisco, USA", "America/Los_Angeles"),
        "los angeles": ("Los Angeles, USA", "America/Los_Angeles"),
        "la": ("Los Angeles, USA", "America/Los_Angeles"),
        "pst": ("Pacific Time", "America/Los_Angeles"),
        "toronto": ("Toronto, Canada", "America/Toronto"),
    ]

    private static func evaluateWorldTime(_ input: String, now: Date) -> InlineCalculationResult? {
        let lower = input.lowercased().trimmingCharacters(in: .whitespaces)
        var place: String?
        if lower.hasPrefix("time in ") {
            place = String(lower.dropFirst("time in ".count)).trimmingCharacters(in: .whitespaces)
        } else if lower.hasSuffix(" time") {
            place = String(lower.dropLast(" time".count)).trimmingCharacters(in: .whitespaces)
        } else if lower == "utc now" || lower == "gmt now" {
            place = String(lower.prefix(3))
        }
        guard let key = place, let entry = cityTimeZones[key], let tz = TimeZone(identifier: entry.id) else {
            return nil
        }
        let tf = DateFormatter()
        tf.timeZone = tz
        tf.dateFormat = "HH:mm (h:mm a)"
        let df = DateFormatter()
        df.timeZone = tz
        df.dateFormat = "EEE, d MMM"
        let timeText = tf.string(from: now)
        return InlineCalculationResult(
            expressionDisplay: entry.label,
            answerDisplay: timeText,
            copyValue: timeText,
            categoryLabel: "World Clock",
            detailSubtitle: "\(df.string(from: now)) · \(tz.abbreviation(for: now) ?? entry.id)"
        )
    }

    // MARK: Unit Conversions ("50 km in miles", "100 f to c", "72 kg in lbs", "500 mb in gb")

    private static func evaluateUnitConversion(_ input: String) -> InlineCalculationResult? {
        let lower = input.lowercased().trimmingCharacters(in: .whitespaces)
        let pattern = #"^([+-]?\d+(?:\.\d+)?)\s*([a-z°]+)\s+(?:in|to|as)\s+([a-z°]+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)),
            let rVal = Range(match.range(at: 1), in: lower),
            let rFrom = Range(match.range(at: 2), in: lower),
            let rTo = Range(match.range(at: 3), in: lower),
            let value = Double(lower[rVal])
        else { return nil }

        let fromKey = String(lower[rFrom]).replacingOccurrences(of: "°", with: "")
        let toKey = String(lower[rTo]).replacingOccurrences(of: "°", with: "")

        if let temp = convertTemperature(value: value, from: fromKey, to: toKey) {
            return temp
        }
        guard let u1 = resolveDimensionUnit(fromKey),
            let u2 = resolveDimensionUnit(toKey),
            type(of: u1.unit) == type(of: u2.unit)
        else { return nil }

        let m1 = Measurement(value: value, unit: u1.unit)
        let converted = m1.converted(to: u2.unit)
        let out = "\(formatNumber(converted.value)) \(u2.symbol)"
        return InlineCalculationResult(
            expressionDisplay: "\(formatNumber(value)) \(u1.symbol)",
            answerDisplay: out,
            copyValue: out,
            categoryLabel: "Unit Conversion",
            detailSubtitle: "\(u1.name) → \(u2.name)"
        )
    }

    private static func convertTemperature(value: Double, from: String, to: String) -> InlineCalculationResult? {
        func parseTemp(_ k: String) -> (UnitTemperature, String)? {
            switch k {
            case "c", "celsius", "centigrade": return (.celsius, "°C")
            case "f", "fahrenheit": return (.fahrenheit, "°F")
            case "k", "kelvin": return (.kelvin, "K")
            default: return nil
            }
        }
        guard let f = parseTemp(from), let t = parseTemp(to), f.0 != t.0 else { return nil }
        let res = Measurement(value: value, unit: f.0).converted(to: t.0).value
        let out = "\(formatNumber(res))\(t.1)"
        return InlineCalculationResult(
            expressionDisplay: "\(formatNumber(value))\(f.1)",
            answerDisplay: out,
            copyValue: out,
            categoryLabel: "Temperature",
            detailSubtitle: "Temperature conversion"
        )
    }

    private static func resolveDimensionUnit(_ key: String) -> (unit: Dimension, symbol: String, name: String)? {
        switch key {
        case "km", "kilometer", "kilometers", "kilometre", "kilometres":
            return (UnitLength.kilometers, "km", "Kilometers")
        case "m", "meter", "meters", "metre", "metres":
            return (UnitLength.meters, "m", "Meters")
        case "cm", "centimeter", "centimeters":
            return (UnitLength.centimeters, "cm", "Centimeters")
        case "mm", "millimeter", "millimeters":
            return (UnitLength.millimeters, "mm", "Millimeters")
        case "mi", "mile", "miles":
            return (UnitLength.miles, "mi", "Miles")
        case "ft", "foot", "feet":
            return (UnitLength.feet, "ft", "Feet")
        case "in", "inch", "inches":
            return (UnitLength.inches, "in", "Inches")
        case "kg", "kilogram", "kilograms", "kilo", "kilos":
            return (UnitMass.kilograms, "kg", "Kilograms")
        case "g", "gram", "grams":
            return (UnitMass.grams, "g", "Grams")
        case "lb", "lbs", "pound", "pounds":
            return (UnitMass.pounds, "lb", "Pounds")
        case "oz", "ounce", "ounces":
            return (UnitMass.ounces, "oz", "Ounces")
        case "l", "liter", "liters", "litre", "litres":
            return (UnitVolume.liters, "L", "Liters")
        case "ml", "milliliter", "milliliters":
            return (UnitVolume.milliliters, "mL", "Milliliters")
        case "gal", "gallon", "gallons":
            return (UnitVolume.gallons, "gal", "Gallons")
        case "kb":
            return (UnitInformationStorage.kilobytes, "KB", "Kilobytes")
        case "mb":
            return (UnitInformationStorage.megabytes, "MB", "Megabytes")
        case "gb":
            return (UnitInformationStorage.gigabytes, "GB", "Gigabytes")
        case "tb":
            return (UnitInformationStorage.terabytes, "TB", "Terabytes")
        default:
            return nil
        }
    }

    // MARK: Safe Recursive-Descent Math Evaluator (+, -, *, /, %, ^, parentheses, sqrt, sin, cos)

    private static func evaluateMathExpression(_ input: String) -> InlineCalculationResult? {
        let normalized = input
            .replacingOccurrences(of: "×", with: "*")
            .replacingOccurrences(of: "÷", with: "/")
            .replacingOccurrences(of: "−", with: "-")
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespaces)

        // Require at least one operator or function so plain numbers like "2026" don't show a math card
        let hasOperatorOrFunc = normalized.contains(where: { "+-*/^()".contains($0) })
            || normalized.lowercased().hasPrefix("sqrt(")
        guard hasOperatorOrFunc else { return nil }

        // Only allow safe math characters and known function names
        var parser = MathParser(normalized)
        guard let result = parser.parseExpression(),
            parser.isAtEnd,
            result.isFinite
        else { return nil }

        // Avoid echoing a bare signed number like "-5"
        if Double(normalized) != nil { return nil }

        let formatted = formatNumber(result)
        return InlineCalculationResult(
            expressionDisplay: input,
            answerDisplay: formatted,
            copyValue: formatted,
            categoryLabel: "Calculator",
            detailSubtitle: "Math expression"
        )
    }

    static func formatNumber(_ value: Double) -> String {
        if abs(value) < 1e-12 { return "0" }
        let rounded = value.rounded()
        if abs(value - rounded) < 1e-9, abs(rounded) < 1e15 {
            let nf = NumberFormatter()
            nf.numberStyle = .decimal
            nf.maximumFractionDigits = 0
            return nf.string(from: NSNumber(value: rounded)) ?? String(Int64(rounded))
        }
        let nf = NumberFormatter()
        nf.numberStyle = .decimal
        nf.maximumFractionDigits = 6
        nf.minimumFractionDigits = 0
        return nf.string(from: NSNumber(value: value)) ?? String(format: "%.4f", value)
    }
}

private struct MathParser {
    private let chars: [Character]
    private var index: Int = 0

    init(_ text: String) {
        self.chars = Array(text.lowercased())
    }

    var isAtEnd: Bool {
        var idx = index
        while idx < chars.count, chars[idx].isWhitespace { idx += 1 }
        return idx == chars.count
    }

    private mutating func skipSpaces() {
        while index < chars.count, chars[index].isWhitespace { index += 1 }
    }

    mutating func parseExpression() -> Double? {
        guard var lhs = parseTerm() else { return nil }
        while true {
            skipSpaces()
            guard index < chars.count else { break }
            let op = chars[index]
            guard op == "+" || op == "-" else { break }
            index += 1
            guard let rhs = parseTerm() else { return nil }
            lhs = op == "+" ? (lhs + rhs) : (lhs - rhs)
        }
        return lhs
    }

    private mutating func parseTerm() -> Double? {
        guard var lhs = parsePower() else { return nil }
        while true {
            skipSpaces()
            guard index < chars.count else { break }
            let op = chars[index]
            guard op == "*" || op == "/" || op == "%" else { break }
            index += 1
            guard let rhs = parsePower() else { return nil }
            if op == "*" {
                lhs *= rhs
            } else if op == "/" {
                guard rhs != 0 else { return nil }
                lhs /= rhs
            } else {
                guard rhs != 0 else { return nil }
                lhs = lhs.truncatingRemainder(dividingBy: rhs)
            }
        }
        return lhs
    }

    private mutating func parsePower() -> Double? {
        guard let base = parseUnary() else { return nil }
        skipSpaces()
        if index < chars.count, chars[index] == "^" {
            index += 1
            guard let exp = parsePower() else { return nil }
            return pow(base, exp)
        }
        return base
    }

    private mutating func parseUnary() -> Double? {
        skipSpaces()
        guard index < chars.count else { return nil }
        if chars[index] == "+" {
            index += 1
            return parseUnary()
        }
        if chars[index] == "-" {
            index += 1
            return parseUnary().map { -$0 }
        }
        return parsePrimary()
    }

    private mutating func parsePrimary() -> Double? {
        skipSpaces()
        guard index < chars.count else { return nil }

        if chars[index] == "(" {
            index += 1
            guard let val = parseExpression() else { return nil }
            skipSpaces()
            guard index < chars.count, chars[index] == ")" else { return nil }
            index += 1
            return val
        }

        // Named functions: sqrt, abs, round, sin, cos, tan, log
        if chars[index].isLetter {
            let start = index
            while index < chars.count, chars[index].isLetter { index += 1 }
            let fn = String(chars[start..<index])
            if fn == "pi" { return Double.pi }
            if fn == "e" { return M_E }
            skipSpaces()
            guard index < chars.count, chars[index] == "(" else { return nil }
            index += 1
            guard let arg = parseExpression() else { return nil }
            skipSpaces()
            guard index < chars.count, chars[index] == ")" else { return nil }
            index += 1
            switch fn {
            case "sqrt": return arg >= 0 ? sqrt(arg) : nil
            case "abs": return abs(arg)
            case "round": return arg.rounded()
            case "sin": return sin(arg)
            case "cos": return cos(arg)
            case "tan": return tan(arg)
            case "ln": return arg > 0 ? log(arg) : nil
            case "log": return arg > 0 ? log10(arg) : nil
            default: return nil
            }
        }

        let start = index
        var hasDot = false
        while index < chars.count {
            let c = chars[index]
            if c.isNumber {
                index += 1
            } else if c == "." && !hasDot {
                hasDot = true
                index += 1
            } else {
                break
            }
        }
        guard index > start else { return nil }
        return Double(String(chars[start..<index]))
    }
}

// MARK: - 2. Native macOS Dictionary Lookup (`Define "<word>"`)

enum GlobalDictionaryLookup {
    static func definition(for term: String) -> String? {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2, trimmed.count <= 40, !trimmed.contains("/") else { return nil }
        let ns = trimmed as NSString
        let range = CFRange(location: 0, length: ns.length)
        guard let raw = DCSCopyTextDefinition(nil, ns, range)?.takeRetainedValue() as String? else {
            return nil
        }
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }
}

// MARK: - 3. Raycast-Style Emoji & Symbol Grid Board (`provider:emoji`)

extension SystemCommand {
    var isEmojiBoard: Bool { provider == "emoji" }
    var isStudioBoard: Bool { provider == "studio" }
}

struct EmojiCatalogItem: Identifiable, Equatable {
    let glyph: String
    let name: String
    let category: String
    let keywords: String
    var id: String { glyph + "-" + name }
}

enum EmojiCatalog {
    static let categories = ["All Categories", "Smileys & People", "Symbols & Arrows", "Objects & Tech", "Nature & Food", "Activities & Flags"]

    static let items: [EmojiCatalogItem] = [
        // Smileys & People
        .init(glyph: "😀", name: "Grinning Face", category: "Smileys & People", keywords: "happy smile joy"),
        .init(glyph: "😂", name: "Face with Tears of Joy", category: "Smileys & People", keywords: "laugh lol funny"),
        .init(glyph: "🥹", name: "Face Holding Back Tears", category: "Smileys & People", keywords: "proud touched grateful"),
        .init(glyph: "😍", name: "Smiling Face with Heart-Eyes", category: "Smileys & People", keywords: "love crush adore"),
        .init(glyph: "🤩", name: "Star-Struck", category: "Smileys & People", keywords: "excited wow amazing"),
        .init(glyph: "😎", name: "Smiling Face with Sunglasses", category: "Smileys & People", keywords: "cool chill"),
        .init(glyph: "🤔", name: "Thinking Face", category: "Smileys & People", keywords: "hmm ponder idea"),
        .init(glyph: "🫡", name: "Saluting Face", category: "Smileys & People", keywords: "salute respect aye"),
        .init(glyph: "🥳", name: "Partying Face", category: "Smileys & People", keywords: "celebrate party congrats"),
        .init(glyph: "😴", name: "Sleeping Face", category: "Smileys & People", keywords: "sleep tired zzz"),
        .init(glyph: "🤯", name: "Exploding Head", category: "Smileys & People", keywords: "mind blown shocked"),
        .init(glyph: "👍", name: "Thumbs Up", category: "Smileys & People", keywords: "yes approve like ok"),
        .init(glyph: "🙌", name: "Raising Hands", category: "Smileys & People", keywords: "hooray celebrate praise"),
        .init(glyph: "👏", name: "Clapping Hands", category: "Smileys & People", keywords: "applause bravo"),
        .init(glyph: "🙏", name: "Folded Hands", category: "Smileys & People", keywords: "thank you please pray"),
        .init(glyph: "💪", name: "Flexed Biceps", category: "Smileys & People", keywords: "strong muscle power"),
        // Symbols & Arrows
        .init(glyph: "✨", name: "Sparkles", category: "Symbols & Arrows", keywords: "ai magic stars shine"),
        .init(glyph: "🔥", name: "Fire", category: "Symbols & Arrows", keywords: "hot lit flame trend"),
        .init(glyph: "⚡️", name: "High Voltage", category: "Symbols & Arrows", keywords: "zap fast lightning bolt"),
        .init(glyph: "✅", name: "Check Mark Button", category: "Symbols & Arrows", keywords: "done yes complete pass"),
        .init(glyph: "❌", name: "Cross Mark", category: "Symbols & Arrows", keywords: "no fail error cancel"),
        .init(glyph: "⚠️", name: "Warning", category: "Symbols & Arrows", keywords: "alert caution attention"),
        .init(glyph: "❤️", name: "Red Heart", category: "Symbols & Arrows", keywords: "love like heart"),
        .init(glyph: "💯", name: "Hundred Points", category: "Symbols & Arrows", keywords: "100 perfect score"),
        .init(glyph: "→", name: "Rightwards Arrow", category: "Symbols & Arrows", keywords: "arrow right next"),
        .init(glyph: "←", name: "Leftwards Arrow", category: "Symbols & Arrows", keywords: "arrow left back"),
        .init(glyph: "↑", name: "Upwards Arrow", category: "Symbols & Arrows", keywords: "arrow up"),
        .init(glyph: "↓", name: "Downwards Arrow", category: "Symbols & Arrows", keywords: "arrow down"),
        .init(glyph: "⌘", name: "Command Key", category: "Symbols & Arrows", keywords: "cmd apple mac shortcut"),
        .init(glyph: "⌥", name: "Option Key", category: "Symbols & Arrows", keywords: "alt option mac shortcut"),
        .init(glyph: "⇧", name: "Shift Key", category: "Symbols & Arrows", keywords: "shift mac shortcut"),
        .init(glyph: "↩", name: "Return Symbol", category: "Symbols & Arrows", keywords: "enter return key"),
        // Objects & Tech
        .init(glyph: "💻", name: "Laptop", category: "Objects & Tech", keywords: "macbook computer code dev"),
        .init(glyph: "📱", name: "Mobile Phone", category: "Objects & Tech", keywords: "iphone ios app"),
        .init(glyph: "🧠", name: "Brain", category: "Objects & Tech", keywords: "ai smart memory intelligence"),
        .init(glyph: "🚀", name: "Rocket", category: "Objects & Tech", keywords: "launch ship deploy fast"),
        .init(glyph: "📄", name: "Page Facing Up", category: "Objects & Tech", keywords: "file document pdf text"),
        .init(glyph: "📁", name: "File Folder", category: "Objects & Tech", keywords: "directory folder finder"),
        .init(glyph: "📌", name: "Pushpin", category: "Objects & Tech", keywords: "pin save stick"),
        .init(glyph: "🔍", name: "Magnifying Glass", category: "Objects & Tech", keywords: "search find lookup"),
        .init(glyph: "🔒", name: "Locked", category: "Objects & Tech", keywords: "security privacy safe"),
        .init(glyph: "🔑", name: "Key", category: "Objects & Tech", keywords: "auth token password"),
        .init(glyph: "🛠", name: "Hammer and Wrench", category: "Objects & Tech", keywords: "tools build fix settings"),
        .init(glyph: "📦", name: "Package", category: "Objects & Tech", keywords: "bundle pack plugin box"),
        .init(glyph: "📎", name: "Paperclip", category: "Objects & Tech", keywords: "attach file link"),
        .init(glyph: "📝", name: "Memo", category: "Objects & Tech", keywords: "note write edit draft"),
        .init(glyph: "📅", name: "Calendar", category: "Objects & Tech", keywords: "date schedule meeting"),
        .init(glyph: "🔔", name: "Bell", category: "Objects & Tech", keywords: "notification reminder alert"),
        // Nature & Food
        .init(glyph: "🌟", name: "Glowing Star", category: "Nature & Food", keywords: "star favorite top"),
        .init(glyph: "🌈", name: "Rainbow", category: "Nature & Food", keywords: "color spectrum"),
        .init(glyph: "☀️", name: "Sun", category: "Nature & Food", keywords: "light bright weather day"),
        .init(glyph: "🌙", name: "Crescent Moon", category: "Nature & Food", keywords: "dark night sleep"),
        .init(glyph: "☕️", name: "Hot Beverage", category: "Nature & Food", keywords: "coffee tea awake cafe"),
        .init(glyph: "🍕", name: "Pizza", category: "Nature & Food", keywords: "food slice lunch"),
        .init(glyph: "🍎", name: "Red Apple", category: "Nature & Food", keywords: "mac fruit healthy"),
        .init(glyph: "🌿", name: "Herb", category: "Nature & Food", keywords: "green plant leaf"),
        // Activities & Flags
        .init(glyph: "🎯", name: "Bullseye", category: "Activities & Flags", keywords: "target goal focus hit"),
        .init(glyph: "🎉", name: "Party Popper", category: "Activities & Flags", keywords: "tada celebrate ship"),
        .init(glyph: "🏆", name: "Trophy", category: "Activities & Flags", keywords: "win award best champion"),
        .init(glyph: "🎵", name: "Musical Note", category: "Activities & Flags", keywords: "music audio song"),
        .init(glyph: "🎬", name: "Clapper Board", category: "Activities & Flags", keywords: "video movie record"),
        .init(glyph: "🎮", name: "Video Game", category: "Activities & Flags", keywords: "game controller play"),
        .init(glyph: "🇬🇧", name: "Flag: United Kingdom", category: "Activities & Flags", keywords: "uk britain london"),
        .init(glyph: "🇺🇸", name: "Flag: United States", category: "Activities & Flags", keywords: "usa america"),
    ]
}

struct EmojiSymbolsBoardCard: View {
    @ObservedObject var prompt: AppChatPromptModel
    @Environment(\.sharesOneCard) private var sharesOneCard
    @State private var selectedCategory = "All Categories"
    @State private var selectedIndex = 0

    private var filtered: [EmojiCatalogItem] {
        let q = prompt.query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return EmojiCatalog.items.filter { item in
            let catOK = selectedCategory == "All Categories" || item.category == selectedCategory
            guard catOK else { return false }
            guard !q.isEmpty else { return true }
            return item.name.lowercased().contains(q)
                || item.keywords.lowercased().contains(q)
                || item.glyph.contains(q)
                || item.category.lowercased().contains(q)
        }
    }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 8)

    var body: some View {
        let items = filtered
        let clamped = items.isEmpty ? 0 : min(selectedIndex, items.count - 1)
        let activeItem = items.indices.contains(clamped) ? items[clamped] : nil

        VStack(spacing: 0) {
            if !sharesOneCard {
                HStack(spacing: 8) {
                    Text("Results  \(items.count)")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Menu {
                        ForEach(EmojiCatalog.categories, id: \.self) { cat in
                            Button {
                                selectedCategory = cat
                                selectedIndex = 0
                            } label: {
                                if selectedCategory == cat {
                                    Label("\(cat)  ✓", systemImage: "square.grid.2x2")
                                } else {
                                    Text(cat)
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "square.grid.2x2")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color.accentColor)
                            Text("\(selectedCategory) ▾")
                                .font(.system(size: 11.5, weight: .medium))
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .padding(.horizontal, 16)
                .frame(height: 32)
            }

            ScrollView(.vertical, showsIndicators: false) {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                        Button {
                            copyEmoji(item)
                        } label: {
                            Text(item.glyph)
                                .font(.system(size: 28))
                                .frame(maxWidth: .infinity)
                                .frame(height: 62)
                                .background(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(idx == clamped
                                            ? Color.accentColor.opacity(0.22)
                                            : Color.primary.opacity(0.06))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .strokeBorder(
                                            idx == clamped
                                                ? Color.accentColor.opacity(0.75)
                                                : Color.white.opacity(0.08),
                                            lineWidth: idx == clamped ? 1.5 : 1
                                        )
                                )
                        }
                        .buttonStyle(.plain)
                        .onHover { hovering in
                            if hovering { selectedIndex = idx }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Footer matching Raycast Emoji Picker
            VStack(spacing: 0) {
                Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
                HStack(spacing: 8) {
                    if let activeItem {
                        BoardFooter.pill {
                            Text(activeItem.glyph).font(.system(size: 13))
                            Text("\(activeItem.name) · \(activeItem.category)")
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                    BoardFooter.pill {
                        Button {
                            if let activeItem { copyEmoji(activeItem) }
                        } label: {
                            BoardFooter.action("Copy Emoji", keys: ["↩"])
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: BoardFooter.height - 1)
            }
            .frame(height: BoardFooter.height)
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.55))
        }
        .frame(width: 680, height: 440, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .background {
            if sharesOneCard {
                Rectangle().fill(Color.white.opacity(0.10)).frame(height: 1)
                    .frame(maxHeight: .infinity, alignment: .top)
            } else {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor).opacity(0.75))
                    .background(GlassBackground(cornerRadius: 22, isDark: nil))
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.35), radius: 20, y: 10)
            }
        }
        .onAppear {
            ScopedListKeyBridge.shared.run = {
                guard items.indices.contains(clamped) else { return false }
                copyEmoji(items[clamped])
                return true
            }
            syncEmojiHeader(count: items.count)
        }
        .onChange(of: selectedCategory) { _, _ in
            syncEmojiHeader(count: items.count)
        }
        .onChange(of: prompt.query) { _, _ in
            syncEmojiHeader(count: items.count)
        }
        .onDisappear {
            ScopedListKeyBridge.shared.run = nil
            ExtensionHeaderBarState.shared.reset(ifMatching: "emoji-symbols")
        }
    }

    private func syncEmojiHeader(count: Int) {
        ExtensionHeaderBarState.shared.update(
            id: "emoji-symbols",
            title: "Emoji & Symbols",
            icon: "face.smiling",
            count: count,
            filterOptions: EmojiCatalog.categories,
            selectedFilter: selectedCategory,
            placeholder: "Search emojis & symbols…",
            onBack: { _ = prompt.leaveScopeForGlobal() },
            onSelectFilter: { cat in
                selectedCategory = cat
                selectedIndex = 0
            })
    }

    private func copyEmoji(_ item: EmojiCatalogItem) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.glyph, forType: .string)
        DockActionFeedback.showResult("Copied \(item.glyph) \(item.name)", icon: "face.smiling", success: true)
        prompt.leaveScopeForGlobal()
    }
}
