//
//  ModelProviderKeySectionUITests.swift
//  ParleyUITests
//
//  Walks the real app to the per-conversation Model & Provider sheet and
//  exercises the API key section: save a key, see the remove button appear,
//  then remove it again (also keeps the simulator Keychain clean).
//

import XCTest

final class ModelProviderKeySectionUITests: XCTestCase {
    @MainActor
    func testAPIKeySectionInModelProviderSheet() throws {
        let app = XCUIApplication()
        app.launch()

        // Age gate appears on a clean install; the wheel default passes.
        let continueButton = app.buttons["Continue"]
        if continueButton.waitForExistence(timeout: 5) {
            continueButton.tap()
        }

        // Settings auto-presents when the default provider needs a key.
        let settingsDone = app.navigationBars["Settings"].buttons["Done"]
        if settingsDone.waitForExistence(timeout: 3) {
            settingsDone.tap()
        }

        let newChat = app.buttons["New chat"].firstMatch
        XCTAssertTrue(newChat.waitForExistence(timeout: 5))
        newChat.tap()

        let more = app.buttons["More"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 5))
        more.tap()
        let modelProvider = app.buttons["Model & provider"].firstMatch
        XCTAssertTrue(modelProvider.waitForExistence(timeout: 3))
        modelProvider.tap()

        XCTAssertTrue(app.navigationBars["Model & Provider"].waitForExistence(timeout: 5))

        // Force a cloud provider (the key section is hidden for the
        // on-device preset). The picker's accessibility label is
        // "Preset, <current value>". Skip if a cloud preset is already
        // active — the key field is then already on screen.
        var keyField = app.secureTextFields["API key"]
        if !keyField.waitForExistence(timeout: 2) {
            let preset = app.buttons.matching(
                NSPredicate(format: "label BEGINSWITH %@", "Preset")
            ).firstMatch
            XCTAssertTrue(preset.waitForExistence(timeout: 3))
            preset.tap()
            let openAI = app.buttons["OpenAI"].firstMatch
            XCTAssertTrue(openAI.waitForExistence(timeout: 3))
            openAI.tap()
            keyField = app.secureTextFields["API key"]
        }
        XCTAssertTrue(keyField.waitForExistence(timeout: 5))
        attachShot(app, name: "1-key-section-empty")

        keyField.tap()
        keyField.typeText("sk-uitest-not-a-real-key")

        let save = app.buttons["Save API key"]
        XCTAssertTrue(save.waitForExistence(timeout: 2))
        XCTAssertTrue(save.isEnabled)
        save.tap()

        let remove = app.buttons["Remove saved key"]
        XCTAssertTrue(remove.waitForExistence(timeout: 3))
        attachShot(app, name: "2-key-saved")

        remove.tap()
        XCTAssertFalse(remove.waitForExistence(timeout: 2))
        attachShot(app, name: "3-key-removed")
    }

    @MainActor
    private func attachShot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
