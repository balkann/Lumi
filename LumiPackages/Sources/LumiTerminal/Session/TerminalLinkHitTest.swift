import CoreGraphics

/// View noktası → 0-tabanlı ekran hücresi (karar 57).
///
/// `MouseWheelGeometry` bounds'u satır/sütuna böler; ızgara host tarafından
/// hücre katına oturtulup ORTALANDIĞI için (`TerminalGridFit`) kenarlardaki
/// boşluk o hesabı kaydırabiliyordu. Link aramasında bir satırlık sapma
/// yanlış linke ya da "link yok"a dönüştüğünden burada SwiftTerm'in kendi
/// hücre boyutu (`cellSize`) kullanılır.
enum TerminalLinkHitTest {
    static func gridCell(
        forViewPoint point: CGPoint,
        cellSize: CGSize,
        bounds: CGRect,
        cols: Int,
        rows: Int,
        isFlipped: Bool
    ) -> (col: Int, row: Int) {
        let safeCols = max(1, cols)
        let safeRows = max(1, rows)
        guard cellSize.width > 0, cellSize.height > 0 else { return (0, 0) }
        let yFromTop = isFlipped ? point.y : (bounds.height - point.y)
        let col = min(safeCols - 1, max(0, Int(point.x / cellSize.width)))
        let row = min(safeRows - 1, max(0, Int(yFromTop / cellSize.height)))
        return (col, row)
    }
}
