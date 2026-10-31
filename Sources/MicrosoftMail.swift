import Foundation
import Security

struct MailPreview { let subject: String; let sender: String; let received: String; let body: String; let link: String }
private struct MailCredential: Codable { let clientID: String; let refreshToken: String }

@MainActor
final class MicrosoftMail: ObservableObject {
    @Published var status = "Not connected"
    @Published var deviceCode = ""
    @Published var verificationURL: URL?
    @Published var connected = false
    @Published var signingIn = false
    private var accessToken = ""
    private var expires = Date.distantPast
    private var credential: MailCredential?
    private let service = "com.local.jarvis.microsoft365"
    private let scopes = "https://graph.microsoft.com/Mail.Read offline_access"

    init() {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "mail", kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data {
            credential = try? JSONDecoder().decode(MailCredential.self, from: data)
            connected = credential != nil
            if connected { status = "Connected · read-only mail" }
        }
    }

    private func post(_ path: String, fields: [String: String]) async throws -> [String: Any] {
        let url = URL(string: "https://login.microsoftonline.com/organizations/oauth2/v2.0/\(path)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        request.httpBody = fields.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }.joined(separator: "&").data(using: .utf8)
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let body = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw JarvisError.message("Microsoft returned an unreadable response.") }
        return body
    }

    func signIn(clientID: String) async {
        guard !signingIn else { return }
        let id = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard UUID(uuidString: id) != nil else { status = "Enter your organization's public-client app ID (a UUID)."; return }
        signingIn = true; status = "Starting Microsoft sign-in…"
        defer { signingIn = false; deviceCode = ""; verificationURL = nil }
        do {
            let start = try await post("devicecode", fields: ["client_id": id, "scope": scopes])
            guard let device = start["device_code"] as? String, let code = start["user_code"] as? String, let address = start["verification_uri"] as? String, let url = URL(string: address), url.scheme == "https" else {
                throw JarvisError.message("Microsoft could not start sign-in. Check the app ID and public-client/device-code configuration.")
            }
            deviceCode = code; verificationURL = url
            status = "Enter the code at Microsoft to connect read-only mail."
            let deadline = Date().addingTimeInterval(min(start["expires_in"] as? Double ?? 900, 900))
            var interval = max(start["interval"] as? Double ?? 5, 5)
            while Date() < deadline {
                try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                try Task.checkCancellation()
                let result = try await post("token", fields: ["client_id": id, "grant_type": "urn:ietf:params:oauth:grant-type:device_code", "device_code": device])
                if result["access_token"] != nil { try accept(result, clientID: id); return }
                switch result["error"] as? String {
                case "authorization_pending": continue
                case "slow_down": interval += 5
                case "authorization_declined", "access_denied": throw JarvisError.message("Microsoft sign-in was declined.")
                case "expired_token": throw JarvisError.message("Sign-in expired. Start again when ready.")
                default: throw JarvisError.message("Microsoft sign-in could not complete. Your tenant may require administrator consent.")
                }
            }
            throw JarvisError.message("Sign-in expired. Start again when ready.")
        } catch is CancellationError { status = "Sign-in cancelled" }
        catch { status = error.localizedDescription }
    }

    private func accept(_ result: [String: Any], clientID: String) throws {
        guard let token = result["access_token"] as? String, let refresh = result["refresh_token"] as? String ?? credential?.refreshToken else { throw JarvisError.message("Microsoft did not issue the required tokens.") }
        let value = MailCredential(clientID: clientID, refreshToken: refresh)
        let data = try JSONEncoder().encode(value)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "mail"]
        let updated = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updated == errSecItemNotFound {
            var entry = query; entry[kSecValueData as String] = data; entry[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(entry as CFDictionary, nil) == errSecSuccess else { throw JarvisError.message("Could not save the Microsoft sign-in in Keychain.") }
        } else if updated != errSecSuccess { throw JarvisError.message("Could not update the Microsoft sign-in in Keychain.") }
        credential = value; accessToken = token; expires = Date().addingTimeInterval((result["expires_in"] as? Double ?? 3600) - 60)
        connected = true; status = "Connected · read-only mail"
    }

    func disconnect() {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "mail"]
        SecItemDelete(query as CFDictionary)
        credential = nil; accessToken = ""; connected = false; status = "Disconnected"
    }

    func unread(retrying: Bool = true) async throws -> [MailPreview] {
        guard let credential else { throw JarvisError.message("Connect Microsoft 365 in Connections to include unread emails.") }
        if Date() >= expires {
            let result = try await post("token", fields: ["client_id": credential.clientID, "grant_type": "refresh_token", "refresh_token": credential.refreshToken, "scope": scopes])
            guard result["access_token"] != nil else { connected = false; status = "Sign-in expired"; throw JarvisError.message("Microsoft sign-in expired. Reconnect your mailbox.") }
            try accept(result, clientID: credential.clientID)
        }
        let since = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-7 * 24 * 3600))
        var components = URLComponents(string: "https://graph.microsoft.com/v1.0/me/mailFolders/inbox/messages")!
        components.queryItems = [URLQueryItem(name: "$top", value: "5"), URLQueryItem(name: "$select", value: "subject,from,receivedDateTime,bodyPreview,webLink"), URLQueryItem(name: "$filter", value: "receivedDateTime ge \(since) and isRead eq false"), URLQueryItem(name: "$orderby", value: "receivedDateTime desc")]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        // A revoked token is rejected before its local expiry; refresh once instead of failing for up to an hour.
        if (response as? HTTPURLResponse)?.statusCode == 401, retrying { expires = .distantPast; return try await unread(retrying: false) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw JarvisError.message("Microsoft could not read your inbox. Check your account's Mail.Read consent.") }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], let messages = object["value"] as? [[String: Any]] else { throw JarvisError.message("Microsoft returned an unreadable inbox response.") }
        return messages.map { message in
            let sender = ((message["from"] as? [String: Any])?["emailAddress"] as? [String: Any])?["name"] as? String ?? "Unknown sender"
            return MailPreview(subject: message["subject"] as? String ?? "No subject", sender: sender, received: message["receivedDateTime"] as? String ?? "", body: message["bodyPreview"] as? String ?? "", link: message["webLink"] as? String ?? "")
        }
    }
}
