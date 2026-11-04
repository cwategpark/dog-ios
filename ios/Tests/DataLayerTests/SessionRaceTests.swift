import Foundation
import XCTest
@testable import DogiosDataLayer
@testable import MobileSessionState

/// HTTP replies are held until the test explicitly releases them, exercising
/// account changes across actual URLSession suspension points without sleeps.
private final class ControlledSessionProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var handler: ((ControlledSessionProtocol) -> Void)?
    private let stateLock = NSLock()
    private var stopped = false

    static func install(_ value: ((ControlledSessionProtocol) -> Void)?) {
        lock.lock(); handler = value; lock.unlock()
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let value = Self.handler; Self.lock.unlock()
        guard let value else { fail(URLError(.unsupportedURL)); return }
        value(self)
    }
    override func stopLoading() { stateLock.lock(); stopped = true; stateLock.unlock() }
    func reply(_ json: String = "", status: Int = 200) {
        stateLock.lock(); let active = !stopped; stateLock.unlock()
        guard active else { return }
        let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    func fail(_ error: Error) { client?.urlProtocol(self, didFailWithError: error) }
}

private final class RequestGate {
    let started: XCTestExpectation
    private let lock = NSLock()
    private var pending: ControlledSessionProtocol?
    init(_ label: String) { started = XCTestExpectation(description: label) }
    func hold(_ value: ControlledSessionProtocol) {
        lock.lock(); pending = value; lock.unlock(); started.fulfill()
    }
    var request: URLRequest? { lock.lock(); defer { lock.unlock() }; return pending?.request }
    func reply(_ json: String = "", status: Int = 200) {
        lock.lock(); let value = pending; lock.unlock(); value?.reply(json, status: status)
    }
}

@MainActor
final class SessionRaceTests: XCTestCase {
    override func tearDown() {
        ControlledSessionProtocol.install(nil)
        super.tearDown()
    }

