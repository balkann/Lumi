import Foundation

/// Definitions for the custom keys in the accessory bar.
public enum AccessoryKey: Sendable {
    case up, down, left, right
    case esc, tab, enter, ctrlC
}

/// Returns the raw bytes to send to the terminal for a given `AccessoryKey`.
/// ANSI/VT100 escape sequences: arrow keys ESC [ X, control keys single byte.
public func bytes(for key: AccessoryKey) -> Data {
    switch key {
    case .esc:   return Data([0x1B])
    case .enter: return Data([0x0D])
    case .tab:   return Data([0x09])
    case .ctrlC: return Data([0x03])
    case .up:    return Data([0x1B, 0x5B, 0x41])   // ESC [ A
    case .down:  return Data([0x1B, 0x5B, 0x42])   // ESC [ B
    case .right: return Data([0x1B, 0x5B, 0x43])   // ESC [ C
    case .left:  return Data([0x1B, 0x5B, 0x44])   // ESC [ D
    }
}
