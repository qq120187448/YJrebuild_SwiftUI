import XCTest
@testable import Robo

#if canImport(FoundationModels)
@available(iOS 26, *)
final class ChatServiceHitParsingTests: XCTestCase {

    // MARK: - Parsing Tests

    func testParseHitResults_MarkdownLinkFormat() {
        // This is the ACTUAL format Apple Intelligence produces
        let content = """
        Here's the availability poll for the ski trip:

        • Vince: [Link](https://robo.app/hit/IbATsszG)
        • E: [Link](https://robo.app/hit/PhK9aF6E)
        • Turtle: [Link](https://robo.app/hit/3OK7tFuX)

        Share each link with the corresponding person. They can pick their available times in their browser.
        """

        let results = extractHitResults(from: content)

        XCTAssertEqual(results.count, 3, "Should extract 3 HIT results from markdown link format")
        XCTAssertEqual(results[0].name, "Vince")
        XCTAssertEqual(results[0].url, "https://robo.app/hit/IbATsszG")
        XCTAssertEqual(results[1].name, "E")
        XCTAssertEqual(results[1].url, "https://robo.app/hit/PhK9aF6E")
        XCTAssertEqual(results[2].name, "Turtle")
        XCTAssertEqual(results[2].url, "https://robo.app/hit/3OK7tFuX")
    }

    func testParseHitResults_PlainURLFormat() {
        // Original format from tool output
        let content = """
        Created availability poll: Ski Trip

        • Vince: https://robo.app/hit/abc123
        • E: https://robo.app/hit/def456
        • Turtle: https://robo.app/hit/ghi789

        Share each link with the corresponding person.
        """

        let results = extractHitResults(from: content)

        XCTAssertEqual(results.count, 3, "Should extract 3 HIT results from plain URL format")
        XCTAssertEqual(results[0].name, "Vince")
        XCTAssertEqual(results[0].url, "https://robo.app/hit/abc123")
        XCTAssertEqual(results[1].name, "E")
        XCTAssertEqual(results[1].url, "https://robo.app/hit/def456")
        XCTAssertEqual(results[2].name, "Turtle")
        XCTAssertEqual(results[2].url, "https://robo.app/hit/ghi789")
    }

    func testParseHitResults_DashBulletFormat() {
        let content = """
        - Sarah: [Link](https://robo.app/hit/aaa111)
        - Mike: [Link](https://robo.app/hit/bbb222)
        """

        let results = extractHitResults(from: content)

        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].name, "Sarah")
        XCTAssertEqual(results[1].name, "Mike")
    }

    func testParseHitResults_FallbackFindsURLs() {
        // Even if format is totally unknown, we should find the URLs
        let content = """
        I made polls for everyone!
        Check out https://robo.app/hit/xxx111 and https://robo.app/hit/yyy222
        """

        let results = extractHitResults(from: content)

        XCTAssertEqual(results.count, 2, "Fallback should find URLs even without bullet format")
        XCTAssertEqual(results[0].url, "https://robo.app/hit/xxx111")
        XCTAssertEqual(results[1].url, "https://robo.app/hit/yyy222")
    }

    func testParseHitResults_NoHitURLs() {
        let content = "Sure, I can help you plan a trip! Who's coming?"

        let results = extractHitResults(from: content)

        XCTAssertEqual(results.count, 0, "Should return empty when no HIT URLs present")
    }

    // MARK: - Content Cleaning Tests

    func testCleanHitContent_RemovesMarkdownLinks() {
        let content = """
        Here's the availability poll for the ski trip:

        • Vince: [Link](https://robo.app/hit/IbATsszG)
        • E: [Link](https://robo.app/hit/PhK9aF6E)
        • Turtle: [Link](https://robo.app/hit/3OK7tFuX)

        Share each link with the corresponding person.
        """

        let cleaned = ChatService.cleanHitContent(content)

        XCTAssertFalse(cleaned.contains("robo.app/hit/"), "Cleaned content should not contain HIT URLs")
        XCTAssertTrue(cleaned.contains("availability poll"), "Should keep the intro text")
        XCTAssertTrue(cleaned.contains("Share each link"), "Should keep the outro text")
    }

    func testCleanHitContent_RemovesPlainURLs() {
        let content = """
        Created poll:

        • Vince: https://robo.app/hit/abc123

        Done!
        """

        let cleaned = ChatService.cleanHitContent(content)

        XCTAssertFalse(cleaned.contains("robo.app/hit/"), "Cleaned content should not contain HIT URLs")
        XCTAssertTrue(cleaned.contains("Created poll"), "Should keep non-URL text")
        XCTAssertTrue(cleaned.contains("Done!"), "Should keep non-URL text")
    }

    // MARK: - Test Helper (mirrors ChatService parsing logic)

    private func extractHitResults(from content: String) -> [(name: String, url: String)] {
        var results: [(name: String, url: String)] = []
        let nsContent = content as NSString

        // Strategy 1: Markdown link format
        let mdPattern = "(?:•|\\-|\\*)\\s*([^:\\n]+):\\s*\\[[^\\]]*\\]\\((https://robo\\.app/hit/[a-zA-Z0-9\\-]+)\\)"
        if let regex = try? NSRegularExpression(pattern: mdPattern, options: []) {
            let matches = regex.matches(in: content, range: NSRange(location: 0, length: nsContent.length))
            for match in matches where match.numberOfRanges == 3 {
                let nameRange = match.range(at: 1)
                let urlRange = match.range(at: 2)
                if nameRange.location != NSNotFound, urlRange.location != NSNotFound {
                    let name = nsContent.substring(with: nameRange).trimmingCharacters(in: .whitespaces)
                    let url = nsContent.substring(with: urlRange)
                    results.append((name: name, url: url))
                }
            }
        }

        // Strategy 2: Plain URL format
        if results.isEmpty {
            let plainPattern = "(?:•|\\-|\\*|\\d+\\.)\\s*([^:\\n]+):\\s*(https://robo\\.app/hit/[a-zA-Z0-9\\-]+)"
            if let regex = try? NSRegularExpression(pattern: plainPattern, options: []) {
                let matches = regex.matches(in: content, range: NSRange(location: 0, length: nsContent.length))
                for match in matches where match.numberOfRanges == 3 {
                    let nameRange = match.range(at: 1)
                    let urlRange = match.range(at: 2)
                    if nameRange.location != NSNotFound, urlRange.location != NSNotFound {
                        let name = nsContent.substring(with: nameRange).trimmingCharacters(in: .whitespaces)
                        let url = nsContent.substring(with: urlRange)
                        results.append((name: name, url: url))
                    }
                }
            }
        }

        // Strategy 3: Fallback — find any URLs
        if results.isEmpty {
            let urlPattern = "https://robo\\.app/hit/[a-zA-Z0-9\\-]+"
            if let urlRegex = try? NSRegularExpression(pattern: urlPattern, options: []) {
                let urlMatches = urlRegex.matches(in: content, range: NSRange(location: 0, length: nsContent.length))
                for (i, urlMatch) in urlMatches.enumerated() {
                    let url = nsContent.substring(with: urlMatch.range)
                    results.append((name: "Person \(i + 1)", url: url))
                }
            }
        }

        return results
    }
}
#endif
