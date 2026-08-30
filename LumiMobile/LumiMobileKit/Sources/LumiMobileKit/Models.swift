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

/// Relay'in telefona ilk cevabı; `lastSeenAt` epoch milisaniye (relay `Date.now()`).
public struct Welcome: Decodable, Sendable, Equatable {
    public let snapshot: Snapshot?
    public let macOnline: Bool
    public let lastSeenAt: Double?

    public init(snapshot: Snapshot?, macOnline: Bool, lastSeenAt: Double?) {
        self.snapshot = snapshot
        self.macOnline = macOnline
        self.lastSeenAt = lastSeenAt
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

public enum SendStatus: Sendable, Equatable { case sending, sent, failed }

/// Transcript akış öğesi (protokol `event.item.itemType`).
public enum FeedItem: Sendable, Equatable {
    case assistantText(String)
    case toolUse(tool: String, summary: String)
    case question([Question])
    case turnDone
    /// Yalnız yerel: kullanıcının gönderdiği mesaj (protokol decode'u üretmez).
    case userMessage(text: String, status: SendStatus)
}

public enum RemoteEvent: Sendable, Equatable {
    case statusChange(sessionId: String, status: SessionStatus, repoName: String, summary: String?)
    case transcript(sessionId: String, item: FeedItem)
    case history(sessionId: String, items: [FeedItem])
    case awaitingDecision(sessionId: String, awaiting: Bool)
    case modelChange(sessionId: String, model: String)
    /// İzlenen transcript dosyası değişti (ör. /clear): oturumun feed'i + soru kartı sıfırlanır.
    case sessionReset(sessionId: String)
    /// Yapısal prompt yokken ham ekran özeti (bare kart bağlamı; [] = temizle). Spec 4 §K3.
    case screenText(sessionId: String, lines: [String])
}

public struct CommandResult: Decodable, Sendable, Equatable {
    public let commandId: String
    public let ok: Bool
    public let error: String?

    public init(commandId: String, ok: Bool, error: String?) {
        self.commandId = commandId
        self.ok = ok
        self.error = error
    }
}
