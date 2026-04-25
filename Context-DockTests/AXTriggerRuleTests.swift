//
//  AXTriggerRuleTests.swift
//  Context-DockTests
//
//  Unit tests for AXTriggerRule model types and built-in example rules.
//

import XCTest
@testable import Context_Dock

final class AXConditionOperatorTests: XCTestCase {

    // MARK: - needsValue

    func testNeedsValue_containsIsTrue() {
        XCTAssertTrue(AXConditionOperator.contains.needsValue)
    }

    func testNeedsValue_notContainsIsTrue() {
        XCTAssertTrue(AXConditionOperator.notContains.needsValue)
    }

    func testNeedsValue_equalsIsTrue() {
        XCTAssertTrue(AXConditionOperator.equals.needsValue)
    }

    func testNeedsValue_startsWithIsTrue() {
        XCTAssertTrue(AXConditionOperator.startsWith.needsValue)
    }

    func testNeedsValue_endsWithIsTrue() {
        XCTAssertTrue(AXConditionOperator.endsWith.needsValue)
    }

    func testNeedsValue_matchesRegexIsTrue() {
        XCTAssertTrue(AXConditionOperator.matchesRegex.needsValue)
    }

    func testNeedsValue_isEmptyIsFalse() {
        XCTAssertFalse(AXConditionOperator.isEmpty.needsValue)
    }

    func testNeedsValue_isNotEmptyIsFalse() {
        XCTAssertFalse(AXConditionOperator.isNotEmpty.needsValue)
    }

    // MARK: - Identifiable

    func testId_matchesRawValue() {
        for op in AXConditionOperator.allCases {
            XCTAssertEqual(op.id, op.rawValue)
        }
    }

    // MARK: - CaseIterable completeness

    func testAllCasesCount() {
        // There are 8 operators; update if the enum changes
        XCTAssertEqual(AXConditionOperator.allCases.count, 8)
    }
}

// MARK: -

final class AXConditionFieldTests: XCTestCase {

    func testId_matchesRawValue() {
        for field in AXConditionField.allCases {
            XCTAssertEqual(field.id, field.rawValue)
        }
    }

    func testSfSymbol_nonEmptyForAllCases() {
        for field in AXConditionField.allCases {
            XCTAssertFalse(field.sfSymbol.isEmpty,
                           "\(field.rawValue) must have a non-empty SF Symbol name")
        }
    }

    func testAllCasesCount() {
        // There are 8 fields; update if the enum changes
        XCTAssertEqual(AXConditionField.allCases.count, 8)
    }
}

// MARK: -

final class AXTriggerConditionTests: XCTestCase {

    func testDefaultInit() {
        let condition = AXTriggerCondition()
        XCTAssertEqual(condition.field, .appName)
        XCTAssertEqual(condition.op, .contains)
        XCTAssertEqual(condition.value, "")
    }

    func testCustomInit() {
        let condition = AXTriggerCondition(field: .currentURL, op: .startsWith, value: "https")
        XCTAssertEqual(condition.field, .currentURL)
        XCTAssertEqual(condition.op, .startsWith)
        XCTAssertEqual(condition.value, "https")
    }

    func testEachInitCallGeneratesUniqueID() {
        let a = AXTriggerCondition()
        let b = AXTriggerCondition()
        XCTAssertNotEqual(a.id, b.id)
    }
}

// MARK: -

final class AXTriggerRuleTests: XCTestCase {

    func testDefaultInit() {
        let rule = AXTriggerRule()
        XCTAssertEqual(rule.name, "New Rule")
        XCTAssertTrue(rule.isEnabled)
        XCTAssertTrue(rule.conditions.isEmpty)
        XCTAssertEqual(rule.conditionLogic, .all)
        XCTAssertTrue(rule.pills.isEmpty)
        XCTAssertEqual(rule.priority, 0)
        XCTAssertNil(rule.hotkeyString)
    }

    func testCustomInit() {
        let condition = AXTriggerCondition(field: .windowTitle, op: .contains, value: "Xcode")
        let pill = AXRulePill(label: "Run", icon: "play.fill", accentColor: "green",
                              actionType: .shellCommand, actionValue: "xcodebuild")
        let rule = AXTriggerRule(name: "Xcode Rule",
                                 isEnabled: true,
                                 conditions: [condition],
                                 conditionLogic: .any,
                                 pills: [pill],
                                 priority: 5,
                                 hotkeyString: "cmd+shift:x")
        XCTAssertEqual(rule.name, "Xcode Rule")
        XCTAssertEqual(rule.conditions.count, 1)
        XCTAssertEqual(rule.conditionLogic, .any)
        XCTAssertEqual(rule.pills.count, 1)
        XCTAssertEqual(rule.priority, 5)
        XCTAssertEqual(rule.hotkeyString, "cmd+shift:x")
    }

