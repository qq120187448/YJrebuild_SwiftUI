import SwiftUI

enum HitDistributionMode: String, CaseIterable {
    case individual
    case group
    case open

    var label: String {
        switch self {
        case .individual: return "Individual"
        case .group: return "Group"
        case .open: return "Open"
        }
    }

    var description: String {
        switch self {
        case .individual: return "Separate link per person"
        case .group: return "One link, pick name from list"
        case .open: return "One link, anyone can respond"
        }
    }
}

struct CreateHitView: View {
    @Environment(APIService.self) private var apiService
    @Environment(\.dismiss) private var dismiss

    @State private var distributionMode: HitDistributionMode = .individual
    @State private var yourName = ""
    @State private var taskDescription = ""
    @State private var participantNames = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var createdHitURL: URL?
    @State private var createdHitURLs: [(name: String, url: URL)] = []
    @State private var showResults = false

    private var otherParticipants: [String] {
        participantNames
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// All participants including the creator
    private var allParticipants: [String] {
        let trimmedName = yourName.trimmingCharacters(in: .whitespaces)
        var list = otherParticipants
        if !trimmedName.isEmpty {
            list.insert(trimmedName, at: 0)
        }
        return list
    }

    private var isValid: Bool {
        let hasDescription = !taskDescription.trimmingCharacters(in: .whitespaces).isEmpty
        let hasYourName = !yourName.trimmingCharacters(in: .whitespaces).isEmpty
        switch distributionMode {
        case .individual, .group:
            return hasDescription && hasYourName && !otherParticipants.isEmpty
        case .open:
            return hasDescription
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Distribution", selection: $distributionMode) {
                        ForEach(HitDistributionMode.allCases, id: \.self) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text(distributionMode.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if distributionMode != .open {
                    Section("Your Name") {
                        TextField("Your first name", text: $yourName)
                            .textContentType(.name)
                            .textInputAutocapitalization(.words)
                    }

                    Section("Other Participants") {
                        TextField("Names (comma-separated)", text: $participantNames)
                            .textContentType(.name)
                            .textInputAutocapitalization(.words)

                        if !allParticipants.isEmpty {
                            Text("\(allParticipants.count) total: \(allParticipants.joined(separator: ", "))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Task") {
                    TextField("What do you need from them?", text: $taskDescription, axis: .vertical)
                        .lineLimit(3...6)
                }

                Section {
                    Button {
                        Task { await createHit() }
                    } label: {
                        HStack {
                            Spacer()
                            if isLoading {
                                ProgressView()
                            } else {
                                Label("Generate Link\(distributionMode == .individual && allParticipants.count > 1 ? "s" : "")", systemImage: "link.badge.plus")
                            }
                            Spacer()
                        }
                    }
                    .disabled(!isValid || isLoading)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }

                if !createdHitURLs.isEmpty {
                    Section("Generated Links") {
                        ForEach(createdHitURLs, id: \.url) { item in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(item.name)
                                        .font(.headline)
                                    Text(item.url.absoluteString)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                ShareLink(item: item.url) {
                                    Image(systemName: "square.and.arrow.up")
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Create HIT")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .sheet(item: $createdHitURL) { url in
                ShareSheet(activityItems: [url])
            }
        }
    }

    private func createHit() async {
        isLoading = true
        errorMessage = nil

        do {
            let result = try await apiService.createHitWithMode(
                distributionMode: distributionMode.rawValue,
                taskDescription: taskDescription.trimmingCharacters(in: .whitespaces),
                participants: distributionMode != .open ? allParticipants : nil,
                senderName: yourName.trimmingCharacters(in: .whitespaces).isEmpty ? nil : yourName.trimmingCharacters(in: .whitespaces)
            )

            if let urls = result.hits, !urls.isEmpty {
                // Individual mode: show all links inline
                createdHitURLs = urls.compactMap { hit in
                    guard let url = URL(string: hit.url) else { return nil }
                    return (name: hit.name, url: url)
                }
            } else if let urlString = result.url, let url = URL(string: urlString) {
                // Group/open mode: single share sheet
                createdHitURL = url
            }
        } catch {
            errorMessage = "Failed to create HIT: \(error.localizedDescription)"
        }

        isLoading = false
    }
}

// ShareSheet and URL+Identifiable defined in SettingsView.swift
