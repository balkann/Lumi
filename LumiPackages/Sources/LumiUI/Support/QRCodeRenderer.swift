import AppKit
import CoreImage.CIFilterBuiltins

/// Eşleştirme QR'ı üretir (CIQRCodeGenerator).
enum QRCodeRenderer {
    static func image(for string: String, scale: CGFloat = 6) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
