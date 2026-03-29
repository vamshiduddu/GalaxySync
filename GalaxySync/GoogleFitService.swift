import Foundation
import AuthenticationServices

// MARK: - Google Fit Data Models

struct GoogleFitDataPoint {
    let dataTypeName: String
    let startTimeNanos: Int64
    let endTimeNanos: Int64
    let values: [FitValue]
}

struct FitValue {
    let intVal: Int?
    let fpVal: Double?
    let stringVal: String?
    let mapVal: [String: Any]?

    init(intVal: Int? = nil, fpVal: Double? = nil, stringVal: String? = nil, mapVal: [String: Any]? = nil) {
        self.intVal = intVal
        self.fpVal = fpVal
        self.stringVal = stringVal
        self.mapVal = mapVal
    }
}

enum GoogleFitDataType: String {
    case stepCount          = "com.google.step_count.delta"
    case heartRate          = "com.google.heart_rate.bpm"
    case calories           = "com.google.calories.expended"
    case distance           = "com.google.distance.delta"
    case activeMinutes      = "com.google.active_minutes"
    case sleepSegment       = "com.google.sleep.segment"
    case oxygenSaturation   = "com.google.oxygen_saturation"
    case weight             = "com.google.weight"
    case bloodPressure      = "com.google.blood_pressure"
}

enum GoogleFitError: LocalizedError {
    case notAuthenticated
    case tokenExpired
    case networkError(Error)
    case invalidResponse
    case quotaExceeded
    case permissionDenied

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:     return "Not authenticated with Google Fit. Please sign in."
        case .tokenExpired:         return "Google Fit session expired. Please re-authenticate."
        case .networkError(let e):  return "Network error: \(e.localizedDescription)"
        case .invalidResponse:      return "Invalid response from Google Fit API."
        case .quotaExceeded:        return "Google Fit API quota exceeded. Try again later."
        case .permissionDenied:     return "Permission denied by Google Fit."
        }
    }
}

// MARK: - GoogleFitService

final class GoogleFitService {

    // Replace with your actual OAuth 2.0 Client ID from Google Cloud Console
    private let clientID = "YOUR_GOOGLE_CLIENT_ID.apps.googleusercontent.com"
    private let redirectURI = "com.yourcompany.galaxysync:/oauth2redirect"
    private let scopes = [
        "https://www.googleapis.com/auth/fitness.activity.read",
        "https://www.googleapis.com/auth/fitness.heart_rate.read",
        "https://www.googleapis.com/auth/fitness.sleep.read",
        "https://www.googleapis.com/auth/fitness.body.read",
        "https://www.googleapis.com/auth/fitness.blood_pressure.read",
        "https://www.googleapis.com/auth/fitness.oxygen_saturation.read"
    ]

    private let tokenEndpoint = "https://oauth2.googleapis.com/token"
    private let authEndpoint  = "https://accounts.google.com/o/oauth2/v2/auth"
    private let fitBaseURL    = "https://www.googleapis.com/fitness/v1/users/me"

    private var accessToken: String?
    private var refreshToken: String?
    private var tokenExpiryDate: Date?

    private let keychain = KeychainHelper.shared
    private let session: URLSession

    var isAuthenticated: Bool {
        guard let expiry = tokenExpiryDate, let _ = accessToken else { return false }
        return Date() < expiry
    }

    init(session: URLSession = .shared) {
        self.session = session
        loadTokensFromKeychain()
    }

    // MARK: - Authentication

    func authenticate(presentingViewController: ASWebAuthenticationSession.PresentationContextProvider? = nil) async throws {
        let authURL = buildAuthURL()

        let callbackURL = try await withCheckedThrowingContinuation { continuation in
            let authSession = ASWebAuthenticationSession(
                url: authURL,
                callbackURLScheme: "com.yourcompany.galaxysync"
            ) { callbackURL, error in
                if let error = error {
                    continuation.resume(throwing: GoogleFitError.networkError(error))
                } else if let callbackURL = callbackURL {
                    continuation.resume(returning: callbackURL)
                } else {
                    continuation.resume(throwing: GoogleFitError.invalidResponse)
                }
            }
            authSession.prefersEphemeralWebBrowserSession = true
            authSession.start()
        }

        let code = try extractAuthCode(from: callbackURL)
        try await exchangeCodeForTokens(code: code)
    }

