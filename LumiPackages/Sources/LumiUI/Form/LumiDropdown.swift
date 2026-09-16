import SwiftUI

/// Tema uyumlu açılır seçim (karar 58).
///
/// Native `Picker(.menu)` sistem görünümüyle (mavi chevron kutusu, açık gri
/// zemin) koyu modalın içinde yabancı duruyordu. Bu kontrol tetikleyicisini
/// `LumiTextInput` ile aynı dille çizer, listeyi `PopoverMenu` satırlarıyla
/// açar. Liste tembel yüklenen kaynaklardan gelebilsin diye `onOpen` vardır.
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
    @Environment(\.isEnabled) private var isEnabled

    /// Uzun dal listeleri modalın dışına taşmasın.
    private static var maxListHeight: CGFloat { 260 }

    var body: some View {
        Button { isPresented = true } label: {
            HStack(spacing: Theme.Spacing.sm) {
                Text(selectedLabel)
                    .font(Theme.Typography.bodyMono)
                    .foregroundStyle(selectedOption == nil ? Theme.textMuted : Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
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
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.45)
        .onChange(of: isPresented) { _, presented in if presented { onOpen?() } }
        .popover(isPresented: $isPresented, arrowEdge: .bottom) { list }
    }

    private var selectedOption: Option? { options.first { $0.value == selection } }
    private var selectedLabel: String { selectedOption?.label ?? placeholder }

    private var list: some View {
        ScrollView {
            PopoverMenu(items: items, dismiss: { isPresented = false }, width: nil)
        }
        .frame(maxHeight: Self.maxListHeight)
        .background(Theme.bgElevated)
    }

    private var items: [PopoverMenu.Item] {
        guard !options.isEmpty else { return [.note(emptyNote ?? "No options")] }
        return options.map { option in
            .toggle(
                option.detail.map { "\(option.label)  ·  \($0)" } ?? option.label,
                isOn: option.value == selection,
                action: {
                    selection = option.value
                    isPresented = false
                }
            )
        }
    }
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
