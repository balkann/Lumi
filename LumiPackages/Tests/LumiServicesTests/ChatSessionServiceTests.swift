import Testing
import Foundation
import LumiKit
import LumiTestSupport
@testable import LumiServices

@Suite struct ChatSessionServiceTests {
    @Test func createStartsSessionAndListsIt() async {
        let fake = FakeStreamingProcess(scriptedLines: [])
        let svc = ChatSessionService(spawner: fake, binaryLocator: FixedBinaryLocator2(path: "/usr/bin/claude"),
                                     environment: [:])
        let meta = await svc.create(repoPath: "/repo")
        let list = await svc.list()
        #expect(list.contains(where: { $0.id == meta.id }))
        #expect(list.count == 1)
    }
    @Test func sendRoutesToSession() async {
        let fake = FakeStreamingProcess(scriptedLines: [])
        let svc = ChatSessionService(spawner: fake, binaryLocator: FixedBinaryLocator2(path: "/usr/bin/claude"),
                                     environment: [:])
        let meta = await svc.create(repoPath: "/repo")
        await svc.send(id: meta.id, text: "merhaba")
        // create bir handle spawn etti; send ona yazdı.
        let written = fake.handles.first?.written.joined() ?? ""
        #expect(written.contains("merhaba"))
    }
}
struct FixedBinaryLocator2: BinaryLocating {
    let path: String?
    func locate(_ name: String, timeout: TimeInterval) async -> String? { path }
}
