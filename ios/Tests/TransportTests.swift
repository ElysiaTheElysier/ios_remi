import XCTest
@testable import Remi

final class StubProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { }
}

@MainActor
final class TransportTests: XCTestCase {
    func client() -> API {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubProtocol.self]
        let session = Session(access_token: "synthetic-test-token", refresh_token: "synthetic-refresh", expires_in: 3600)
        return API(config: Configuration(api: "https://example.invalid/api/v1", auth: "https://auth.invalid", publicKey: "synthetic-public"), session: session, transport: URLSession(configuration: config))
    }
    func testDecimalAndUnknownFieldsSurviveReview() throws {
        let data = Data(#"{"amount":"12345678901234567890.12","reminder":{"trigger_at":"2026-10-04T18:00:00+07:00"},"extension":null}"#.utf8)
        let json = try JSONDecoder().decode(JSON.self, from: data)
        XCTAssertEqual(json["amount"].string, "12345678901234567890.12")
        XCTAssertEqual(try JSONDecoder().decode(JSON.self, from: JSONEncoder().encode(json)), json)
    }
    func testHTTPSAndNoCredentialsInURL() {
        for url in ["http://example.invalid/api/v1", "https://user:pass@example.invalid", "https://example.invalid?token=secret"] {
            XCTAssertThrowsError(try Configuration(api: url, auth: "https://auth.invalid", publicKey: "public").validate())
        }
    }
    func testConfirmationHeadersAndPayloadAreExact() async throws {
        let payload = JSON.body(["amount": .string("50.25"), "domain": .string("expense")])
        let body = JSON.body(["source_message_id": .string("source"), "proposal_version": .number(3), "payload": payload])
        StubProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/v1/actions/proposal/confirm")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-test-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Idempotency-Key"), "same-retry-key")
            // URLSession may represent request bodies as a stream in URLProtocol.
            var data = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 1024)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }; data.append(contentsOf: buffer.prefix(count))
                }
            }
            XCTAssertEqual(try JSONDecoder().decode(JSON.self, from: data), body)
            return (200, Data(#"{"status":"persisted","record_id":"record","audit_event_id":"audit"}"#.utf8))
        }
        let result = try await client().request("/actions/proposal/confirm", method: "POST", body: body, key: "same-retry-key")
        XCTAssertEqual(result["status"].string, "persisted")
        StubProtocol.handler = nil
    }
    func testFailureNeverReturnsSuccessfulJSON() async {
        StubProtocol.handler = { _ in (409, Data(#"{"code":"stale_version","message":"Phiên bản đã thay đổi"}"#.utf8)) }
        do { _ = try await client().request("/actions/proposal/confirm", method: "POST"); XCTFail("Expected failure") }
        catch { XCTAssertEqual(error.localizedDescription, "Phiên bản đã thay đổi") }
        StubProtocol.handler = nil
    }
    func testMissingSessionFailsBeforeNetwork() async {
        let api = client(); api.session = nil
        StubProtocol.handler = { _ in XCTFail("No credential must not send request"); return (200, Data()) }
        do { _ = try await api.request("/records"); XCTFail("Expected authentication failure") }
        catch { XCTAssertEqual(error.localizedDescription, "Vui lòng đăng nhập.") }
        StubProtocol.handler = nil
    }
    func testStoreRetainsExactIdempotencyKeyAfterLostResult() async throws {
        let api = client(); let store = Store(client: api)
        let proposal = Item(.body(["id": .string("proposal"), "source_message_id": .string("source"),
            "version": .number(2), "payload": .body(["domain": .string("expense"), "amount": .string("50.25")])]))
        var observedKeys: [String] = []
        StubProtocol.handler = { request in
            observedKeys.append(request.value(forHTTPHeaderField: "Idempotency-Key") ?? "")
            throw URLError(.networkConnectionLost)
        }
        for _ in 0..<2 {
            do { try await store.confirm(proposal); XCTFail("Expected lost result") } catch { }
        }
        XCTAssertEqual(observedKeys.count, 2)
        XCTAssertFalse(observedKeys[0].isEmpty)
        XCTAssertEqual(observedKeys[0], observedKeys[1])
        StubProtocol.handler = nil
    }
    func testStoreDoesNotAcceptSuccessWithoutAuditEvidence() async {
        let store = Store(client: client())
        let proposal = Item(.body(["id": .string("proposal"), "source_message_id": .string("source"), "version": .number(1), "payload": .body([:])]))
        store.proposals = [proposal]
        StubProtocol.handler = { _ in (200, Data(#"{"status":"persisted","record_id":"record"}"#.utf8)) }
        do { try await store.confirm(proposal); XCTFail("Expected missing audit evidence failure") } catch { }
        XCTAssertEqual(store.proposals.count, 1)
        StubProtocol.handler = nil
    }
}
