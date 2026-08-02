//
//  AgeGate.swift
//  ai-chat
//
//  Declared-age gate policy (App Review Guideline 4.7.5).
//
//  The app renders unfiltered output from third-party models and can surface
//  arbitrary web content, so it is rated 17+. Users must declare their birth
//  year before first use. Only the year is asked for — a full birth date
//  would be more data than the check needs. The declaration is stored once
//  in UserDefaults; an under-age declaration keeps the app blocked rather
//  than offering a second chance to enter a different year.
//

import Foundation

nonisolated enum AgeGate {
    static let minimumAge = 17

    /// UserDefaults key for the declared birth year. 0 (the `@AppStorage`
    /// default) means no declaration has been made yet.
    static let birthYearKey = "ageGate.declaredBirthYear"

    static func isDeclared(birthYear: Int) -> Bool {
        birthYear > 0
    }

    static func passes(birthYear: Int, now: Date = .now) -> Bool {
        guard isDeclared(birthYear: birthYear) else { return false }
        let currentYear = Calendar.current.component(.year, from: now)
        return currentYear - birthYear >= minimumAge
    }

    /// Newest year first, so the wheel starts near recent years and scrolling
    /// down moves into the past.
    static func selectableYears(now: Date = .now) -> [Int] {
        let currentYear = Calendar.current.component(.year, from: now)
        return Array(((currentYear - 120)...currentYear).reversed())
    }
}
