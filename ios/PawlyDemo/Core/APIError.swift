import Foundation

struct APIError: Error, LocalizedError {
    enum Kind {
        case http
        case network
        case decoding
        case invalidTicket
    }

    let kind: Kind
    let status: Int?
    let code: String
    let message: String
    let requestId: String?
    let retryable: Bool
    let fieldErrors: [FieldError]
    let underlying: String?

    var isUnauthorized: Bool {
        status == 401 || code == "UNAUTHENTICATED"
    }

    var isRevisionMismatch: Bool {
        status == 412 || code == "REVISION_MISMATCH"
    }

    var isStateConflict: Bool {
        status == 409 || code == "STATE_CONFLICT" || code == "IDEMPOTENCY_CONFLICT" || code == "CLAIM_CONSUMED"
    }

    var isValidation: Bool {
        status == 422 || code == "VALIDATION_ERROR" || code == "CLAIM_INVALID"
    }

    var errorDescription: String? { message }

    static func network(_ error: Error) -> APIError {
        APIError(kind: .network,
                 status: nil,
                 code: "NETWORK_ERROR",
                 message: error.localizedDescription,
                 requestId: nil,
                 retryable: true,
                 fieldErrors: [],
                 underlying: String(describing: error))
    }

    static func decoding(_ error: Error) -> APIError {
        APIError(kind: .decoding,
                 status: nil,
                 code: "DECODING_ERROR",
                 message: error.localizedDescription,
                 requestId: nil,
                 retryable: false,
                 fieldErrors: [],
                 underlying: String(describing: error))
    }

    static func unexpected(_ message: String) -> APIError {
        APIError(kind: .http, status: nil, code: "UNEXPECTED", message: message,
                 requestId: nil, retryable: true, fieldErrors: [], underlying: nil)
    }

    /// Human readable text for the current UI language.
    func displayMessage(language: String) -> String {
        if !message.isEmpty, kind == .http {
            return message
        }
        if kind == .network {
            return L10n.t("error.network", language)
        }
        if kind == .decoding {
            return L10n.t("error.decoding", language)
        }
        return message.isEmpty ? L10n.t("error.generic", language) : message
    }

    func fieldMessage(_ field: String) -> String? {
        fieldErrors.first { $0.field == field }?.message
    }
}
