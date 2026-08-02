//
//  WebSearchSettings.swift
//  demo-app
//

import Foundation
import Observation

@Observable
final class WebSearchSettings {
    static let shared = WebSearchSettings()

    private static let keychainAccount = "web-search-key::brave"
    private static let disclosureKey = "web-search.braveDisclosureAccepted"

    private let defaults: UserDefaults

    var hasAcceptedDisclosure: Bool {
        didSet { defaults.set(hasAcceptedDisclosure, forKey: Self.disclosureKey) }
    }

    var hasKey: Bool {
        !(KeychainStore.read(for: Self.keychainAccount) ?? "").isEmpty
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.hasAcceptedDisclosure = defaults.bool(forKey: Self.disclosureKey)
    }

    func key() -> String? {
        KeychainStore.read(for: Self.keychainAccount)
    }

    func setKey(_ key: String?) throws {
        guard let key = key?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            KeychainStore.delete(for: Self.keychainAccount)
            return
        }
        try KeychainStore.save(key, for: Self.keychainAccount)
    }
}
