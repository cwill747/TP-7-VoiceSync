//
//  AppleNotesServiceTests.swift
//  TeenageEngVoiceSyncTests
//
//  AppleScript source is built by string interpolation, and note bodies are
//  raw HTML, so these escapers are the only thing standing between a
//  transcription/title/folder name and script or markup injection.
//

import XCTest
@testable import TP_7_VoiceSync

final class AppleNotesServiceTests: XCTestCase {
    private let service = AppleNotesService()

    // MARK: - escapeForAppleScript

    func testEscapesBackslash() {
        XCTAssertEqual(service.escapeForAppleScript(#"C:\Users\test"#), #"C:\\Users\\test"#)
    }

    func testEscapesDoubleQuote() {
        XCTAssertEqual(service.escapeForAppleScript(#"Say "hello""#), #"Say \"hello\""#)
    }

    func testEscapesNewlineTabReturn() {
        let backslash = "\\"
        let input = "Line1\tTabbed\nLine2\rReturn"
        let expected = "Line1" + backslash + "tTabbed" + backslash + "nLine2" + backslash + "rReturn"
        XCTAssertEqual(service.escapeForAppleScript(input), expected)
    }

    /// A folder/title/body containing an embedded AppleScript injection
    /// attempt: backslash-then-quote sequences must not collapse or
    /// double-escape depending on replacement order.
    func testEscapesBackslashQuoteInjectionAttempt() {
        let backslash = "\\"
        let quote = "\""
        let input = "He said " + backslash + quote + "hi" + backslash + quote + " and left"
        let expected = "He said "
            + backslash + backslash + backslash + quote
            + "hi"
            + backslash + backslash + backslash + quote
            + " and left"
        XCTAssertEqual(service.escapeForAppleScript(input), expected)
    }

    func testEscapesAppleScriptTellBlockInjectionAttempt() {
        let input = "Notes\"\nend tell\ndo shell script \"rm -rf /\"\ntell application \"Notes"
        let expected = #"Notes\"\nend tell\ndo shell script \"rm -rf /\"\ntell application \"Notes"#
        XCTAssertEqual(service.escapeForAppleScript(input), expected)
    }

    func testPlainStringIsUnchanged() {
        XCTAssertEqual(service.escapeForAppleScript("Just a normal title"), "Just a normal title")
    }

    // MARK: - escapeHTML

    func testEscapesAmpersandLessThanGreaterThan() {
        let input = "<script>alert(\"xss\")</script> & Co."
        let expected = "&lt;script&gt;alert(\"xss\")&lt;/script&gt; &amp; Co."
        XCTAssertEqual(service.escapeHTML(input), expected)
    }

    func testHTMLEscapeDoesNotTouchQuotes() {
        // escapeHTML only guards against tag/entity injection, not attribute
        // breakout — quotes pass through unescaped by design.
        XCTAssertEqual(service.escapeHTML(#"He said "hi""#), #"He said "hi""#)
    }

    func testHTMLEscapePlainStringIsUnchanged() {
        XCTAssertEqual(service.escapeHTML("Just a normal transcription."), "Just a normal transcription.")
    }
}
