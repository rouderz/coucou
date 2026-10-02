import XCTest
@testable import Coucou

/// Google: PKCE, the redirect, and reading mails.
final class GoogleTests: XCTestCase {
    func testPKCEChallengeMatchesRFC7636() {
        // RFC 7636, appendix B.
        XCTAssertEqual(GoogleText.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
                       "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testBase64URL() {
        XCTAssertEqual(GoogleText.base64url(Data("hi?".utf8)), "aGk_")
        XCTAssertEqual(GoogleText.decodeBase64url("aGk_"), Data("hi?".utf8))
        XCTAssertEqual(GoogleText.decodeBase64url("SGVsbG8gd29ybGQ"), Data("Hello world".utf8))
    }

    func testRedirect() {
        let ok = GoogleText.parseRedirect("GET /?state=abc&code=4%2F0Ab&scope=x HTTP/1.1\r\nHost: x")
        XCTAssertEqual(ok?.code, "4/0Ab")
        XCTAssertEqual(ok?.state, "abc")
        XCTAssertNil(ok?.error)
        XCTAssertEqual(GoogleText.parseRedirect("GET /?error=access_denied&state=abc HTTP/1.1")?.error, "access_denied")
        XCTAssertNil(GoogleText.parseRedirect("GET /favicon.ico HTTP/1.1")?.code)
    }

    func testMailParts() {
        XCTAssertEqual(GoogleText.senderName("\"Ana Pérez\" <ana@x.com>"), "Ana Pérez")
        XCTAssertEqual(GoogleText.senderName("<ana@x.com>"), "ana@x.com")
        let payload: [String: Any] = ["mimeType": "multipart/alternative", "parts": [
            ["mimeType": "text/html", "body": ["data": GoogleText.base64url(Data("<p>Hola</p>".utf8))]],
            ["mimeType": "text/plain", "body": ["data": GoogleText.base64url(Data("Hola, plain".utf8))]],
        ]]
        XCTAssertEqual(GoogleText.messageText(payload), "Hola, plain")
        let html: [String: Any] = ["mimeType": "text/html", "body": ["data": GoogleText.base64url(Data("<p>Hola <b>tú</b></p>".utf8))]]
        XCTAssertEqual(GoogleText.messageText(html), "Hola tú")
    }

    func testExportsAndNames() {
        XCTAssertEqual(GoogleText.exportType("application/vnd.google-apps.spreadsheet")?.1, "csv")
        XCTAssertNil(GoogleText.exportType("application/pdf"))
        XCTAssertEqual(GoogleText.safeFileName("Q3 / budget: final"), "Q3 _ budget_ final")
    }
}
