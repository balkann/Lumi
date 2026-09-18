import Foundation
import LumiKit

/// DeepSeek bakiye servisi (karar 75) — `GET api.deepseek.com/user/balance`.
///
/// Anahtar tek kaynaktan gelir: `~/.claude/deepseek.env` (karar 54). Servis
/// anahtarı ne saklar ne loglar; her çağrıda env dosyasından okunur, böylece
/// Settings'te anahtar değişince gösterge bir sonraki yenilemede yeni anahtarla
/// konuşur.
///
/// Yeniden deneme YOK: `ClaudeUsageService`'teki retry, CLI yedeğine düşüp
/// abonelik kotasından yemeyi engellemek içindi; burada yedek yol yoktur,
/// başarısız istek görünür hata olur (karar 5) ve son bakiye korunur.
///
/// I/O ağırlıklı, UI-yüzlü değil → `actor`.
public actor DeepSeekBalanceService: DeepSeekBalanceServicing {
    public static let balanceURL = URL(string: "https://api.deepseek.com/user/balance")!
    static let timeout: TimeInterval = 10

    private let environment: any DeepSeekEnvironmentServicing
    private let session: URLSession

    public init(environment: any DeepSeekEnvironmentServicing, session: URLSession = .shared) {
        self.environment = environment
        self.session = session
    }

    public func fetch() async throws -> DeepSeekBalance {
        guard let apiKey = await environment.read().apiKey else {
            throw LumiError.deepSeekBalanceUnavailable(
                detail: "API key not set (Settings ▸ Agent ▸ DeepSeek)"
            )
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: Self.makeRequest(apiKey: apiKey))
        } catch {
            throw LumiError.deepSeekBalanceUnavailable(detail: error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw LumiError.deepSeekBalanceUnavailable(detail: "unexpected response")
        }
        guard http.statusCode == 200 else {
            throw LumiError.deepSeekBalanceUnavailable(detail: Self.detail(forStatus: http.statusCode))
        }
        guard let balance = DeepSeekBalanceParser.parse(data) else {
            throw LumiError.deepSeekBalanceUnavailable(detail: "unrecognized response format")
        }
        return balance
    }

    // MARK: - İstek

    private static func makeRequest(apiKey: String) -> URLRequest {
        var request = URLRequest(url: balanceURL)
        request.timeoutInterval = timeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    /// DeepSeek'in hata kodları (dokümandaki tablo). Ham kod da korunur:
    /// tanınmayan bir durumda kullanıcı en azından sayıyı görür.
    static func detail(forStatus code: Int) -> String {
        switch code {
        case 401: return "HTTP 401 — invalid API key"
        case 403: return "HTTP 403 — key not allowed to read balance"
        case 429: return "HTTP 429 — rate limited, try again shortly"
        case 500 ... 599: return "HTTP \(code) — DeepSeek server error"
        default: return "HTTP \(code)"
        }
    }
}