    private func makeControlledClient(authenticated: Bool = true) throws -> (MobileAPIClient, InMemoryTokenStore) {
        let tokens = InMemoryTokenStore(bundle: authenticated ? makeTokenBundle(access: "old-access", refresh: "old-refresh") : nil)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ControlledSessionProtocol.self]
        return (MobileAPIClient(config: try makeTestConfig(), tokenStore: tokens,
                                session: URLSession(configuration: config)), tokens)
    }

    func testLogoutClearsTokensBeforeHTTPAndLateFailureCannotClearNewLogin() async throws {
        let (client, tokens) = try makeControlledClient()
        let gate = RequestGate("old logout started")
        let refreshes = TestCounter()
        ControlledSessionProtocol.install { connection in
            if connection.request.url?.path == "/mobile/v1/auth/logout" { gate.hold(connection) }
            else { refreshes.increment(); connection.reply("{}", status: 500) }
        }
        let logout = Task { try await IdentityService(client: client).logout() }
        await fulfillment(of: [gate.started], timeout: 3)
        XCTAssertNil(tokens.load(), "Credentials must disappear before logout HTTP finishes")
        XCTAssertEqual(gate.request?.authorizationHeader, "Bearer old-access")
        XCTAssertEqual(gate.request?.httpBodyJSON?["refresh_token"] as? String, "old-refresh")
        try client.store(makeTokenBundle(access: "new-access", refresh: "new-refresh"))
        gate.reply(#"{"detail":"old_session_expired"}"#, status: 401)
        do { try await logout.value; XCTFail("Old revoke should report its own failure") }
        catch let error as MobileAPIError { XCTAssertTrue(error.isUnauthorized) }
        XCTAssertEqual(tokens.load()?.accessToken, "new-access")
        XCTAssertEqual(refreshes.count, 0, "Logout must not refresh or attach the current account")
    }

    func testLateBootstrapResponseCannotRestorePrivateUIAfterLogout() async throws {
        let (client, tokens) = try makeControlledClient()
        let app = MobileAppStore(client: client)
        let me = RequestGate("old profile started")
        let logoutGate = RequestGate("logout started")
        ControlledSessionProtocol.install { connection in
            if connection.request.url?.path == "/mobile/v1/me" { me.hold(connection) }
            else { logoutGate.hold(connection) }
        }
        let boot = Task { await app.bootstrap() }
        await fulfillment(of: [me.started], timeout: 3)
        let oldViewSession = app.sessionID
        let logout = Task { await app.logout() }
        await fulfillment(of: [logoutGate.started], timeout: 3)
        XCTAssertNil(tokens.load())
        XCTAssertNil(app.me)
        XCTAssertFalse(app.starting)
        XCTAssertNotEqual(app.sessionID, oldViewSession)
        me.reply(#"{"user_id":"old-user","email":"private@old.test","pets":[]}"#)
        await boot.value
        XCTAssertNil(app.me)
        XCTAssertNil(app.startupError)
        logoutGate.reply(status: 204)
        await logout.value
    }

    func testLateAccountSyncCannotOverwriteNewAccount() async throws {
        let (client, _) = try makeControlledClient()
        let app = MobileAppStore(client: client)
        app.me = MobileMeResponse(userId: "old-user")
        let oldMe = RequestGate("account sync started")
        ControlledSessionProtocol.install { connection in
            if connection.request.authorizationHeader == "Bearer old-access" { oldMe.hold(connection) }
            else { connection.reply(#"{"user_id":"new-user","pets":[]}"#) }
        }
        let sync = Task { try await app.finishLogin() }
        await fulfillment(of: [oldMe.started], timeout: 3)
        client.clearSession()
        try client.store(makeTokenBundle(access: "new-access", refresh: "new-refresh"))
        try await app.finishLogin()
        oldMe.reply(#"{"user_id":"old-user","pets":[]}"#)
        do { try await sync.value; XCTFail("Old profile must be discarded") }
        catch let error as MobileAPIError { XCTAssertEqual(error.kind, .cancelled) }
        XCTAssertEqual(app.me?.userId, "new-user")
    }

    func testLate401CannotRefreshOrSignOutNewAccount() async throws {
        let (client, tokens) = try makeControlledClient()
        let oldMe = RequestGate("old request started")
        let refreshes = TestCounter()
        ControlledSessionProtocol.install { connection in
            if connection.request.url?.path == "/mobile/v1/me" { oldMe.hold(connection) }
            else { refreshes.increment(); connection.reply("{}", status: 500) }
        }
        let old = Task { try await IdentityService(client: client).me() }
        await fulfillment(of: [oldMe.started], timeout: 3)
        try client.store(makeTokenBundle(access: "new-access", refresh: "new-refresh"))
        oldMe.reply(#"{"detail":"expired"}"#, status: 401)
        do { _ = try await old.value; XCTFail("Old HTTP failure must be cancelled") }
        catch let error as MobileAPIError { XCTAssertEqual(error.kind, .cancelled) }
        XCTAssertEqual(tokens.load()?.accessToken, "new-access")
        XCTAssertEqual(refreshes.count, 0)
    }

    func testUnauthorizedAlreadyDeliveredCannotClearDifferentGeneration() throws {
        let (client, tokens) = try makeControlledClient()
        let oldGeneration = client.sessionGeneration
        let oldFailure = MobileAPIError(kind: .unauthorized, status: 401, sessionGeneration: oldGeneration)
        try client.store(makeTokenBundle(access: "new-access", refresh: "new-refresh"))
        let app = MobileAppStore(client: client)
        app.me = MobileMeResponse(userId: "new-user")
        XCTAssertFalse(app.handleSessionError(oldFailure))
        XCTAssertEqual(tokens.load()?.accessToken, "new-access")
        XCTAssertEqual(app.me?.userId, "new-user")
    }

    func testLateRefreshCannotRestoreLoggedOutSession() async throws {
        let (client, tokens) = try makeControlledClient()
        let refresh = RequestGate("refresh started")
        ControlledSessionProtocol.install { refresh.hold($0) }
        let task = Task { try await client.refreshSession() }
        await fulfillment(of: [refresh.started], timeout: 3)
        client.clearSession()
        refresh.reply(#"{"access_token":"late-access","refresh_token":"late-refresh"}"#)
        do { _ = try await task.value; XCTFail("Logged out refresh must be discarded") }
        catch let error as MobileAPIError { XCTAssertEqual(error.kind, .cancelled) }
        XCTAssertNil(tokens.load())
    }

    func testLateRefreshFailureCannotClearNewAccount() async throws {
        let (client, tokens) = try makeControlledClient()
        let refresh = RequestGate("refresh started")
        ControlledSessionProtocol.install { refresh.hold($0) }
        let task = Task { try await client.refreshSession() }
        await fulfillment(of: [refresh.started], timeout: 3)
        try client.store(makeTokenBundle(access: "new-access", refresh: "new-refresh"))
        refresh.reply(#"{"detail":"revoked"}"#, status: 401)
        do { _ = try await task.value; XCTFail("Old refresh must be discarded") }
        catch let error as MobileAPIError { XCTAssertEqual(error.kind, .cancelled) }
        XCTAssertEqual(tokens.load()?.accessToken, "new-access")
    }

    func testLateOTPResponseCannotReplaceNewLogin() async throws {
        let (client, tokens) = try makeControlledClient(authenticated: false)
        let verify = RequestGate("verify started")
        ControlledSessionProtocol.install { verify.hold($0) }
        let task = Task { try await IdentityService(client: client).verifyEmail(challengeId: "old", code: "123456") }
        await fulfillment(of: [verify.started], timeout: 3)
        client.clearSession()
        try client.store(makeTokenBundle(access: "new-access", refresh: "new-refresh"))
        verify.reply(#"{"access_token":"old-login-access","refresh_token":"old-login-refresh"}"#)
        do { _ = try await task.value; XCTFail("Old OTP must not replace a later session") }
        catch let error as MobileAPIError { XCTAssertEqual(error.kind, .cancelled) }
        XCTAssertEqual(tokens.load()?.accessToken, "new-access")
    }

    func testProfileRetryAfterOTPDoesNotReplayConsumedCode() async throws {
        let (client, tokens) = try makeControlledClient(authenticated: false)
        let app = MobileAppStore(client: client)
        let verifies = TestCounter(), profiles = TestCounter()
        ControlledSessionProtocol.install { connection in
            if connection.request.url?.path == "/mobile/v1/auth/email/verify" {
                verifies.increment()
                connection.reply(#"{"access_token":"verified-access","refresh_token":"verified-refresh"}"#)
            } else if profiles.increment() == 1 { connection.fail(URLError(.notConnectedToInternet)) }
            else { connection.reply(#"{"user_id":"verified-user","pets":[]}"#) }
        }
        _ = try await IdentityService(client: client).verifyEmail(challengeId: "otp-once", code: "123456")
        await app.bootstrap()
        XCTAssertNotNil(app.startupError)
        XCTAssertFalse(app.starting)
        XCTAssertNil(app.me)
        XCTAssertEqual(tokens.load()?.accessToken, "verified-access")
        await app.bootstrap()
        XCTAssertEqual(app.me?.userId, "verified-user")
        XCTAssertNil(app.startupError)
        XCTAssertEqual(verifies.count, 1)
        XCTAssertEqual(profiles.count, 2)
    }

    func testLateConcurrent401ReusesAlreadyRotatedToken() async throws {
        let (client, _) = try makeControlledClient()
        let first = RequestGate("first old request"), second = RequestGate("second old request")
        let oldRequests = TestCounter(), refreshes = TestCounter()
        ControlledSessionProtocol.install { connection in
            if connection.request.url?.path == "/mobile/v1/auth/refresh" {
                refreshes.increment()
                connection.reply(#"{"access_token":"rotated-access","refresh_token":"rotated-refresh"}"#)
            } else if connection.request.authorizationHeader == "Bearer old-access" {
                if oldRequests.increment() == 1 { first.hold(connection) } else { second.hold(connection) }
            } else { connection.reply(#"{"user_id":"same-user","pets":[]}"#) }
        }
        let one = Task { try await IdentityService(client: client).me() }
        await fulfillment(of: [first.started], timeout: 3)
        let two = Task { try await IdentityService(client: client).me() }
        await fulfillment(of: [second.started], timeout: 3)
        first.reply(#"{"detail":"expired"}"#, status: 401)
        _ = try await one.value
        second.reply(#"{"detail":"expired"}"#, status: 401)
        _ = try await two.value
        XCTAssertEqual(refreshes.count, 1)
    }
}
