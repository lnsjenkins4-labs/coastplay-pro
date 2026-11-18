// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
// PRIVATE PROTOTYPE — NOT FOR DISTRIBUTION.
import Foundation
import CChiakiShim
import RGPCore

/// What is kept (in the Keychain, by the app) after a PlayStation sign-in.
/// No password is ever part of this: Sony's page handles the password.
struct PSNAccount: Codable {
    var accountID: String        // base64 of the 8-byte account number; needed for pairing
    var refreshToken: String
    var accessToken: String
    var accessExpiry: Date
    var duid: String             // client device identifier the tokens were issued for
}

/// PlayStation sign-in on Sony's own web page. The flow and endpoints are the ones the
/// chiaki-ng project uses; the client values come from its source (see gen-psn-client.sh).
final class PSNSignIn: AccountSignIn {
    let providerName = "PlayStation"
    let redirectPrefix = "https://remoteplay.dl.playstation.net/remoteplay/redirect"

    private let scope = "psn:clientapp referenceDataService:countryConfig.read pushNotification:webSocket.desktop.connect sessionManager:remotePlaySession.system.update"
    private let tokenURL = URL(string: "https://auth.api.sonyentertainmentnetwork.com/2.0/oauth/token")!
    private var pendingDUID = ""

    func makeSignInURL() -> URL {
        var buffer = [CChar](repeating: 0, count: 64)
        if rgp_psn_generate_duid(&buffer, buffer.count) == 0 { pendingDUID = String(cString: buffer) }
        var components = URLComponents(string: "https://auth.api.sonyentertainmentnetwork.com/2.0/oauth/authorize")!
        components.queryItems = [
            .init(name: "service_entity", value: "urn:service-entity:psn"),
            .init(name: "response_type", value: "code"),
            .init(name: "client_id", value: PSNClient.id),
            .init(name: "redirect_uri", value: redirectPrefix),
            .init(name: "scope", value: scope),
            .init(name: "request_locale", value: "en_US"),
            .init(name: "ui", value: "pr"),
            .init(name: "service_logo", value: "ps"),
            .init(name: "layout_type", value: "popup"),
            .init(name: "smcid", value: "remoteplay"),
            .init(name: "prompt", value: "always"),
            .init(name: "PlatformPrivacyWs1", value: "minimal"),
            .init(name: "duid", value: pendingDUID),
        ]
        return components.url!
    }

    private var basicAuth: String {
        "Basic " + Data("\(PSNClient.id):\(PSNClient.secret)".utf8).base64EncodedString()
    }

    private static let failure = SessionFailure(
        code: .unknown, title: "PlayStation sign-in didn't finish",
        message: "Sony's sign-in page did not return what the app needs.",
        recovery: ["Try signing in again.", "If it keeps failing, wait a few minutes; Sony limits repeated attempts."], canRetry: true)

    func complete(redirect: URL) async throws -> Data {
        guard let code = URLComponents(url: redirect, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "code" })?.value, !code.isEmpty else { throw Self.failure }

        // 1. Exchange the one-time code for tokens.
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue(basicAuth, forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = [.init(name: "grant_type", value: "authorization_code"), .init(name: "code", value: code),
                           .init(name: "scope", value: scope), .init(name: "redirect_uri", value: redirectPrefix)]
        request.httpBody = Data((form.percentEncodedQuery ?? "").utf8)
        let (tokenData, tokenResponse) = try await URLSession.shared.data(for: request)
        guard (tokenResponse as? HTTPURLResponse)?.statusCode == 200,
              let tokens = try? JSONSerialization.jsonObject(with: tokenData) as? [String: Any],
              let access = tokens["access_token"] as? String, let refresh = tokens["refresh_token"] as? String else { throw Self.failure }
        let lifetime = (tokens["expires_in"] as? Double) ?? 3600

        // 2. Ask which account the token belongs to. Only the numeric id is kept.
        var info = URLRequest(url: tokenURL.appendingPathComponent(access))
        info.setValue(basicAuth, forHTTPHeaderField: "Authorization")
        let (infoData, infoResponse) = try await URLSession.shared.data(for: info)
        guard (infoResponse as? HTTPURLResponse)?.statusCode == 200,
              let account = try? JSONSerialization.jsonObject(with: infoData) as? [String: Any],
              let userID = (account["user_id"] as? String).flatMap(UInt64.init) else { throw Self.failure }
        var little = userID.littleEndian
        let accountID = withUnsafeBytes(of: &little) { Data($0) }.base64EncodedString()

        let stored = PSNAccount(accountID: accountID, refreshToken: refresh, accessToken: access,
                                accessExpiry: Date().addingTimeInterval(lifetime), duid: pendingDUID)
        return try JSONEncoder().encode(stored)
    }

    /// Returns the account with a token that is valid for at least the next couple of minutes,
    /// asking Sony for a new one with the stored refresh token when needed.
    func refreshed(_ stored: Data) async throws -> (account: PSNAccount, updated: Data?) {
        guard var account = try? JSONDecoder().decode(PSNAccount.self, from: stored) else { throw Self.signInAgain }
        if account.accessExpiry.timeIntervalSinceNow > 120 { return (account, nil) }
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue(basicAuth, forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = [.init(name: "grant_type", value: "refresh_token"), .init(name: "refresh_token", value: account.refreshToken),
                           .init(name: "scope", value: scope), .init(name: "redirect_uri", value: redirectPrefix)]
        request.httpBody = Data((form.percentEncodedQuery ?? "").utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let tokens = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = tokens["access_token"] as? String else { throw Self.signInAgain }
        account.accessToken = access
        if let refresh = tokens["refresh_token"] as? String { account.refreshToken = refresh }
        account.accessExpiry = Date().addingTimeInterval((tokens["expires_in"] as? Double) ?? 3600)
        return (account, try JSONEncoder().encode(account))
    }

    static let signInAgain = SessionFailure(
        code: .unknown, title: "PlayStation sign-in has expired",
        message: "Sony no longer accepts the saved sign-in, so the app can't connect away from home.",
        recovery: ["Open Settings, sign out of PlayStation, and sign in again."], canRetry: false)

    func accountIdentifier(from stored: Data) -> String? {
        (try? JSONDecoder().decode(PSNAccount.self, from: stored))?.accountID
    }
}
