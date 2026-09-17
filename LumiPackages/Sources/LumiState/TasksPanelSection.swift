import LumiKit

/// Sol paneldeki Tasks ve Remote girişleri (karar 55).
///
/// Her biri orta alanın bir route'udur: satıra tıklamak `activeRoute`'u o
/// route'a çevirir (terminal ızgarasının yerini alır). Küme burada, view'dan
/// bağımsız yaşar ki içerik geldiğinde yalnız o route'un görünümü değişsin.
public enum TasksPanelSection: String, CaseIterable, Sendable {
    case tasks
    case remote

    public var title: String {
        switch self {
        case .tasks: "Tasks"
        case .remote: "Remote"
        }
    }

    /// Orta alandaki karşılığı — `ContentRouteID` ham değeri `rawValue`'dur.
    public var routeID: ContentRouteID { ContentRouteID(rawValue) }

    public var icon: String {
        switch self {
        case .tasks: "checklist"
        case .remote: "antenna.radiowaves.left.and.right"
        }
    }
}
