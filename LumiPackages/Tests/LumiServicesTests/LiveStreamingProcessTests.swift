import Testing
import Foundation
@testable import LumiServices
import LumiKit

@Suite struct LiveStreamingProcessTests {
    @Test func catEchoesWrittenLines() async throws {
        let spawner = LiveStreamingProcess()
        let handle = spawner.spawn(executable: "/bin/cat", arguments: [],
                                   currentDirectory: nil, environment: [:])
        handle.write("merhaba\n")
        handle.write("dünya\n")
        var got: [String] = []
        for await line in handle.lines {
            got.append(line)
            if got.count == 2 { break }
        }
        handle.terminate()
        #expect(got == ["merhaba", "dünya"])
    }
}
