import XCTest

/// Isolated synthetic acceptance only. Requires qa/fixture_server.py on Mac localhost.
/// Uses the existing DEBUG simulator fixture -> InMemoryTokenStore path, never Keychain.
final class WebsiteAccountSyncTests: XCTestCase {
    private let fixtureOrigin = "http://127.0.0.1:18786"
    private var launchedApp: XCUIApplication?

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        launchedApp?.terminate()
        launchedApp = nil
    }

    func testNormalLogisticsShowsWebsiteOrderAndBothShipmentsWithoutShopping() throws {
        let app = try launchFixture("normal")
        try openLogistics(app)
        let order = app.staticTexts["订单 #FIXTURE-1001"]
        XCTAssertTrue(order.waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["部分商品已发货"].exists)
        XCTAssertTrue(app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "隔离测试宠物玩具")).firstMatch.exists)
        for label in ["包裹 1 · 运输中", "运单号：FIXTURE-TRACK-001", "包裹 2 · 已送达", "运单号：FIXTURE-TRACK-002"] {
            let text = app.staticTexts[label].firstMatch
            reveal(text, in: app)
            XCTAssertTrue(text.exists, "Expected synthetic shipment detail: \(label)")
        }
        XCTAssertFalse(element("logisticsEmpty", in: app).exists)
        XCTAssertFalse(element("logisticsUnavailable", in: app).exists)
        assertNoShopping(in: app)
        capture("synthetic-website-logistics-normal")
    }

    func testEmptyLogisticsIsDistinctFromUnavailable() throws {
        let app = try launchFixture("empty")
        try openLogistics(app)
        XCTAssertTrue(app.staticTexts["暂无商品物流"].waitForExistence(timeout: 15))
        XCTAssertTrue(element("logisticsEmpty", in: app).exists)
        XCTAssertFalse(element("logisticsUnavailable", in: app).exists)
        XCTAssertFalse(app.staticTexts["物流暂时无法同步"].exists)
        XCTAssertFalse(element("logisticsOrder", in: app).exists)
        assertNoShopping(in: app)
        capture("synthetic-website-logistics-empty")
    }

    func testUnconfiguredLogisticsShowsUnavailableAndNeverEmptyHistory() throws {
        let app = try launchFixture("unavailable")
        try openLogistics(app)
        XCTAssertTrue(app.staticTexts["物流暂时无法同步"].waitForExistence(timeout: 15))
        XCTAssertTrue(element("logisticsUnavailable", in: app).exists)
        XCTAssertFalse(element("logisticsEmpty", in: app).exists)
        XCTAssertFalse(app.staticTexts["暂无商品物流"].exists)
        XCTAssertFalse(element("logisticsOrder", in: app).exists)
        XCTAssertTrue(app.buttons["重试"].exists)
        assertNoShopping(in: app)
        capture("synthetic-website-logistics-unavailable")
    }

    func testPetNamesUploadedPhotoAndTextGeneratedModelStayInAccount() throws {
        guard ProcessInfo.processInfo.environment["DOGIOS_RUN_WEBSITE_SYNC_ASSETS_UI"] == "1" else {
            throw XCTSkip("Optional asset preview acceptance; enable DOGIOS_RUN_WEBSITE_SYNC_ASSETS_UI=1")
        }
        let app = try launchFixture("normal")
        let firstPet = app.buttons["pet-" + String(repeating: "a", count: 32)]
        let secondPet = app.buttons["pet-" + String(repeating: "b", count: 32)]
        XCTAssertTrue(firstPet.waitForExistence(timeout: 15))
        XCTAssertTrue(firstPet.label.contains("团子"))
        XCTAssertTrue(secondPet.label.contains("麻薯"))
        XCTAssertTrue(app.staticTexts["专属宠物模型"].firstMatch.waitForExistence(timeout: 20),
                      "text-generated models must receive the personal-model title")
        let photoID = "asset-image-" + String(repeating: "1", count: 32)
        let modelID = "asset-model-" + String(repeating: "2", count: 32)
        let uploadFilter = app.segmentedControls.buttons["上传照片"].firstMatch
        reveal(uploadFilter, in: app)
        XCTAssertTrue(uploadFilter.isHittable)
        uploadFilter.tap()
        let photo = app.buttons[photoID].firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 10))
        reveal(photo, in: app)
        XCTAssertFalse(app.buttons[modelID].exists)
        XCTAssertFalse(app.buttons["asset-image-" + String(repeating: "3", count: 32)].exists,
                       "Try-on images are outside the requested account photo scope")
        XCTAssertFalse(app.buttons["asset-image-" + String(repeating: "4", count: 32)].exists,
                       "Generated photos must not be passed off as original uploads")
        photo.tap()
        XCTAssertTrue(app.images["privateAssetImage"].waitForExistence(timeout: 15),
                      "Private upload must open through the authenticated download")
        XCTAssertTrue(app.navigationBars["上传照片"].exists)
        assertNoShopping(in: app)
        capture("synthetic-private-upload-preview")
    }

    func testOptionalDarkLargeTextAndLandscapeLogisticsRemainsNavigable() throws {
        guard ProcessInfo.processInfo.environment["DOGIOS_RUN_WEBSITE_SYNC_LAYOUT_UI"] == "1" else {
            throw XCTSkip("Optional layout acceptance; enable DOGIOS_RUN_WEBSITE_SYNC_LAYOUT_UI=1")
        }
        let app = try launchFixture("normal", extraArguments: [
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
            "-AppleInterfaceStyle", "Dark"
        ])
        try openLogistics(app)
        XCTAssertTrue(app.staticTexts["订单 #FIXTURE-1001"].waitForExistence(timeout: 15))
        capture("synthetic-logistics-dark-accessibility-xxxl")
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        XCTAssertTrue(app.navigationBars["商品物流"].exists)
        capture("synthetic-logistics-requested-landscape")
        let back = app.navigationBars["商品物流"].buttons.element(boundBy: 0)
        XCTAssertTrue(back.isHittable)
        back.tap()
        XCTAssertTrue(app.navigationBars["我的"].waitForExistence(timeout: 10))
        assertNoShopping(in: app)
    }

    private func launchFixture(_ name: String, extraArguments: [String] = []) throws -> XCUIApplication {
        let fixturePath = try resetFixture(name)
        XCTAssertEqual(URL(fileURLWithPath: fixturePath).lastPathComponent, ".pet-model-ui-token.private.json")
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-token-fixture"] + extraArguments
        app.launchEnvironment["DOGIOS_API_BASE_URL"] = fixtureOrigin
        app.launchEnvironment["DOGIOS_UI_TEST_TOKEN_FIXTURE_PATH"] = fixturePath
        launchedApp = app
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["我的"].waitForExistence(timeout: 20),
                      "Synthetic authenticated account did not reach the app tabs")
        assertNoShopping(in: app)
        return app
    }

    private func openLogistics(_ app: XCUIApplication) throws {
        app.tabBars.buttons["我的"].tap()
        let entry = element("websiteLogistics", in: app)
        XCTAssertTrue(entry.waitForExistence(timeout: 10))
        reveal(entry, in: app)
        XCTAssertTrue(entry.isHittable)
        entry.tap()
        XCTAssertTrue(app.navigationBars["商品物流"].waitForExistence(timeout: 10))
    }

    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func reveal(_ target: XCUIElement, in app: XCUIApplication) {
        // Swipe at the edge, outside the 3D viewer's orbit gesture region.
        for _ in 0..<8 {
            if target.exists && target.isHittable { return }
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.78))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.25))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
    }

    private func assertNoShopping(in app: XCUIApplication) {
        for title in ["购物", "购物车", "商城", "立即购买", "加入购物车", "Buy now", "Cart", "Shop"] {
            XCTAssertFalse(app.tabBars.buttons[title].exists, "Shopping tab must not exist: \(title)")
            XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label == %@", title)).firstMatch.exists,
                           "Shopping action must not exist: \(title)")
        }
    }

    private func resetFixture(_ name: String) throws -> String {
        let url = try XCTUnwrap(URL(string: fixtureOrigin + "/fixture/reset?case=" + name))
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        let done = expectation(description: "Reset isolated synthetic website fixture")
        let result = FixtureRequestResult()
        URLSession.shared.dataTask(with: request) { data, response, error in
            result.complete(data: data, status: (response as? HTTPURLResponse)?.statusCode, error: error)
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 10)
        if let error = result.error { throw error }
        XCTAssertEqual(result.status, 200, "Start qa/fixture_server.py on the Mac before running this class")
        let data = try XCTUnwrap(result.data)
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertTrue((value["notice"] as? String)?.contains("TEST STUB") == true)
        return try XCTUnwrap(value["fixture_path"] as? String)
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

private final class FixtureRequestResult: @unchecked Sendable {
    private let lock = NSLock()
    private var storedData: Data?
    private var storedStatus: Int?
    private var storedError: Error?
    var data: Data? { lock.lock(); defer { lock.unlock() }; return storedData }
    var status: Int? { lock.lock(); defer { lock.unlock() }; return storedStatus }
    var error: Error? { lock.lock(); defer { lock.unlock() }; return storedError }
    func complete(data: Data?, status: Int?, error: Error?) {
        lock.lock(); defer { lock.unlock() }
        storedData = data; storedStatus = status; storedError = error
    }
}
