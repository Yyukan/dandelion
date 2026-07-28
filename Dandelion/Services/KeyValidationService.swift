//
//  KeyValidationService.swift
//  Dandelion
//
//  Validates a discovered OpenCode API key with a zero-cost, 1-token
//  completion call - never a request against `/v1/models` (verified live to
//  accept any garbage key) and never a request against a paid model.
//

import Foundation

enum KeyValidationResult: Sendable, Equatable {
    case valid
    case invalid
    case networkError
}

/// Performs the $0 completion check described in the plan's research
/// findings: `POST /zen/v1/chat/completions` enforces the key (401 on a bad
/// one) while costing nothing when targeted at a free model.
///
/// Both Zen and Go keys are validated against the same free Zen model: Go
/// has no free-tier model of its own, and routing the check through Zen's
/// `big-pickle` model avoids ever consuming a Go subscriber's limited
/// 5h/weekly/monthly usage-window quota just to confirm the key works.
struct KeyValidationService: Sendable {
    private let session: URLSession
    private let endpoint = URL(string: "https://opencode.ai/zen/v1/chat/completions")!
    private let freeValidationModel = "big-pickle"

    init(session: URLSession = .shared) {
        self.session = session
    }

    func validate(_ credential: OpenCodeCredential) async -> KeyValidationResult {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(credential.apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": freeValidationModel,
            "messages": [["role": "user", "content": "ping"]],
            "max_tokens": 1
        ])

        do {
            let (_, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else { return .networkError }
            switch httpResponse.statusCode {
            case 200..<300:
                return .valid
            case 401:
                return .invalid
            default:
                return .networkError
            }
        } catch {
            return .networkError
        }
    }
}
