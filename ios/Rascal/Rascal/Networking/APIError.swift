import Foundation

/// The one error shape the server renders, from `docs/api-contract.md`:
/// `{"error": {"code": ..., "message": ..., "field": ...}}`
nonisolated struct APIErrorEnvelope: Decodable {
    let error: APIErrorDetail
}

nonisolated struct APIErrorDetail: Decodable {
    let code: APIErrorCode
    let message: String
    let field: String?
}

/// A case per documented code, so call sites can switch exhaustively.
///
/// `unknown` exists because the server may add a code before this client knows about it, and
/// an unrecognised value must degrade rather than crash. It is the same reasoning that keeps
/// constrained columns as `text` + CHECK instead of a Postgres enum.
nonisolated enum APIErrorCode: RawRepresentable, Decodable, Equatable, Sendable {
    case unauthenticated
    case tokenExpired
    case refreshTokenReused
    case notAuthorized
    case notFound
    case validationFailed
    case assignmentExpired
    case uploadIncomplete
    case conflict
    case internalError
    case unknown(String)

    init(rawValue: String) {
        switch rawValue {
        case "unauthenticated": self = .unauthenticated
        case "token_expired": self = .tokenExpired
        case "refresh_token_reused": self = .refreshTokenReused
        case "not_authorized": self = .notAuthorized
        case "not_found": self = .notFound
        case "validation_failed": self = .validationFailed
        case "assignment_expired": self = .assignmentExpired
        case "upload_incomplete": self = .uploadIncomplete
        case "conflict": self = .conflict
        case "internal_error": self = .internalError
        default: self = .unknown(rawValue)
        }
    }

    var rawValue: String {
        switch self {
        case .unauthenticated: "unauthenticated"
        case .tokenExpired: "token_expired"
        case .refreshTokenReused: "refresh_token_reused"
        case .notAuthorized: "not_authorized"
        case .notFound: "not_found"
        case .validationFailed: "validation_failed"
        case .assignmentExpired: "assignment_expired"
        case .uploadIncomplete: "upload_incomplete"
        case .conflict: "conflict"
        case .internalError: "internal_error"
        case .unknown(let raw): raw
        }
    }

    init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }
}

/// Everything a call site can be handed. Callers switch on `code`, never on message text —
/// messages are copy and will change.
enum APIError: Error, Equatable {
    /// The server answered with its error envelope.
    case api(code: APIErrorCode, message: String, field: String?, status: Int)
    /// A non-2xx with a body that wasn't the documented envelope.
    case unexpectedStatus(Int)
    /// URLSession failed — offline, DNS, TLS, or ATS.
    case transport(String)
    /// 2xx whose body didn't match the expected model. A contract drift, not a user error.
    case decoding(String)
    /// Refresh could not recover the session. The caller signs out.
    case sessionExpired

    var code: APIErrorCode? {
        if case .api(let code, _, _, _) = self { return code }
        return nil
    }

    /// Retrying the identical request could plausibly succeed.
    var isRetryable: Bool {
        switch self {
        case .transport: true
        case .api(let code, _, _, _): code == .internalError
        default: false
        }
    }

    /// What the parent reads. Says what happened and what to do; never apologises, never vague,
    /// never alarming — `docs/design-system.md`, copy rules.
    var userMessage: String {
        switch self {
        case .api(let code, let message, _, _):
            switch code {
            case .assignmentExpired:
                "This one expired, so it won't complete today's mission. Your entry is saved."
            case .notAuthorized:
                "This archive isn't shared with you."
            case .notFound:
                "That's no longer here."
            case .validationFailed:
                message
            case .internalError:
                "The server had trouble. Your work is saved on this phone."
            default:
                message
            }
        case .transport:
            "No connection. Saved here, and it'll sync when you're back."
        case .decoding:
            "The server sent something this version doesn't understand."
        case .unexpectedStatus:
            "The server had trouble. Your work is saved on this phone."
        case .sessionExpired:
            "Signed out. Sign in again to keep going."
        }
    }
}
