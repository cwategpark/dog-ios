import XCTest

/// Opt-in real canonical API acceptance. A short-lived token for an isolated test user
/// must be supplied via the explicit simulator-only fixture path before launch.
/// No token, email, or private photo is committed to the project or test report.
final class PetModelCanonicalTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment["DOGIOS_RUN_CANONICAL_MODEL_UI"] == "1" else {
            throw XCTSkip("Requires a prepared canonical API test-user fixture")
        }
    }

    func testWebsiteSavedBreedModelRendersAndRespondsToGestures() throws {
        guard ProcessInfo.processInfo.environment["DOGIOS_UI_TEST_MODEL_KIND"] != "personal" else {
            throw XCTSkip("Requires the breed-reference fixture")
        }
        try exerciseSavedModel(title: "品种参考模型", prefix: "breed-model")
    }

    func testWebsiteSavedPersonalModelRendersAndRespondsToGestures() throws {
        guard ProcessInfo.processInfo.environment["DOGIOS_UI_TEST_MODEL_KIND"] == "personal" else {
            throw XCTSkip("Requires the generated personal-model fixture")
        }
        try exerciseSavedModel(title: "专属宠物模型", prefix: "personal-model")
    }

    private func exerciseSavedModel(title: String, prefix: String) throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-token-fixture"]
        if let path = ProcessInfo.processInfo.environment["DOGIOS_UI_TEST_TOKEN_FIXTURE_PATH"] {
            app.launchEnvironment["DOGIOS_UI_TEST_TOKEN_FIXTURE_PATH"] = path
        }
        app.launch()
        if let petID = ProcessInfo.processInfo.environment["DOGIOS_UI_TEST_PET_ID"] {
            let chip = app.buttons["pet-\(petID)"].firstMatch
            guard chip.waitForExistence(timeout: 30) else {
                capture("canonical-pet-selection-failure")
                XCTFail("Expected saved pet is missing")
                return
            }
            let selector = app.scrollViews["petSelector"].firstMatch
            for _ in 0..<5 where !chip.isHittable { selector.swipeLeft() }
            XCTAssertTrue(chip.isHittable)
            chip.tap()
        }
        let reference = app.staticTexts[title].firstMatch
        let profileGateError = app.staticTexts["公开资料暂时无法读取"].firstMatch
        let modelError = app.staticTexts["形象暂时没有打开"].firstMatch
        let login = app.staticTexts["验证邮箱"].firstMatch
        let startup = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                reference.exists || profileGateError.exists || modelError.exists || login.exists
            }, object: nil)
        let startupResult = XCTWaiter.wait(for: [startup], timeout: 30)
        guard startupResult == .completed, reference.exists else {
            capture("canonical-startup-failure")
            XCTFail("Canonical startup did not reach the saved model; inspect attached screen")
            return
        }
        guard app.staticTexts["modelReady"].waitForExistence(timeout: 45) else {
            capture("canonical-model-render-failure")
            XCTFail("Saved model did not finish rendering")
            return
        }
        try expectFullBody(app.staticTexts["modelReady"])
        capture("\(prefix)-synced")

        let viewer = app.webViews.firstMatch
        XCTAssertTrue(viewer.exists)
        let start = viewer.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.48))
        let end = viewer.coordinate(withNormalizedOffset: CGVector(dx: 0.28, dy: 0.48))
        start.press(forDuration: 0.1, thenDragTo: end)
        XCTAssertTrue(app.staticTexts["modelReady"].exists)
        capture("\(prefix)-rotated")
        viewer.pinch(withScale: 1.25, velocity: 1)
        XCTAssertTrue(app.staticTexts["modelReady"].exists)
        capture("\(prefix)-zoomed")
        app.buttons["modelReady-reset"].tap()
        try expectFullBody(app.staticTexts["modelReady"])

        if let assetID = ProcessInfo.processInfo.environment["DOGIOS_UI_TEST_ASSET_ID"] {
            let archived = app.buttons["asset-model-\(assetID)"].firstMatch
            for _ in 0..<5 where !archived.isHittable {
                let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.78))
                let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.25))
                start.press(forDuration: 0.1, thenDragTo: end)
            }
            XCTAssertTrue(archived.isHittable)
            archived.tap()
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 15))
            XCTAssertTrue(app.staticTexts["archiveModelReady"].waitForExistence(timeout: 45))
            try expectFullBody(app.staticTexts["archiveModelReady"])
            capture("\(prefix)-from-archive")
        }
    }

    private func expectFullBody(_ element: XCUIElement) throws {
        let fullBody = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND value == %@", "完整取景"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [fullBody], timeout: 45), .completed,
                       "The initial/reset camera must frame the complete model with a margin")
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
