import Foundation
import Testing
@testable import Robo

// MARK: - HIT Result Parsing (tests the parsing logic used by ChatService)

@Suite struct HitResultParsingTests {

    @Test func parseHitResults_extractsNamesAndURLs() {
        let content = """
        Created availability poll: Ski Trip

        • Sarah: https://robo.app/hit/abc12345
        • Mike: https://robo.app/hit/def67890

        Share each link with the corresponding person.
        """

        let lines = content.components(separatedBy: "\n")
        var results: [(name: String, url: String)] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("•"),
               let colonRange = trimmed.range(of: ": https://robo.app/hit/") {
                let name = String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 2)..<colonRange.lowerBound])
                let url = String(trimmed[colonRange.lowerBound..<trimmed.endIndex]).dropFirst(2)
                results.append((name: name.trimmingCharacters(in: .whitespaces), url: String(url)))
            }
        }

        #expect(results.count == 2)
        #expect(results[0].name == "Sarah")
        #expect(results[0].url == "https://robo.app/hit/abc12345")
        #expect(results[1].name == "Mike")
        #expect(results[1].url == "https://robo.app/hit/def67890")
    }

    @Test func parseHitResults_handlesNoMatches() {
        let content = "I can help you plan that! Who's coming?"
        let lines = content.components(separatedBy: "\n")
        var results: [(name: String, url: String)] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("•"),
               let colonRange = trimmed.range(of: ": https://robo.app/hit/") {
                let name = String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 2)..<colonRange.lowerBound])
                let url = String(trimmed[colonRange.lowerBound..<trimmed.endIndex]).dropFirst(2)
                results.append((name: name.trimmingCharacters(in: .whitespaces), url: String(url)))
            }
        }

        #expect(results.isEmpty)
    }

    @Test func parseHitResults_singleParticipant() {
        let content = "• Alex: https://robo.app/hit/xyz99999\n"

        let lines = content.components(separatedBy: "\n")
        var results: [(name: String, url: String)] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("•"),
               let colonRange = trimmed.range(of: ": https://robo.app/hit/") {
                let name = String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 2)..<colonRange.lowerBound])
                let url = String(trimmed[colonRange.lowerBound..<trimmed.endIndex]).dropFirst(2)
                results.append((name: name.trimmingCharacters(in: .whitespaces), url: String(url)))
            }
        }

        #expect(results.count == 1)
        #expect(results[0].name == "Alex")
    }
}

// MARK: - HitCreateResponse Decoding

@Suite struct HitResponseDecodingTests {

    @Test func decodesHitCreateResponse_withHitType() throws {
        let json = """
        {
            "id": "abc123",
            "url": "https://robo.app/hit/abc123",
            "recipient_name": "Sarah",
            "task_description": "When are you free?",
            "status": "pending",
            "hit_type": "availability"
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        let response = try decoder.decode(HitCreateResponse.self, from: json)

        #expect(response.id == "abc123")
        #expect(response.hitType == "availability")
        #expect(response.recipientName == "Sarah")
    }

    @Test func decodesHitCreateResponse_withoutHitType() throws {
        let json = """
        {
            "id": "abc123",
            "url": "https://robo.app/hit/abc123",
            "recipient_name": "Sarah",
            "task_description": "Send photos",
            "status": "pending"
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        let response = try decoder.decode(HitCreateResponse.self, from: json)

        #expect(response.id == "abc123")
        #expect(response.hitType == nil)
    }
}

// MARK: - HitSummary availability type

@Suite struct HitSummaryTests {

    @Test func decodesAvailabilityHitSummary() throws {
        let json = """
        {
            "id": "test1",
            "recipient_name": "Mike",
            "task_description": "When are you free for: Ski Trip?",
            "status": "pending",
            "photo_count": 0,
            "created_at": "2026-02-15T00:00:00Z",
            "hit_type": "availability"
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        let hit = try decoder.decode(HitSummary.self, from: json)

        #expect(hit.hitType == "availability")
        #expect(hit.recipientName == "Mike")
        #expect(hit.taskDescription == "When are you free for: Ski Trip?")
    }

    @Test func decodesPhotoHitSummary_hitTypeNil() throws {
        let json = """
        {
            "id": "test2",
            "recipient_name": "Jane",
            "task_description": "Take a photo of X",
            "status": "completed",
            "photo_count": 3,
            "created_at": "2026-02-15T00:00:00Z",
            "completed_at": "2026-02-15T01:00:00Z"
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        let hit = try decoder.decode(HitSummary.self, from: json)

        #expect(hit.hitType == nil)
        #expect(hit.photoCount == 3)
    }
}

// MARK: - HitResponseItem Decoding

@Suite struct HitResponseItemTests {

    @Test func decodesHitResponseItem() throws {
        let json = """
        {
            "id": "resp1",
            "hit_id": "hit1",
            "respondent_name": "Sarah",
            "response_data": {"available_slots": [{"date": "2026-05-03", "time": "5 PM"}]},
            "created_at": "2026-02-15T12:00:00Z"
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        let item = try decoder.decode(HitResponseItem.self, from: json)

        #expect(item.respondentName == "Sarah")
        #expect(item.hitId == "hit1")
        #expect(item.responseData["available_slots"] != nil)
    }
}

// MARK: - SpeechRecognitionService

@Suite struct SpeechRecognitionServiceTests {

    @Test func initialState_notRecording() {
        let service = SpeechRecognitionService()
        #expect(!service.isRecording)
        #expect(service.transcribedText.isEmpty)
        #expect(service.errorMessage == nil)
    }

    @Test func stopRecording_whenNotRecording_isNoOp() {
        let service = SpeechRecognitionService()
        service.stopRecording()
        #expect(!service.isRecording)
        #expect(service.transcribedText.isEmpty)
    }
}
