import AppKit
import CryptoKit
import ImageIO
import Network
import Security

enum DriveError: LocalizedError {
    case notConfigured, notSignedIn, auth(String), http(Int, String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: "Client ID dan Client Secret belum diisi di Settings."
        case .notSignedIn: "Belum login ke Google Drive. Buka Settings lalu klik Sign in."
        case .auth(let message): "Login gagal: \(message)"
        case .http(let status, let body): "Google API error \(status): \(body)"
        }
    }
}

struct DriveFile: Decodable, Sendable {
    let id: String
    let name: String
    let createdTime: Date
    let webViewLink: String
    let thumbnailLink: String?
}

/// Google Drive upload via OAuth 2.0 for desktop apps (loopback redirect + PKCE).
@MainActor
final class GoogleDrive {
    static let shared = GoogleDrive()

    private static let clientIDKey = "googleClientID"
    private static let secretKey = "googleClientSecret"
    private static let refreshKey = "googleRefreshToken"
    private static let folderKey = "googleDriveFolder"
    private static let folderMime = "application/vnd.google-apps.folder"

    private var accessToken: String?
    private var accessTokenExpiry = Date.distantPast

    var clientID: String {
        get { UserDefaults.standard.string(forKey: Self.clientIDKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: Self.clientIDKey) }
    }

    var clientSecret: String {
        get { Keychain.get(Self.secretKey) ?? "" }
        set { Keychain.set(newValue, for: Self.secretKey) }
    }

    /// Upload destination folder name; empty means the My Drive root.
    var folderName: String {
        get { UserDefaults.standard.string(forKey: Self.folderKey) ?? "Screenshoot" }
        set { UserDefaults.standard.set(newValue, forKey: Self.folderKey) }
    }

    var isSignedIn: Bool { Keychain.get(Self.refreshKey) != nil }

    func signOut() {
        Keychain.set(nil, for: Self.refreshKey)
        accessToken = nil
    }

