import Foundation

/// Mac'in yayınladığı oturum durumu (docs/spec/50-remote-protocol.md snapshot payload).
public enum SessionStatus: String, Sendable, Equatable {
    case idle, working, error
    case waitingUnseen = "waiting-unseen"
    case waitingFocused = "waiting-focused"
    case waitingSeen = "waiting-seen"

    /// Telefon rozeti 4 duruma indirger (tasarım §2).
    public var badge: Badge {
        switch self {
        case .idle: .idle
        case .working: .working
        case .error: .error
        case .waitingUnseen, .waitingFocused, .waitingSeen: .waiting
        }
    }
}

extension SessionStatus: Decodable {
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        // Tolerans (tasarım §12.2): ileride eklenen durumlar akışı kırmasın.
        self = SessionStatus(rawValue: raw) ?? .idle
    }
}

public enum Badge: Sendable, Equatable { case idle, working, waiting, error }

public struct SessionSummary: Decodable, Sendable, Equatable, Identifiable {
    public let id: String
    public let repoPath: String
    public let repoName: String
    public var status: SessionStatus
    public let title: String?
    public let awaitingDecision: Bool
    public let model: String?
    /// O an ekranda duran interaktif prompt (ekran-scrape; spec 4). Reconnect'te kartı kurar.
    public let activePrompt: [Question]?
    /// Yapısal prompt yokken ham ekran özeti (bare kart bağlamı; spec 4 §K3).
    public let screenText: [String]?

    public init(id: String, repoPath: String, repoName: String,
                status: SessionStatus, title: String? = nil,
                awaitingDecision: Bool = false, model: String? = nil,
                activePrompt: [Question]? = nil, screenText: [String]? = nil) {
        self.id = id
        self.repoPath = repoPath
        self.repoName = repoName
        self.status = status
        self.title = title
        self.awaitingDecision = awaitingDecision
        self.model = model
        self.activePrompt = activePrompt
        self.screenText = screenText
    }

    private enum CodingKeys: String, CodingKey {
        case id, repoPath, repoName, status, title, awaitingDecision, model, activePrompt, screenText
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(String.self, forKey: .id),
            repoPath: try c.decode(String.self, forKey: .repoPath),
            repoName: try c.decode(String.self, forKey: .repoName),
            status: try c.decode(SessionStatus.self, forKey: .status),
            title: try c.decodeIfPresent(String.self, forKey: .title),
            awaitingDecision: try c.decodeIfPresent(Bool.self, forKey: .awaitingDecision) ?? false,
            model: try c.decodeIfPresent(String.self, forKey: .model),
            activePrompt: try c.decodeIfPresent([Question].self, forKey: .activePrompt),
            screenText: try c.decodeIfPresent([String].self, forKey: .screenText)
        )
    }
}

public struct Repo: Decodable, Sendable, Equatable, Identifiable {
    public let name: String
    public let path: String
    public var id: String { path }

    public init(name: String, path: String) {
        self.name = name
        self.path = path
    }
}

public struct Persona: Decodable, Sendable, Equatable, Identifiable {
    public let id: String
    public let label: String

    public init(id: String, label: String) {
        self.id = id
        self.label = label
    }
}

public struct Snapshot: Decodable, Sendable, Equatable {
    public let sessions: [SessionSummary]
    public let repos: [Repo]
    public let personas: [Persona]

    public init(sessions: [SessionSummary], repos: [Repo], personas: [Persona]) {
        self.sessions = sessions
        self.repos = repos
        self.personas = personas
    }
}

/// Terminal oturum meta verisi (terminal-mirror protokolü; relay sessions mesajı).
public struct SessionMeta: Decodable, Sendable, Equatable, Identifiable {
    public let id: String
    public let repoName: String
    public let status: String
    public let title: String?
    public let model: String?
    public let cols: Int
    public let rows: Int
    public let kind: String?   // oturum türü (örn. "chat", "terminal"); Faz 2 — yoksa nil

