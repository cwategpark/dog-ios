import XCTest

final class MobileFlowTests: XCTestCase {
    @MainActor
    func testRealBackendFlow() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-ui-test-reset-session"]
        app.launch()
        let email = app.textFields["emailInput"]
        XCTAssertTrue(email.waitForExistence(timeout: 10))
        email.tap(); email.typeText("ios-ui-owner@example.test")
        app.buttons["sendCode"].tap()
        let verify = app.buttons["verifyLogin"]
        XCTAssertTrue(verify.waitForExistence(timeout: 20))
        XCTAssertTrue(verify.isEnabled, "Development challenge should prefill the server dev_code; no token injection")
        verify.tap()
        XCTAssertTrue(app.tabBars.buttons["宠物"].waitForExistence(timeout: 20))
        let modelReady = app.staticTexts["modelReady"].waitForExistence(timeout: 30)
        capture("00-model-status")
        continueAfterFailure = true
        XCTAssertTrue(modelReady, "Real GLB renderer must signal ready")
        continueAfterFailure = false
        capture("01-pet-home-golden")
        app.swipeUp()
        let asset = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "asset-image-")).firstMatch
        XCTAssertTrue(asset.waitForExistence(timeout: 15))
        capture("02-private-gallery")
        for tile in app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "asset-")).allElementsBoundByIndex {
            XCTAssertGreaterThanOrEqual(tile.frame.minX, 15)
            XCTAssertLessThanOrEqual(tile.frame.maxX, app.frame.maxX - 15)
        }
        asset.tap()
        XCTAssertTrue(app.images["privateAssetImage"].waitForExistence(timeout: 20))
        capture("03-private-image")
        app.buttons["完成"].tap()
        app.tabBars.buttons["附近"].tap()
        XCTAssertTrue(app.otherElements["nearbyMap"].waitForExistence(timeout: 15))
        capture("04-nearby-map")
        app.tabBars.buttons["消息"].tap()
        let accept = app.buttons["接受"]
        if accept.waitForExistence(timeout: 8) { accept.firstMatch.tap() }
        let contact = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "contact-")).firstMatch
        XCTAssertTrue(contact.waitForExistence(timeout: 15))
        capture("05-contacts")
        contact.tap()
        let input = app.textFields["messageInput"]
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        input.tap(); input.typeText("UI integration walk invitation")
        app.buttons["sendMessage"].tap()
        XCTAssertTrue(app.staticTexts["UI integration walk invitation"].waitForExistence(timeout: 20))
        capture("06-chat")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.tabBars.buttons["我的"].tap()
        XCTAssertTrue(app.staticTexts["userIdentifier"].waitForExistence(timeout: 15))
        capture("07-account")
        app.buttons["logout"].tap()
        XCTAssertTrue(app.buttons["confirmLogout"].waitForExistence(timeout: 8))
        app.buttons["confirmLogout"].firstMatch.tap()
        XCTAssertTrue(app.textFields["emailInput"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.images["privateAssetImage"].exists)
        capture("08-logged-out")
    }

    @MainActor private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
