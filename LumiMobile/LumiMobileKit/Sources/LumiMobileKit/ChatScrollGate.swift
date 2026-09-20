import CoreGraphics

/// Decides whether the chat list is scrolled to (or near) the bottom.
///
/// `sentinelMinY` is the bottom sentinel's `minY` in the ScrollView's named
/// coordinate space: ~`viewportHeight` when pinned to the bottom, larger when
/// the user has scrolled up. At-bottom means the sentinel is within `threshold`
/// points of the viewport's bottom edge (or above it, when content fits).
/// Threshold defaults to 80 (orca `distanceFromBottom < 80` parity).
public func chatAtBottom(sentinelMinY: CGFloat, viewportHeight: CGFloat, threshold: CGFloat = 80) -> Bool {
    sentinelMinY <= viewportHeight + threshold
}
