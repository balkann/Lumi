import SwiftUI
import UIKit
import LumiMobileKit

struct SessionListView: View {
    let model: AppModel
    @State private var showNewSession = false
    @State private var pendingDelete: SessionMeta?

    var body: some View {
        NavigationStack {
            List {
                if !model.macOnline {
                    offlineBanner
                }
                ForEach(model.orderedSessions) { session in
                    NavigationLink(value: session.id) {
                        SessionRow(session: session)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            pendingDelete = session
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
                if model.orderedSessions.isEmpty {
                    Text("No active sessions")
                        .foregroundStyle(.secondary)
                }
            }
            .confirmationDialog(
                "End session?",
                isPresented: Binding(
                    get: { pendingDelete != nil },
                    set: { if !$0 { pendingDelete = nil } }
                ),
                presenting: pendingDelete
            ) { session in
                Button("End", role: .destructive) {
                    Task { await model.deleteSession(sessionId: session.id) }
                    pendingDelete = nil
                }
                Button("Cancel", role: .cancel) { pendingDelete = nil }
            } message: { session in
                Text("The \(session.repoName) session will be ended on the Mac.")
            }
            .navigationTitle("Lumi")
            .navigationDestination(for: String.self) { sessionId in
                TerminalSessionView(model: model, sessionId: sessionId)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    connectionDot
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showNewSession = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .disabled(!model.macOnline)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Toggle("Notifications", isOn: Binding(
                            get: { model.notificationsEnabled },
                            set: { isOn in
                                Task {
                                    if isOn {
                                        if await model.enableNotifications() == .needsSettings,
                                           let url = URL(string: UIApplication.openSettingsURLString) {
                                            await UIApplication.shared.open(url)
                                        }
                                    } else {
                                        await model.disableNotifications()
                                    }
                                }
                            }
                        ))
                        Button("Unpair", role: .destructive) {
                            Task { await model.unpair() }
                        }
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showNewSession) {
                NewSessionView(model: model)
            }
        }
    }

    private var offlineBanner: some View {
        Label {
            Text("Mac offline" + lastSeenSuffix)
        } icon: {
            Image(systemName: "desktopcomputer.trianglebadge.exclamationmark")
        }
        .font(.callout)
        .foregroundStyle(.orange)
    }

    private var lastSeenSuffix: String {
        guard let lastSeenAt = model.lastSeenAt else { return "" }
        return " — last seen " + lastSeenAt.formatted(date: .omitted, time: .shortened)
    }

    private var connectionDot: some View {
        Circle()
            .fill(model.connection == .connected ? .green :
                  model.connection == .connecting ? .yellow : .red)
            .frame(width: 10, height: 10)
            .accessibilityLabel("Relay connection")
    }
}

struct SessionRow: View {
    let session: SessionMeta

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.repoName).font(.headline)
                if let title = session.title, !title.isEmpty {
                    Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            StatusBadge(badge: session.badge)
        }
    }
}

struct StatusBadge: View {
    let badge: Badge

    var body: some View {
        Text(label)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    private var label: String {
        switch badge {
        case .idle: "idle"
        case .working: "running"
        case .waiting: "waiting"
        case .error: "error"
        }
    }

    private var color: Color {
        switch badge {
        case .idle: .gray
        case .working: .blue
        case .waiting: .orange
        case .error: .red
        }
    }
}