    public init(id: String, repoName: String, status: String,
                title: String? = nil, model: String? = nil,
                cols: Int, rows: Int, kind: String? = nil) {
        self.id = id
        self.repoName = repoName
        self.status = status
        self.title = title
        self.model = model
        self.cols = cols
        self.rows = rows
        self.kind = kind
    }

    private enum CodingKeys: String, CodingKey {
        case id, repoName, status, title, model, cols, rows, kind
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(String.self, forKey: .id),
            repoName: try c.decode(String.self, forKey: .repoName),
            status: try c.decode(String.self, forKey: .status),
            title: try c.decodeIfPresent(String.self, forKey: .title),
            model: try c.decodeIfPresent(String.self, forKey: .model),
            cols: try c.decode(Int.self, forKey: .cols),
            rows: try c.decode(Int.self, forKey: .rows),
            kind: try c.decodeIfPresent(String.self, forKey: .kind)
        )
    }

    /// Ham durum dizgesini telefon rozetine indirger (SessionStatus toleransıyla aynı).
    public var badge: Badge {
        (SessionStatus(rawValue: status) ?? .idle).badge
    }
}

/// Ham terminal bayt dilimi (data veya scrollback mesajından).
/// `bytes` base64-decoded ham PTY verisidir.
public struct TerminalChunk: Sendable, Equatable {
    public let sessionId: String
    public let seq: Int
    public let cols: Int?
    public let rows: Int?
    public let bytes: Data

    public init(sessionId: String, seq: Int, cols: Int? = nil, rows: Int? = nil, bytes: Data) {
        self.sessionId = sessionId
        self.seq = seq
        self.cols = cols
        self.rows = rows
        self.bytes = bytes
    }
}

/// Relay'in telefona ilk cevabı; `lastSeenAt` epoch milisaniye (relay `Date.now()`).
/// Terminal-ayna protokolünde oturum listesi `sessions` alanında gelir (eski `snapshot` kaldırıldı).
public struct Welcome: Decodable, Sendable, Equatable {
    public let macOnline: Bool
    public let lastSeenAt: Double?
    /// Terminal-mirror protokolü: aktif terminal oturumlarının listesi.
    public let sessions: [SessionMeta]?
    /// Telefondan yeni oturum başlatmak için repo listesi (relay room cache'inden).
    public let repos: [Repo]?

    public init(macOnline: Bool, lastSeenAt: Double?, sessions: [SessionMeta]? = nil, repos: [Repo]? = nil) {
        self.macOnline = macOnline
        self.lastSeenAt = lastSeenAt
        self.sessions = sessions
        self.repos = repos
    }

    private enum CodingKeys: String, CodingKey {
        case macOnline, lastSeenAt, sessions, repos
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.macOnline = try c.decode(Bool.self, forKey: .macOnline)
        self.lastSeenAt = try c.decodeIfPresent(Double.self, forKey: .lastSeenAt)
        self.sessions = try c.decodeIfPresent([SessionMeta].self, forKey: .sessions)
        self.repos = try c.decodeIfPresent([Repo].self, forKey: .repos)
    }
}

public struct Question: Decodable, Sendable, Equatable {
    public let header: String
    public let question: String
    public let options: [String]

    public init(header: String, question: String, options: [String]) {
        self.header = header
        self.question = question
        self.options = options
    }
}

public struct CommandResult: Decodable, Sendable, Equatable {
    public let commandId: String
    public let ok: Bool
    public let error: String?
    /// start_session kind=chat'ta Mac'in döndürdüğü yeni oturum kimliği (Faz 2).
    public let sessionId: String?

    public init(commandId: String, ok: Bool, error: String?, sessionId: String? = nil) {
        self.commandId = commandId
        self.ok = ok
        self.error = error
        self.sessionId = sessionId
    }
}
