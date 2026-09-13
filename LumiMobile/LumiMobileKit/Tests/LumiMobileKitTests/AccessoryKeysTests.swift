import Testing
import Foundation
@testable import LumiMobileKit

@Suite struct AccessoryKeysTests {
    @Test func mapsControlBytes() {
        #expect(bytes(for: .esc)   == Data([0x1B]))
        #expect(bytes(for: .enter) == Data([0x0D]))
        #expect(bytes(for: .tab)   == Data([0x09]))
        #expect(bytes(for: .ctrlC) == Data([0x03]))
        #expect(bytes(for: .up)    == Data([0x1B, 0x5B, 0x41]))     // ESC [ A
        #expect(bytes(for: .down)  == Data([0x1B, 0x5B, 0x42]))
        #expect(bytes(for: .right) == Data([0x1B, 0x5B, 0x43]))
        #expect(bytes(for: .left)  == Data([0x1B, 0x5B, 0x44]))
    }
}
