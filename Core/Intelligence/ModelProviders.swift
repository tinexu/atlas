import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Exactly what a language model is given: instructions, the request, and
/// the JSON Schema its answer must follow. Shared by the Companion's command
/// planner and workflow generation.
public struct ModelRequest: Equatable, Sendable {
    public let instructions: String
    public let input: String
    /// JSON Schema, as JSON text.
    public let schemaJSON: String

    public init(instructions: String, input: String, schemaJSON: String) {
        self.instructions = instructions
        self.input = input
        self.schemaJSON = schemaJSON
    }

    public init(instructions: String, input: String, schema: [String: Any]) {
        let data = (try? JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys])) ?? Data("{}".utf8)
        self.init(instructions: instructions, input: input, schemaJSON: String(data: data, encoding: .utf8) ?? "{}")
    }

    public var schema: [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(schemaJSON.utf8))) as? [String: Any] ?? [:]
    }

    public var preview: String { "INSTRUCTIONS\n\(instructions)\n\nREQUEST\n\(input)" }
}

/// A language model that answers a `ModelRequest` with JSON text.
public protocol IntentModelProvider: Sendable {
    var displayName: String { get }
    /// Nil when it can be used; otherwise why not, in words.
    func unavailableReason() async -> String?
    func complete(_ request: ModelRequest) async throws -> String
}

public struct ModelError: Error, LocalizedError, Equatable {
    public let reason: String
    public init(_ reason: String) { self.reason = reason }
    public var errorDescription: String? { reason }
}

/// Apple's on-device model (Apple Intelligence). Nothing leaves the Mac.
public struct OnDeviceModelProvider: IntentModelProvider {
    public init() {}
    public var displayName: String { "Apple Intelligence (on-device)" }

    public func unavailableReason() async -> String? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return SystemLanguageModel.default.isAvailable
                ? nil : "Apple Intelligence isn't available on this Mac (it may be off in System Settings or still downloading)."
        }
        #endif
        return "On-device AI needs macOS 26 or later with Apple Intelligence."
    }

    public func complete(_ request: ModelRequest) async throws -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let session = LanguageModelSession(instructions: request.instructions + "\n\nJSON schema:\n" + request.schemaJSON)
            return try await session.respond(to: request.input + "\n\nAnswer with the JSON object only.").content
        }
        #endif
        throw ModelError("On-device AI isn't available.")
    }
}

/// Claude through the Messages API, with the person's own API key (kept in
/// the Keychain). Only used when they choose it.
public struct CloudModelProvider: IntentModelProvider {
    public let model: String
    let apiKey: @Sendable () -> String?
    let session: URLSession

    public init(model: String, apiKey: @escaping @Sendable () -> String? = { CompanionKeychain.apiKey() }, session: URLSession = .shared) {
        self.model = model
        self.apiKey = apiKey
        self.session = session
    }

    public var displayName: String { "Claude (\(model))" }

    public func unavailableReason() async -> String? {
        (apiKey()?.isEmpty ?? true) ? "Add your Claude API key in Companion settings." : nil
    }

    /// The JSON body sent to the API, also used for "Preview request".
    public func body(for request: ModelRequest) -> [String: Any] {
        [
            "model": model,
            "max_tokens": 4_000,
            "system": request.instructions,
            "messages": [["role": "user", "content": request.input]],
            "output_config": ["effort": "low", "format": ["type": "json_schema", "schema": request.schema]],
            "fallbacks": "default",
        ]
    }

    public func complete(_ request: ModelRequest) async throws -> String {
        guard let key = apiKey(), !key.isEmpty else { throw ModelError("No Claude API key is saved.") }
        var urlRequest = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 45
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        urlRequest.setValue(key, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        urlRequest.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body(for: request))
        let (data, response) = try await session.data(for: urlRequest)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard status == 200, let json else {
            let message = ((json?["error"] as? [String: Any])?["message"] as? String) ?? "HTTP \(status)"
            throw ModelError(status == 401 ? "The Claude API key was rejected." : "Claude couldn't answer: \(message)")
        }
        if json["stop_reason"] as? String == "refusal" { throw ModelError("Claude declined that request.") }
        let content = json["content"] as? [[String: Any]] ?? []
        let text = content.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
        guard !text.isEmpty else { throw ModelError("Claude returned nothing.") }
        return text
    }
}

/// The Claude API key, in the login Keychain.
public enum CompanionKeychain {
    static let service = "com.atlas.companion.claude"
    static let account = "api-key"

    public static func apiKey() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    public static func setAPIKey(_ key: String?) -> Bool {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        guard let key, !key.isEmpty else { return true }
        var add = base
        add[kSecValueData as String] = Data(key.utf8)
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}

/// Pulls the JSON object out of a model's answer (bare, or wrapped in prose or a code fence).
public func extractJSONObject(_ text: String) -> Data? {
    guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else { return nil }
    return Data(text[start...end].utf8)
}
