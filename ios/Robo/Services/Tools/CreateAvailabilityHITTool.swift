#if canImport(FoundationModels)
import Foundation
import FoundationModels

@available(iOS 26, *)
struct CreateAvailabilityHITTool: Tool {
    let name = "create_availability_poll"
    let description = """
        Creates an availability poll and sends unique links to each participant. \
        Use this when the user wants to find a time that works for a group of people. \
        Returns a link for each participant that they can open in their browser to vote.
        """

    @Generable
    struct Arguments {
        @Guide(description: "Title for the event, e.g. 'Ski Trip' or 'Team Dinner'")
        var eventTitle: String

        @Guide(description: "Comma-separated list of participant names, e.g. 'Sarah, Mike, Alex'")
        var participants: String

        @Guide(description: "Comma-separated list of date options in ISO format (YYYY-MM-DD), e.g. '2026-05-03, 2026-05-10'")
        var dateOptions: String

        @Guide(description: "Comma-separated list of time slots, e.g. '5 PM, 6 PM, 7 PM, 8 PM'")
        var timeSlots: String
    }

    let apiService: APIService

    func call(arguments: Arguments) async throws -> String {
        var names = arguments.participants
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        // Include the creator as a participant if they have a name set
        if let creatorName = UserDefaults.standard.string(forKey: "firstName"),
           !creatorName.isEmpty,
           !names.contains(where: { $0.localizedCaseInsensitiveCompare(creatorName) == .orderedSame }) {
            names.insert(creatorName, at: 0)
        }

        let dates = arguments.dateOptions
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }

        let times = arguments.timeSlots
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }

        guard !names.isEmpty else {
            return "Error: No participant names provided."
        }

        let config: [String: Any] = [
            "title": arguments.eventTitle,
            "date_options": dates,
            "time_slots": times,
            "days": dates.count
        ]

        var results: [(name: String, url: String)] = []
        let groupId = UUID().uuidString

        for name in names {
            do {
                let response = try await apiService.createHit(
                    recipientName: name,
                    taskDescription: "When are you free for: \(arguments.eventTitle)?",
                    hitType: "availability",
                    config: config,
                    groupId: groupId
                )
                results.append((name: name, url: response.url))
            } catch {
                results.append((name: name, url: "Error: \(error.localizedDescription)"))
            }
        }

        var output = "Created availability poll: \(arguments.eventTitle)\n\n"
        for result in results {
            output += "• \(result.name): \(result.url)\n"
        }
        output += "\nShare each link with the corresponding person. They can pick their available times in their browser."

        return output
    }
}
extension APIService: @unchecked Sendable {}
#endif
