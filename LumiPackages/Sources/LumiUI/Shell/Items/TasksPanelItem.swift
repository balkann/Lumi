import LumiKit
import LumiState
import SwiftUI

/// Sol panelin üst öğesi (karar 55 — eski `SessionsPanelItem`'ın yeri).
///
/// Sessions listesi kaldırıldı: canlı ajanlar zaten Projects panelinde
/// checkout başına listeleniyordu. Yerine Tasks ve Remote **satırları** geldi;
/// her biri orta alanın bir route'udur — tıklama terminal ızgarasının yerine o
/// route'un görünümünü getirir. Geri dönüş ayrı bir kontrol istemez: Projects
/// panelinden bir proje/workspace/ajan seçmek repo route'unu geri açar.
public struct TasksPanelItem: View {
    @Shell private var shell

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            ForEach(TasksPanelSection.allCases, id: \.self) { section in
                row(section)
            }
        }
        .padding(Theme.Spacing.lg)
        .frame(alignment: .top)
    }

    private func row(_ section: TasksPanelSection) -> some View {
        let isActive = shell.navigation.activeRoute == .content(section.routeID)
        return HoverReader { isHovering in
            Button { shell.navigation.setRoute(.content(section.routeID)) } label: {
                HStack(spacing: Theme.Spacing.md) {
                    Image(systemName: section.icon)
                        .font(Theme.Typography.ui(.body))
                        .accessibilityHidden(true)
                    Text(section.title)
                        .font(Theme.Typography.bodyMono)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(nameColor(isActive: isActive, isHovering: isHovering))
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.vertical, Theme.Spacing.md)
                .background(isActive || isHovering ? Theme.bgElevated : Color.clear)
                .overlay(alignment: .leading) {
                    if isActive {
                        Rectangle().fill(Theme.accentPrimary).frame(width: Theme.Spacing.xxs)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .accessibilityLabel(section.title)
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
    }

    private func nameColor(isActive: Bool, isHovering: Bool) -> Color {
        if isActive { return Theme.accentPrimary }
        return isHovering ? Theme.textPrimary : Theme.textSecondary
    }
}

#if DEBUG
#Preview("TasksPanelItem") {
    TasksPanelItem()
        .frame(width: 280)
        .background(Theme.bgSurface)
        .environment(\.shell, ShellContext.preview())
}
#endif