    func refreshAccessTokenIfNeeded() async throws {
        guard let expiry = tokenExpiryDate else { throw GoogleFitError.notAuthenticated }
        guard Date() >= expiry.addingTimeInterval(-60) else { return }
        guard let refreshToken = refreshToken else { throw GoogleFitError.tokenExpired }
        try await refreshAccessToken(refreshToken: refreshToken)
    }

    // MARK: - Data Fetching

    func fetchDataPoints(
        dataType: GoogleFitDataType,
        startDate: Date,
        endDate: Date
    ) async throws -> [GoogleFitDataPoint] {
        try await refreshAccessTokenIfNeeded()
        guard let token = accessToken else { throw GoogleFitError.notAuthenticated }

        let startNanos = Int64(startDate.timeIntervalSince1970 * 1_000_000_000)
        let endNanos   = Int64(endDate.timeIntervalSince1970 * 1_000_000_000)

        let urlString = "\(fitBaseURL)/dataSources/derived:\(dataType.rawValue):com.google.android.gms:aggregated/datasets/\(startNanos)-\(endNanos)"

        guard let url = URL(string: urlString) else { throw GoogleFitError.invalidResponse }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        try validateHTTPResponse(response)

        return try parseDataPoints(from: data, dataType: dataType)
    }

    func fetchAggregatedData(
        dataType: GoogleFitDataType,
        startDate: Date,
        endDate: Date,
        bucketByTime: Int = 86400000
    ) async throws -> [GoogleFitDataPoint] {
        try await refreshAccessTokenIfNeeded()
        guard let token = accessToken else { throw GoogleFitError.notAuthenticated }

        let url = URL(string: "\(fitBaseURL)/dataset:aggregate")!

        let body: [String: Any] = [
            "aggregateBy": [["dataTypeName": dataType.rawValue]],
            "bucketByTime": ["durationMillis": bucketByTime],
            "startTimeMillis": Int64(startDate.timeIntervalSince1970 * 1000),
            "endTimeMillis": Int64(endDate.timeIntervalSince1970 * 1000)
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        try validateHTTPResponse(response)

        return try parseAggregatedDataPoints(from: data, dataType: dataType)
    }

    // MARK: - Private Helpers

    private func buildAuthURL() -> URL {
        var components = URLComponents(string: authEndpoint)!
        components.queryItems = [
            URLQueryItem(name: "client_id",     value: clientID),
            URLQueryItem(name: "redirect_uri",  value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope",         value: scopes.joined(separator: " ")),
            URLQueryItem(name: "access_type",   value: "offline"),
            URLQueryItem(name: "prompt",        value: "consent")
        ]
        return components.url!
    }

    private func extractAuthCode(from url: URL) throws -> String {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let code = components.queryItems?.first(where: { $0.name == "code" })?.value
        else { throw GoogleFitError.invalidResponse }
        return code
    }

    private func exchangeCodeForTokens(code: String) async throws {
        let body: [String: String] = [
            "code":          code,
            "client_id":     clientID,
            "redirect_uri":  redirectURI,
            "grant_type":    "authorization_code"
        ]
        try await performTokenRequest(body: body)
    }

    private func refreshAccessToken(refreshToken: String) async throws {
        let body: [String: String] = [
            "refresh_token": refreshToken,
            "client_id":     clientID,
            "grant_type":    "refresh_token"
        ]
        try await performTokenRequest(body: body)
    }

    private func performTokenRequest(body: [String: String]) async throws {
        var request = URLRequest(url: URL(string: tokenEndpoint)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await session.data(for: request)
        try validateHTTPResponse(response)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GoogleFitError.invalidResponse
        }

        accessToken    = json["access_token"] as? String
        refreshToken   = json["refresh_token"] as? String ?? self.refreshToken
        let expiresIn  = json["expires_in"] as? TimeInterval ?? 3600
        tokenExpiryDate = Date().addingTimeInterval(expiresIn)

        saveTokensToKeychain()
    }

    private func validateHTTPResponse(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw GoogleFitError.invalidResponse }
        switch http.statusCode {
        case 200...299: break
        case 401:       throw GoogleFitError.tokenExpired
        case 403:       throw GoogleFitError.permissionDenied
        case 429:       throw GoogleFitError.quotaExceeded
        default:        throw GoogleFitError.invalidResponse
        }
    }

    private func parseDataPoints(from data: Data, dataType: GoogleFitDataType) throws -> [GoogleFitDataPoint] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let points = json["point"] as? [[String: Any]]
        else { return [] }

        return points.compactMap { point -> GoogleFitDataPoint? in
            guard
                let startNanos = (point["startTimeNanos"] as? String).flatMap(Int64.init),
                let endNanos   = (point["endTimeNanos"]   as? String).flatMap(Int64.init),
                let rawValues  = point["value"] as? [[String: Any]]
            else { return nil }

            let values = rawValues.map { v -> FitValue in
                FitValue(
                    intVal:    v["intVal"] as? Int,
                    fpVal:     v["fpVal"]  as? Double,
                    stringVal: v["stringVal"] as? String,
                    mapVal:    v["mapVal"] as? [String: Any]
                )
            }

            return GoogleFitDataPoint(
                dataTypeName:   dataType.rawValue,
                startTimeNanos: startNanos,
                endTimeNanos:   endNanos,
                values:         values
            )
        }
    }

