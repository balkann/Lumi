import Foundation

/// Canlı streaming metnini göster/gizle kuralı (orca native-chat-streaming paritesi;
/// spec Faz 2 §E). working değilse veya streaming boşsa nil; streaming son assistant
/// metnini geçmiyorsa (içeriyorsa/kısaysa) nil — transcript yerleşince overlay düşer.
public func chatStreamingText(working: Bool, streaming: String?, lastAssistantText: String) -> String? {
    guard working, let text = streaming?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
    if lastAssistantText.contains(text) || text.count <= lastAssistantText.count { return nil }
    return text
}
