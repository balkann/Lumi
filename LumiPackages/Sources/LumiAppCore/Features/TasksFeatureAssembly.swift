import Foundation
import LumiKit
import LumiState
import LumiUI
import SwiftUI

/// Sol panelin Tasks/Remote öğesi (karar 55).
///
/// Henüz store'u yoktur: panel içeriği yer tutucudur, bu yüzden `build`/`start`
/// boştur. Assembly yine de vardır ki içerik geldiğinde store'u ve bootstrap'i
/// kabuk dosyalarına dokunmadan buraya eklensin (karar 33).
@MainActor
final class TasksFeatureAssembly: FeatureAssembly, ShellContributing {
    let bootstrapPhase = BootstrapPhase.ui

    func build(services: any ServiceRegistry, shared: SharedStores) {}

    func registerShellItems(into registries: ShellRegistries) {
        registries.panels.register(PanelItemDescriptor(
            id: .tasks,
            title: "Tasks",
            icon: "checklist",
            defaultSlot: .left,
            sizing: .fit,
            makeView: { AnyView(TasksPanelItem()) }
        ))
        // Her bölüm orta alanın bir route'u + o route'un toolbar öğesidir.
        for section in TasksPanelSection.allCases {
            registries.routes.register(ContentRouteDescriptor(
                id: section.routeID,
                title: section.title,
                icon: section.icon,
                makeView: { _ in AnyView(TasksRouteView(section: section)) }
            ))
            registries.toolbar.register(ToolbarItemDescriptor(
                id: ToolbarItemID("route.\(section.rawValue)"),
                region: .center,
                order: ShellToolbarItems.Order.routeTitle,
                isVisible: { $0.navigation.activeRoute == .content(section.routeID) },
                makeView: { AnyView(TasksRouteToolbarItem(section: section)) }
            ))
        }
    }

    func start() async {}

    func shutdown() async {}
}
