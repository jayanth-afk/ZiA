import Foundation
import Testing
@testable import Jarvis

/// AppleScript is an executable authority. A URL is untrusted model output, so
/// it must never be able to terminate the AppleScript string literal and inject
/// a second statement.
@Suite struct BrowserScriptSafetyTests {

    @Test func urlEscapingNeutralizesLiteralBreakout() {
        let hostile = "https://example.com/\"; do shell script \"echo pwned\"; --"
        let escaped = BrowserManager.appleScriptStringLiteral(hostile)
        // Every quote is backslash-escaped, so it cannot terminate the literal.
        let expected = "https://example.com/\\\"; do shell script \\\"echo pwned\\\"; --"
        #expect(escaped == expected)
        #expect(!escaped.contains("\n") && !escaped.contains("\r"))
    }

    @Test func urlEscapingNeutralizesBackslashAndNewlines() {
        let hostile = "https://example.com/\\\"\n\r evil"
        let escaped = BrowserManager.appleScriptStringLiteral(hostile)
        #expect(!escaped.contains("\n") && !escaped.contains("\r"))
        #expect(escaped.contains("\\\\"), "backslashes must be escaped")
    }

    @Test func benignUrlIsUnchanged() {
        let url = "https://example.com/path?q=1"
        #expect(BrowserManager.appleScriptStringLiteral(url) == url)
    }
}
