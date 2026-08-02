//
//  AgeGateTests.swift
//  ai-chatTests
//

import Foundation
import Testing
@testable import AIChat

struct AgeGateTests {
    private let now = Calendar.current.date(from: DateComponents(year: 2026, month: 8, day: 3))!

    @Test func undeclaredNeverPasses() {
        #expect(!AgeGate.isDeclared(birthYear: 0))
        #expect(!AgeGate.passes(birthYear: 0, now: now))
        #expect(!AgeGate.passes(birthYear: -5, now: now))
    }

    @Test func seventeenYearOldPasses() {
        #expect(AgeGate.passes(birthYear: 2009, now: now))
    }

    @Test func sixteenYearOldIsBlocked() {
        #expect(!AgeGate.passes(birthYear: 2010, now: now))
    }

    @Test func adultPasses() {
        #expect(AgeGate.passes(birthYear: 1990, now: now))
    }

    @Test func selectableYearsCoverCurrentYearBackTo120() {
        let years = AgeGate.selectableYears(now: now)
        #expect(years.first == 2026)
        #expect(years.last == 1906)
        #expect(years.count == 121)
    }
}
