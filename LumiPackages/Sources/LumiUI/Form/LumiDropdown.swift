import SwiftUI

/// Tema uyumlu açılır seçim (karar 58).
///
/// Native `Picker(.menu)` sistem görünümüyle (mavi chevron kutusu, açık gri
/// zemin) koyu modalın içinde yabancı duruyordu. Bu kontrol tetikleyicisini
/// `LumiTextInput` ile aynı dille çizer, listeyi `PopoverMenu` satırlarıyla
/// `DropdownPanel` içinde açar (ok ucu yok, genişlik en az alan kadar).
/// Liste tembel yüklenen kaynaklardan gelebilsin diye `onOpen` vardır; uzun
/// listelerde tetikleyici açıkken arama alanına dönüşür.
struct LumiDropdown<Value: Hashable>: View {
    struct Option: Identifiable {
        let value: Value
        let label: String
        /// Satırın altında gösterilen açıklama (ör. "current branch").
        var detail: String?
        var id: String { label }
    }

    let options: [Option]
    @Binding var selection: Value
    var placeholder = "Select"
    /// Liste açıldığında bir kez çağrılır (tembel yükleme).
    var onOpen: (() -> Void)?
    /// Liste boşken gösterilen satır: yükleniyor / hata / sonuç yok.
    var emptyNote: String?

    @State private var isPresented = false
    @State private var query = ""
    @State private var triggerWidth: CGFloat = 0
    @FocusState private var isSearchFocused: Bool
    @Environment(\.isEnabled) private var isEnabled

    /// Uzun dal listeleri ekranı kaplamasın.
    private static var maxListHeight: CGFloat { 260 }
    /// Bu sayıdan uzun listelerde tetikleyici arama alanına dönüşür.
    private static var searchThreshold: Int { 8 }
    /// Aynı anda çizilen satır tavanı; gerisi arama ile daraltılır.
    private static var maxVisibleOptions: Int { 200 }

    var body: some View {
        trigger
            .background(
                GeometryReader { geometry in
                    Color.clear.preference(key: DropdownTriggerWidth.self, value: geometry.size.width)
                }
            )
            .onPreferenceChange(DropdownTriggerWidth.self) { width in
                Task { @MainActor in triggerWidth = width }
            }
            .background(DropdownPanel(isPresented: $isPresented) { list })
            .opacity(isEnabled ? 1 : 0.45)
            .onChange(of: isPresented) { _, presented in
                query = ""
                isSearchFocused = presented && isSearchable
                if presented { onOpen?() }
            }
    }

    private var isSearchable: Bool { options.count >= Self.searchThreshold }

    @ViewBuilder
    private var trigger: some View {
        if isPresented && isSearchable {
            chrome {
                TextField(selectedLabel, text: $query)
                    .textFieldStyle(.plain)
                    .font(Theme.Typography.bodyMono)
                    .foregroundStyle(Theme.textPrimary)
                    .focused($isSearchFocused)
                    .onSubmit { if let first = matches.first { select(first) } }
            } icon: {
                Image(systemName: "magnifyingglass")
            }
        } else {
            Button { isPresented = true } label: {
                chrome {
                    Text(selectedLabel)
                        .font(Theme.Typography.bodyMono)
                        .foregroundStyle(selectedOption == nil ? Theme.textMuted : Theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } icon: {
                    Image(systemName: "chevron.up.chevron.down")
                }
            }
            .buttonStyle(.plain)
        }
    }

    /// Tetikleyicinin ortak kabuğu (metin ve arama hâli aynı görünür).
    private func chrome<Body: View, Icon: View>(
        @ViewBuilder content: () -> Body,
        @ViewBuilder icon: () -> Icon
    ) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
            content()
            Spacer(minLength: 0)
            icon()
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.textMuted)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.bgDeep)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .stroke(isPresented ? Theme.accentVivid : Theme.border, lineWidth: Theme.Stroke.hairline)
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
        .contentShape(Rectangle())
    }

    private var selectedOption: Option? { options.first { $0.value == selection } }
    private var selectedLabel: String { selectedOption?.label ?? placeholder }

    private var matches: [Option] {
        guard !query.isEmpty else { return options }
        return options.filter { $0.label.localizedCaseInsensitiveContains(query) }
    }

    private var list: some View {
        ScrollView {
            PopoverMenu(items: items, dismiss: { isPresented = false }, width: nil)
        }
        .frame(maxHeight: Self.maxListHeight)
        .frame(minWidth: max(triggerWidth, PopoverMenu.width), alignment: .leading)
        .background(Theme.bgElevated)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .stroke(Theme.border, lineWidth: Theme.Stroke.hairline)
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
    }

    private var items: [PopoverMenu.Item] {
        let matches = matches
        let shown = matches.prefix(Self.maxVisibleOptions)
        guard !shown.isEmpty else {
            return [.note(query.isEmpty ? (emptyNote ?? "No options") : "No branches match \"\(query)\"")]
        }
        var rows: [PopoverMenu.Item] = shown.map { option in
            .toggle(
                option.detail.map { "\(option.label)  ·  \($0)" } ?? option.label,
                isOn: option.value == selection,
                action: { select(option) }
            )
        }
        if matches.count > shown.count {
            rows.append(.note("\(matches.count - shown.count) more — keep typing to narrow the list"))
        }
        return rows
    }

    private func select(_ option: Option) {
        selection = option.value
        isPresented = false
    }
}

private struct DropdownTriggerWidth: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

#if DEBUG
#Preview("LumiDropdown") {
    LumiDropdown(
        options: [
            .init(value: "main", label: "/main", detail: "current"),
            .init(value: "feature", label: "/main/feature"),
        ],
        selection: .constant("main")
    )
    .padding(Theme.Spacing.xxl)
    .frame(width: 360)
    .background(Theme.bgSurface)
}
#endif
