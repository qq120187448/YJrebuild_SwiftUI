import Foundation
import AuthenticationServices
import CryptoKit
import Security
import UIKit
import os

private let logger = Logger(subsystem: "com.silv.Robo", category: "CoindexService")

@MainActor
@Observable
class CoindexService: NSObject {
    var isAuthenticated = false

    private static let baseURL = "https://coindex.app"
    private static let clientID = "robo_mobile_client"
    private static let callbackScheme = "robo"
    private static let keychainService = "com.silv.Robo.coindex"
    private static let keychainAccount = "access_token"

    private var accessToken: String? {
        didSet { isAuthenticated = accessToken != nil }
    }
    private var authSession: ASWebAuthenticationSession?

    override init() {
        super.init()
        accessToken = Self.loadToken()
        isAuthenticated = accessToken != nil
    }

    // MARK: - OAuth PKCE

    func authenticate() async throws {
        let verifier = Self.generateCodeVerifier()
        let challenge = Self.sha256Base64URL(verifier)

        let authURL = URL(string: "\(Self.baseURL)/oauth/authorize?client_id=\(Self.clientID)&response_type=code&code_challenge=\(challenge)&code_challenge_method=S256&redirect_uri=robo://oauth/callback")!

        let code = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            let session = ASWebAuthenticationSession(url: authURL, callbackURLScheme: Self.callbackScheme) { [weak self] url, error in
                self?.authSession = nil
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let url,
                      let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                      let code = components.queryItems?.first(where: { $0.name == "code" })?.value else {
                    continuation.resume(throwing: CoindexError.noAuthCode)
                    return
                }
                continuation.resume(returning: code)
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.authSession = session
            session.start()
        }

        // Exchange code for token
        let tokenURL = URL(string: "\(Self.baseURL)/oauth/token")!
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: String] = [
            "grant_type": "authorization_code",
            "client_id": Self.clientID,
            "code": code,
            "code_verifier": verifier,
            "redirect_uri": "robo://oauth/callback"
        ]
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw CoindexError.tokenExchangeFailed
        }

        let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)
        accessToken = tokenResponse.accessToken
        Self.saveToken(tokenResponse.accessToken)
        logger.info("Coindex authentication successful")
    }

    func logout() {
        accessToken = nil
        Self.deleteToken()
    }

    // MARK: - Upload Photos

    /// Upload photos to Coindex and create an album. Returns the album URL.
    func uploadPhotos(title: String, photoFilenames: [String]) async throws -> String {
        guard let token = accessToken else { throw CoindexError.notAuthenticated }

        // Load photos and re-encode as JPEG. UIImage auto-applies EXIF orientation,
        // and jpegData() re-encodes without EXIF metadata (strips location, camera info, etc.)
        // This matches Coindex's web approach: read orientation → apply → re-encode.
        var photoDataList: [Data] = []
        for filename in photoFilenames {
            if let image = PhotoStorageService.load(filename),
               let data = image.jpegData(compressionQuality: 0.85) {
                photoDataList.append(data)
            }
        }

        guard !photoDataList.isEmpty else { throw CoindexError.noPhotos }

        // Step 1: Create album and get presigned upload URLs
        let createURL = URL(string: "\(Self.baseURL)/api/albums")!
        var createReq = URLRequest(url: createURL)
        createReq.httpMethod = "POST"
        createReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        createReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let createBody: [String: Any] = [
            "title": title,
            "photoCount": photoDataList.count
        ]
        createReq.httpBody = try JSONSerialization.data(withJSONObject: createBody)

        let (createData, createResponse) = try await URLSession.shared.data(for: createReq)
        guard let httpResp = createResponse as? HTTPURLResponse, httpResp.statusCode == 200 || httpResp.statusCode == 201 else {
            throw CoindexError.albumCreationFailed
        }

        let albumResponse = try JSONDecoder().decode(AlbumResponse.self, from: createData)

        // Step 2: Upload each photo to its presigned URL
        for (index, presignedURL) in albumResponse.uploadURLs.enumerated() {
            guard index < photoDataList.count else { break }
            var uploadReq = URLRequest(url: URL(string: presignedURL)!)
            uploadReq.httpMethod = "PUT"
            uploadReq.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
            uploadReq.httpBody = photoDataList[index]

            let (_, uploadResp) = try await URLSession.shared.data(for: uploadReq)
            guard let httpUpload = uploadResp as? HTTPURLResponse, (200...299).contains(httpUpload.statusCode) else {
                logger.error("Failed to upload photo \(index)")
                throw CoindexError.uploadFailed
            }
        }

        // Step 3: Finalize the album
        let finalizeURL = URL(string: "\(Self.baseURL)/api/albums/\(albumResponse.albumId)/finalize")!
        var finalizeReq = URLRequest(url: finalizeURL)
        finalizeReq.httpMethod = "POST"
        finalizeReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (_, finalizeResp) = try await URLSession.shared.data(for: finalizeReq)
        guard let httpFinalize = finalizeResp as? HTTPURLResponse, (200...299).contains(httpFinalize.statusCode) else {
            throw CoindexError.finalizeFailed
        }

        logger.info("Uploaded \(photoDataList.count) photos to album \(albumResponse.albumId)")
        return albumResponse.albumURL
    }

    // MARK: - PKCE Helpers

    private static func generateCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncoded()
    }

    private static func sha256Base64URL(_ input: String) -> String {
        let hash = SHA256.hash(data: Data(input.utf8))
        return Data(hash).base64URLEncoded()
    }

    // MARK: - Keychain

    private static func saveToken(_ token: String) {
        let data = Data(token.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        SecItemDelete(query as CFDictionary)
        var addQuery = query
        addQuery[kSecValueData as String] = data
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    private static func loadToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func deleteToken() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - ASWebAuthenticationPresentationContextProviding

extension CoindexService: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = scene.windows.first else {
            return ASPresentationAnchor()
        }
        return window
    }
}

// MARK: - Models

enum CoindexError: LocalizedError {
    case noAuthCode
    case tokenExchangeFailed
    case notAuthenticated
    case noPhotos
    case albumCreationFailed
    case uploadFailed
    case finalizeFailed

    var errorDescription: String? {
        switch self {
        case .noAuthCode: return "No authorization code received"
        case .tokenExchangeFailed: return "Failed to exchange code for token"
        case .notAuthenticated: return "Not authenticated with Coindex"
        case .noPhotos: return "No photos to upload"
        case .albumCreationFailed: return "Failed to create album on Coindex"
        case .uploadFailed: return "Failed to upload photo"
        case .finalizeFailed: return "Failed to finalize album"
        }
    }
}

private struct TokenResponse: Decodable {
    let accessToken: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
    }
}

private struct AlbumResponse: Decodable {
    let albumId: String
    let albumURL: String
    let uploadURLs: [String]

    enum CodingKeys: String, CodingKey {
        case albumId = "album_id"
        case albumURL = "album_url"
        case uploadURLs = "upload_urls"
    }
}

// MARK: - Data extension for base64url

private extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
