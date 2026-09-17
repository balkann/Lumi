import LumiKit
import LumiState
import SwiftUI

/// Tasks / Remote route'larının orta alan görünümü (karar 55).
///
/// İçerik henüz yok: görünüm route'un kimliğini taşır ve yer tutucu çizer.
/// İçerik geldiğinde yalnız bu gövde değişir — kabuk, panel satırı ve toolbar
/// öğesi olduğu gibi kalır.
public struct TasksRouteView: View {
    let section: TasksPanelSection

    public init(section: TasksPanelSection) {
        self.section = section
    }

    public var body: some View {
        EmptyStatePlaceholder("\(section.title) is coming soon", density: .full)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.bgDeep)
    }
}

/// Route'un kendi toolbar öğesi: orta bölgede route adı (karar 55). Grid ayarı
/// ve `New <Provider>` repo route'una bağlı olduğu için bu route'ta zaten
/// bar'dan düşer.
public struct TasksRouteToolbarItem: View {
    let section: TasksPanelSection

    public init(section: TasksPanelSection) {
        self.section = section
    }

    public var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: section.icon)
                .font(Theme.Typography.ui(.label))
                .accessibilityHidden(true)
            Text(section.title)
                .font(Theme.Typography.mono(.body, weight: .semibold))
        }
        .foregroundStyle(Theme.textSecondary)
        .frame(height: TopBarMetrics.controlHeight)
    }
}

#if DEBUG
#Preview("TasksRouteView") {
    TasksRouteView(section: .tasks)
        .frame(width: 640, height: 360)
}
#endif
