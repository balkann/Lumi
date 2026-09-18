# Faz 3 — macOS Lumi'de chat view (ERTELENDİ, not)

Tarih: 2026-09-18 · Durum: **YAPILMADI, ileride.** Kullanıcı "şimdilik not olarak bırak" dedi.
Amaç: macOS Lumi masaüstünden stream-json chat oturumlarını **takip + kullan**. Mac'te şu an
hiç chat arayüzü yok (LumiUI/LumiState'te chat referansı sıfır). Chat telefonda çalışıyor.

## Kilit avantaj
Mac chat için **relay GEREKMEZ** — Mac `ChatSessionService`'e doğrudan erişiyor. Journal'ı
(`ChatJournalState`: `messages: [ChatMessage]`, `streamingText: String?`, `turnActive: Bool`)
doğrudan render edeceğiz. Telefondaki tüm wire/köprü/gate karmaşası burada yok.

## Nasıl eklenir (generic shell — karar 33; RootView/kabuk içine DOKUNMADAN)
1. **`ChatFeatureAssembly`** (LumiAppCore/Features) — `FeatureAssembly + ShellContributing`.
   `RepoFeatureAssembly.swift`'i birebir mirror'la (`bootstrapPhase`, `build(services:shared:)`,
   `registerShellItems(into:)`, `start/shutdown`).
2. `build()`: `store = ChatSessionStore(service: services.chatSessions)`.
3. `registerShellItems`: ya **ContentRoute** (`ContentRouteDescriptor(id:ContentRouteID("chat"),
   title:"Chat", icon:"message", makeView:{ _ in AnyView(ChatMainView()) })`) YA da sağ panelde
   4. sekme (`ProjectToolsTab` + `ProjectToolsPanel` switch'ine ekleme).
4. **`AppComposition.swift`** (~satır 43–63): assembly listesine + `contributors` listesine
   `let chat = ChatFeatureAssembly()` tek satır (İKİ yere: `assemblies:[...]` ve `contributors:[...]`).
5. `ChatSessionStore`'u **`ShellContext`**'e ekle (LumiUI/Shell/ShellContext.swift init + prop),
   view `@Shell private var shell` ile `shell.chat` erişsin. (ShellContext'i kuran
   RootViewFactory/ShellComposition'a da store geçirilir.)

## ChatSessionStore (@Observable, LumiState) — taslak
```swift
@Observable @MainActor public final class ChatSessionStore {
    public private(set) var sessions: [ChatSessionMeta] = []
    public private(set) var states: [String: ChatJournalState] = [:]
    public private(set) var activeSessionID: String?
    @ObservationIgnored private let service: any ChatSessionServicing
    @ObservationIgnored private var consumers: [String: Task<Void,Never>] = [:]
    public init(service: any ChatSessionServicing) { self.service = service }
    public func refresh() async { sessions = await service.list() }
    public func open(_ id: String) async {
        activeSessionID = id
        guard consumers[id] == nil, let stream = await service.snapshots(id: id) else { return }
        consumers[id] = Task { [weak self] in for await s in stream { self?.states[id] = s } }
    }
    public func send(_ text: String) async { if let id = activeSessionID { await service.send(id:id, text:text) } }
    public func createSession(repoPath: String) async { let m = await service.create(repoPath:repoPath); await refresh(); activeSessionID = m.id }
}
```

## Render notları (vanish'e düşmemek için)
- `streamingText`'i turn sürerken (`turnActive`) canlı balon göster. Journal, gerçek mesaj
  commit olunca (`assistantSnapshot`) `streamingText`'i null'a çeker → balon gizlenir, mesaj
  kalır. **Burada relay yok, tek kaynak journal → içerik-güncelleme kaybı OLMAZ** (telefondaki
  Mac-side diff hatası burada yok). Basit tut.
- **Kendi gönderdiğin mesaj:** stream-json kullanıcı mesajını yankılamıyor → store'da optimistic
  user mesajı ekle (telefondaki [[orca-source-and-chat-render]] pending mantığının basit hali;
  local olduğu için dedup çoğu zaman gereksiz).
- Mesajları `foldChatMessages` benzeri katla (tool satırları). LumiMobileKit'teki fold iOS-only;
  Mac için LumiKit/LumiUI'da küçük bir eşdeğer yaz (veya ChatFold'u paylaşılan modüle taşı).
- Sezgisel soru kartı (Faz 2b) Mac'te opsiyonel — Mac'te klavye var, yazmak kolay; şimdilik atlanabilir.

## Açık kararlar (kullanıcıya sorulacak, henüz seçilmedi)
- **Yerleşim:** ana içerik route'u "Chat" (toolbar Terminals↔Chat; iki panel: liste | konuşma —
  ÖNERİLEN, konuşma için tam genişlik) VS sağ panelde 4. sekme (dar ~340px).
- **Kapsam:** takip+yaz+yeni chat+sil (telefon paritesi, ÖNERİLEN) VS sadece takip (read-only).

## Zorunlu kurallar
- LumiUI literal yasağı: `Theme.Typography/Radius/Spacing/Motion/Colors` token'ları (bkz.
  `Theme+Typography.swift`, `Theme+Metrics.swift`, `Theme.swift`). Her `#Preview` `#if DEBUG`.
- Yeni servis yok (chatSessions zaten var). Sadece store+view+assembly.
- Mac rebuild+relaunch gerekir → [[ask-before-mac-update]] onayı.

## Anahtar dosyalar
- FeatureAssembly: `LumiState/Composition/FeatureAssembly.swift`
- ShellContributing/AppComposition: `LumiAppCore/Composition/{ShellComposition,AppComposition}.swift`
- Descriptor/registry: `LumiUI/Shell/{PanelItemRegistry,ContentRouteRegistry,ShellRegistries,ShellContext,RootView}.swift`
- Örnek assembly: `LumiAppCore/Features/RepoFeatureAssembly.swift`
- Panel sekmeleri: `LumiState/ProjectToolsTab.swift`, `LumiUI/Sidebar/ProjectToolsPanel.swift`, `AgentHistoryView.swift`
- Servis: `LumiKit/Protocols/ChatSessionServicing.swift`, `LiveServiceRegistry.swift` (chatSessions kurulur)
- Store örneği: `LumiState/{RemoteStore,AgentHistoryStore}.swift`
- Journal/mesaj: `LumiKit/NativeChat/ChatJournal.swift`, `LumiWire/ChatMirrorModels.swift`