    private func parseAggregatedDataPoints(from data: Data, dataType: GoogleFitDataType) throws -> [GoogleFitDataPoint] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let buckets = json["bucket"] as? [[String: Any]]
        else { return [] }

        var result: [GoogleFitDataPoint] = []
        for bucket in buckets {
            guard
                let startMillis = (bucket["startTimeMillis"] as? String).flatMap(Int64.init),
                let endMillis   = (bucket["endTimeMillis"]   as? String).flatMap(Int64.init),
                let datasets    = bucket["dataset"] as? [[String: Any]]
            else { continue }

            for dataset in datasets {
                guard let points = dataset["point"] as? [[String: Any]] else { continue }
                for point in points {
                    guard let rawValues = point["value"] as? [[String: Any]] else { continue }
                    let values = rawValues.map { v -> FitValue in
                        FitValue(
                            intVal:    v["intVal"] as? Int,
                            fpVal:     v["fpVal"]  as? Double,
                            stringVal: v["stringVal"] as? String
                        )
                    }
                    result.append(GoogleFitDataPoint(
                        dataTypeName:   dataType.rawValue,
                        startTimeNanos: startMillis * 1_000_000,
                        endTimeNanos:   endMillis   * 1_000_000,
                        values:         values
                    ))
                }
            }
        }
        return result
    }

    // MARK: - Keychain Persistence

    private func saveTokensToKeychain() {
        if let token = accessToken {
            keychain.save(token, forKey: "google_fit_access_token")
        }
        if let token = refreshToken {
            keychain.save(token, forKey: "google_fit_refresh_token")
        }
        if let expiry = tokenExpiryDate {
            keychain.save(String(expiry.timeIntervalSince1970), forKey: "google_fit_token_expiry")
        }
    }

    private func loadTokensFromKeychain() {
        accessToken  = keychain.load(forKey: "google_fit_access_token")
        refreshToken = keychain.load(forKey: "google_fit_refresh_token")
        if let expiryStr = keychain.load(forKey: "google_fit_token_expiry"),
           let expiryTs  = Double(expiryStr) {
            tokenExpiryDate = Date(timeIntervalSince1970: expiryTs)
        }
    }
}

// MARK: - Minimal Keychain Helper

final class KeychainHelper {
    static let shared = KeychainHelper()
    private init() {}

    func save(_ value: String, forKey key: String) {
        guard let data = value.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecValueData as String:   data
        ]
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }

    func load(forKey key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String:  kCFBooleanTrue!,
            kSecMatchLimit as String:  kSecMatchLimitOne
        ]
        var item: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func delete(forKey key: String) {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }
}
