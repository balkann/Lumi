import SwiftUI
import LumiMobileKit

/// Aksesuar tuş çubuğu: ok tuşları, kontrol tuşları ve serbest metin girişi.
/// Her buton veya metin gönderimi `sendInput` closure'ı üzerinden PTY'ye iletilir.
struct AccessoryBar: View {
    /// Gönderilecek ham baytları alan closure; caller PTY'ye yönlendirir.
    let sendInput: (Data) -> Void

    @State private var text: String = ""
    @FocusState private var textFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            VStack(spacing: 6) {
                // Birinci satır: ok tuşları + kontrol tuşları
                HStack(spacing: 6) {
                    accessoryButton("↑", key: .up)
                    accessoryButton("↓", key: .down)
                    accessoryButton("←", key: .left)
                    accessoryButton("→", key: .right)
                    Spacer()
                    accessoryButton("Esc",   key: .esc)
                    accessoryButton("Tab",   key: .tab)
                    accessoryButton("↵",     key: .enter)
                    accessoryButton("^C",    key: .ctrlC)
                }

                // İkinci satır: serbest metin girişi + gönder
                HStack(spacing: 8) {
                    TextField("Gönder…", text: $text)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled(true)
                        .textInputAutocapitalization(.never)
                        .submitLabel(.send)
                        .focused($textFieldFocused)
                        .onSubmit { commitText() }

                    Button(action: commitText) {
                        Image(systemName: "arrow.up.circle.fill")
                            .imageScale(.large)
                    }
                    .disabled(text.isEmpty)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(uiColor: .systemBackground))
        }
    }

    // MARK: - Yardımcılar

    @ViewBuilder
    private func accessoryButton(_ label: String, key: AccessoryKey) -> some View {
        Button(label) {
            sendInput(bytes(for: key))
        }
        .font(.system(.footnote, design: .monospaced).bold())
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 6))
        .foregroundStyle(.primary)
    }

    private func commitText() {
        guard !text.isEmpty else { return }
        // "Gönder" = metni yaz + Enter (CR) → satırı submit et (orca buffered-send
        // davranışı). Enter olmadan metin terminalde görünür ama gönderilmez.
        sendInput(Data(text.utf8) + Data([0x0D]))
        text = ""
    }
}

#if DEBUG
#Preview {
    AccessoryBar { _ in }
}
#endif