    func signIn() async throws {
        guard !clientID.isEmpty, !clientSecret.isEmpty else { throw DriveError.notConfigured }
        let verifier = randomURLSafe(bytes: 32)
        let challenge = base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = randomURLSafe(bytes: 16)

        let receiver = try LoopbackReceiver()
        let redirect = "http://127.0.0.1:\(try await receiver.start())"
        var auth = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        auth.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirect),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: "https://www.googleapis.com/auth/drive.file"),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent"),
            .init(name: "state", value: state),
        ]
        NSWorkspace.shared.open(auth.url!)

        let query = try await receiver.waitForCallback()
        guard query["state"] == state else { throw DriveError.auth("state tidak cocok") }
        guard let code = query["code"] else { throw DriveError.auth(query["error"] ?? "kode tidak diterima") }
        let token = try await tokenRequest([
            "code": code, "redirect_uri": redirect,
            "grant_type": "authorization_code", "code_verifier": verifier,
        ])
        guard let refresh = token.refresh_token else { throw DriveError.auth("Google tidak mengirim refresh token") }
        Keychain.set(refresh, for: Self.refreshKey)
    }

    /// Uploads the PNG, makes it readable by anyone with the link, and returns that link.
    func upload(png: Data, name: String) async throws -> String {
        let token = try await validAccessToken()
        let boundary = UUID().uuidString
        var meta: [String: Any] = ["name": name, "mimeType": "image/png"]
        if let folder = try await folderID(token: token) { meta["parents"] = [folder] }
        let metadata = try JSONSerialization.data(withJSONObject: meta)
        var body = Data("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".utf8)
        body.append(metadata)
        body.append(Data("\r\n--\(boundary)\r\nContent-Type: image/png\r\n\r\n".utf8))
        body.append(png)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var request = URLRequest(url: URL(string: "https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart&fields=id,webViewLink")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        struct File: Decodable { let id: String; let webViewLink: String }
        let file = try JSONDecoder().decode(File.self, from: try await send(request))

        _ = try await send(try jsonRequest("https://www.googleapis.com/drive/v3/files/\(file.id)/permissions",
                                           token: token, body: ["role": "reader", "type": "anyone"]))
        return file.webViewLink
    }

    /// Finds the app-created folder named `folderName`, creating it if missing. nil means the My Drive root.
    /// The `drive.file` scope only lists files this app created, so a same-named user folder is never picked.
    private func folderID(token: String) async throws -> String? {
        let name = folderName
        guard !name.isEmpty else { return nil }
        let escaped = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        var list = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        list.queryItems = [
            .init(name: "q", value: "name = '\(escaped)' and mimeType = '\(Self.folderMime)' and trashed = false"),
            .init(name: "fields", value: "files(id)"),
            .init(name: "pageSize", value: "1"),
        ]
        let request = getRequest(list, token: token)
        struct Folder: Decodable { let id: String }
        struct Listing: Decodable { let files: [Folder] }
        if let existing = try JSONDecoder().decode(Listing.self, from: try await send(request)).files.first {
            return existing.id
        }
        let create = try jsonRequest("https://www.googleapis.com/drive/v3/files?fields=id",
                                     token: token, body: ["name": name, "mimeType": Self.folderMime])
        return try JSONDecoder().decode(Folder.self, from: try await send(create)).id
    }

    /// Every image this app uploaded, newest first. The `drive.file` scope only returns this app's files.
    func listUploads() async throws -> [DriveFile] {
        let token = try await validAccessToken()
        let decoder = JSONDecoder()
        // Drive timestamps carry milliseconds ("2026-10-14T03:21:09.512Z"), which `.iso8601` rejects.
        decoder.dateDecodingStrategy = .custom { decoder in
            try Date.ISO8601FormatStyle(includingFractionalSeconds: true)
                .parse(decoder.singleValueContainer().decode(String.self))
        }
        struct Page: Decodable { let files: [DriveFile]; let nextPageToken: String? }

        var files: [DriveFile] = []
        var pageToken: String?
        repeat {
            var list = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
            list.queryItems = [
                .init(name: "q", value: "mimeType contains 'image/' and trashed = false"),
                .init(name: "orderBy", value: "createdTime desc"),
                .init(name: "pageSize", value: "100"),
                .init(name: "fields", value: "nextPageToken,files(id,name,createdTime,webViewLink,thumbnailLink)"),
            ]
            if let pageToken { list.queryItems?.append(.init(name: "pageToken", value: pageToken)) }
            let page = try decoder.decode(Page.self, from: try await send(getRequest(list, token: token)))
            files += page.files
            pageToken = page.nextPageToken
        } while pageToken != nil
        return files
    }

    /// Preview at most `maxPixels` on its longest side: Drive's thumbnail if it has one, else the original downscaled.
    func thumbnail(for file: DriveFile, maxPixels: Int) async throws -> NSImage? {
        let token = try await validAccessToken()
        var sources: [String] = []
        if let link = file.thumbnailLink {
            // Thumbnail links end in a size suffix such as "=s220".
            sources.append(link.replacingOccurrences(of: #"=s\d+$"#, with: "=s\(maxPixels)", options: .regularExpression))
        }
        sources.append("https://www.googleapis.com/drive/v3/files/\(file.id)?alt=media")
        for source in sources {
            guard let url = URL(string: source) else { continue }
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            if let data = try? await send(request), let image = Self.downscaled(data, maxPixels: maxPixels) {
                return image
            }
        }
        return nil
    }

    private static func downscaled(_ data: Data, maxPixels: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixels,
              ] as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: .zero)
    }

    private func getRequest(_ components: URLComponents, token: String) -> URLRequest {
        var components = components
        // URLComponents leaves "+" unescaped, but the server decodes it as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func jsonRequest(_ url: String, token: String, body: [String: Any]) throws -> URLRequest {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// Toolbar entry point: uploads in the background and puts the link on the clipboard.
    func uploadAndCopyLink(_ png: Data, name: String) {
        guard isSignedIn else {
            SettingsWindowController.shared.show()
            return
        }
        Toast.show("Mengunggah ke Google Drive…", duration: 60)
        Task {
            do {
                let link = try await upload(png: png, name: name)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(link, forType: .string)
                Toast.show("Link disalin: \(link)")
                GalleryWindowController.shared.reloadIfVisible()
            } catch {
                Toast.hide()
                NSApp.activate(ignoringOtherApps: true)
                NSAlert(error: error).runModal()
            }
        }
    }

    // MARK: Tokens

    private struct TokenResponse: Decodable {
        let access_token: String
        let expires_in: Double
        let refresh_token: String?
    }

    private func validAccessToken() async throws -> String {
        if let accessToken, Date() < accessTokenExpiry { return accessToken }
        guard let refresh = Keychain.get(Self.refreshKey) else { throw DriveError.notSignedIn }
        do {
            return try await tokenRequest(["refresh_token": refresh, "grant_type": "refresh_token"]).access_token
        } catch DriveError.http(400, let body) where body.contains("invalid_grant") {
            signOut() // revoked or expired (7 days while the consent screen is in "Testing")
            throw DriveError.notSignedIn
        }
    }

    private func tokenRequest(_ params: [String: String]) async throws -> TokenResponse {
        var form = URLComponents()
        form.queryItems = params.merging(["client_id": clientID, "client_secret": clientSecret]) { a, _ in a }
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        // URLComponents leaves "+" unescaped, but form decoding reads it as a space.
        request.httpBody = Data((form.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
        let token = try JSONDecoder().decode(TokenResponse.self, from: try await send(request))
        accessToken = token.access_token
        accessTokenExpiry = Date().addingTimeInterval(token.expires_in - 60)
        return token
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw DriveError.http(status, String(decoding: data, as: UTF8.self)) }
        return data
    }

    private func randomURLSafe(bytes: Int) -> String {
        base64URL(Data((0..<bytes).map { _ in UInt8.random(in: .min ... .max) }))
    }

    private func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - OAuth loopback receiver

/// One-shot HTTP listener on 127.0.0.1 that captures the OAuth redirect query. All state lives on `queue`.
final class LoopbackReceiver: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "screenshoot.oauth")
    private var ready: CheckedContinuation<UInt16, Error>?
    private var waiter: CheckedContinuation<[String: String], Error>?
    private var result: Result<[String: String], Error>?

    init() throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: params)
    }

    /// Starts listening and returns the bound port.
    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                ready = continuation
                listener.stateUpdateHandler = { [self] state in
                    switch state {
                    case .ready:
                        ready?.resume(returning: listener.port?.rawValue ?? 0)
                        ready = nil
                    case .failed(let error):
                        ready?.resume(throwing: error)
                        ready = nil
                        finish(.failure(error))
                    default: break
                    }
                }
                listener.newConnectionHandler = { [self] in handle($0) }
                listener.start(queue: queue)
            }
        }
    }

    func waitForCallback(timeout: TimeInterval = 300) async throws -> [String: String] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                if let result { return continuation.resume(with: result) }
                waiter = continuation
                queue.asyncAfter(deadline: .now() + timeout) { [self] in
                    finish(.failure(DriveError.auth("timeout, browser tidak kembali ke app")))
                }
            }
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [self] data, _, _, _ in
            // Request line: "GET /?code=...&state=... HTTP/1.1"
            let request = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
            let target = request.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            let items = URLComponents(string: target)?.queryItems ?? []
            guard !items.isEmpty else { return connection.cancel() } // e.g. /favicon.ico

            let html = "<html><body style='font-family:-apple-system;text-align:center;margin-top:20vh'>"
                + "<h2>Screenshoot: login selesai. Silakan kembali ke app.</h2></body></html>"
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n"
                + "Content-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            finish(.success(Dictionary(items.map { ($0.name, $0.value ?? "") }) { first, _ in first }))
        }
    }

    private func finish(_ outcome: Result<[String: String], Error>) {
        guard result == nil else { return }
        result = outcome
        listener.stateUpdateHandler = nil
        listener.newConnectionHandler = nil
        listener.cancel()
        waiter?.resume(with: outcome)
        waiter = nil
    }
}

// MARK: - Keychain

enum Keychain {
    private static let service = "com.local.screenshoot"

    private static func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: key]
    }

    static func get(_ key: String) -> String? {
        var q = query(key)
        q[kSecReturnData as String] = true
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// `nil` or empty deletes the item.
    static func set(_ value: String?, for key: String) {
        SecItemDelete(query(key) as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var q = query(key)
        q[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(q as CFDictionary, nil)
    }
}