    func testEachInitGeneratesUniqueID() {
        let a = AXTriggerRule()
        let b = AXTriggerRule()
        XCTAssertNotEqual(a.id, b.id)
    }

    // MARK: Built-in examples

    func testBuiltInExamples_nonEmpty() {
        XCTAssertFalse(AXTriggerRule.builtInExamples.isEmpty,
                       "There must be at least one built-in example rule")
    }

    func testBuiltInExamples_allHaveNames() {
        for rule in AXTriggerRule.builtInExamples {
            XCTAssertFalse(rule.name.isEmpty, "Every built-in rule must have a name")
        }
    }

    func testBuiltInExamples_allEnabled() {
        for rule in AXTriggerRule.builtInExamples {
            XCTAssertTrue(rule.isEnabled, "All built-in rules should be enabled by default")
        }
    }

    func testBuiltInExamples_allHaveAtLeastOneCondition() {
        for rule in AXTriggerRule.builtInExamples {
            XCTAssertFalse(rule.conditions.isEmpty,
                           "Rule '\(rule.name)' has no conditions")
        }
    }

    func testBuiltInExamples_allHaveAtLeastOnePill() {
        for rule in AXTriggerRule.builtInExamples {
            XCTAssertFalse(rule.pills.isEmpty,
                           "Rule '\(rule.name)' has no pills")
        }
    }

    func testBuiltInExamples_uniqueIDs() {
        let ids = AXTriggerRule.builtInExamples.map { $0.id }
        let uniqueIDs = Set(ids)
        XCTAssertEqual(ids.count, uniqueIDs.count, "All built-in rules must have unique IDs")
    }

    func testBuiltInExamples_pillsHaveNonEmptyLabels() {
        for rule in AXTriggerRule.builtInExamples {
            for pill in rule.pills {
                XCTAssertFalse(pill.label.isEmpty,
                               "Pill in rule '\(rule.name)' must have a non-empty label")
            }
        }
    }

    func testBuiltInExamples_pillsHaveNonEmptyIcons() {
        for rule in AXTriggerRule.builtInExamples {
            for pill in rule.pills {
                XCTAssertFalse(pill.icon.isEmpty,
                               "Pill in rule '\(rule.name)' must have a non-empty icon")
            }
        }
    }

    func testBuiltInExamples_pillsHaveNonEmptyAccentColors() {
        let validColors = Set(["blue", "red", "green", "orange", "purple", "teal", "gray"])
        for rule in AXTriggerRule.builtInExamples {
            for pill in rule.pills {
                XCTAssertTrue(validColors.contains(pill.accentColor),
                              "Pill '\(pill.label)' has invalid accent color: '\(pill.accentColor)'")
            }
        }
    }

    // MARK: Codable round-trip

    func testRule_codableRoundTrip() throws {
        let original = AXTriggerRule(name: "Test Rule",
                                     isEnabled: true,
                                     conditions: [
                                        AXTriggerCondition(field: .appName, op: .equals, value: "Xcode"),
                                     ],
                                     conditionLogic: .all,
                                     pills: [
                                        AXRulePill(label: "Fix", icon: "wrench.fill",
                                                   accentColor: "orange",
                                                   actionType: .openURL,
                                                   actionValue: "https://example.com"),
                                     ],
                                     priority: 3)

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AXTriggerRule.self, from: encoded)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.name, original.name)
        XCTAssertEqual(decoded.isEnabled, original.isEnabled)
        XCTAssertEqual(decoded.conditionLogic, original.conditionLogic)
        XCTAssertEqual(decoded.priority, original.priority)
        XCTAssertEqual(decoded.conditions.count, original.conditions.count)
        XCTAssertEqual(decoded.pills.count, original.pills.count)
    }
}

// MARK: -

final class AXRulePillTests: XCTestCase {

    func testDefaultInit() {
        let pill = AXRulePill()
        XCTAssertEqual(pill.label, "Action")
        XCTAssertEqual(pill.icon, "bolt.fill")
        XCTAssertEqual(pill.accentColor, "blue")
        XCTAssertEqual(pill.actionType, .shellCommand)
        XCTAssertEqual(pill.actionValue, "")
    }

    func testCustomInit() {
        let pill = AXRulePill(label: "Open",
                              icon: "safari",
                              accentColor: "teal",
                              actionType: .openURL,
                              actionValue: "https://apple.com")
        XCTAssertEqual(pill.label, "Open")
        XCTAssertEqual(pill.icon, "safari")
        XCTAssertEqual(pill.accentColor, "teal")
        XCTAssertEqual(pill.actionType, .openURL)
        XCTAssertEqual(pill.actionValue, "https://apple.com")
    }

    func testEachInitGeneratesUniqueID() {
        let a = AXRulePill()
        let b = AXRulePill()
        XCTAssertNotEqual(a.id, b.id)
    }
}
