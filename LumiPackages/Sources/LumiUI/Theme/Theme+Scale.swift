import CoreGraphics

/// Arayüz ölçeği (karar 57) — Electron sürümünün `zoomIn`/`zoomOut`/`resetZoom`
/// paritesi.
///
/// **Neden token çarpanı, çizim ölçeği DEĞİL:** Chromium'un page zoom'u CSS
/// pixel'ini büyütür ve layout'u YENİDEN AKITIR — %80'de pencereye daha çok
/// içerik sığar, %125'te daha az. Pencere içeriğini bir bütün olarak ölçekleyen
/// bir kap (transform ya da `frame`/`bounds` ayrışması) bunu yapamaz: layout
/// eski boyutta hesaplanır, sonuç sığmaz ya da kenarda boşluk bırakır.
///
/// Burada ölçek, punto ve boşluk **token'larının kendisine** uygulanır. LumiUI'da
/// literal punto/yarıçap yasak olduğu için (`DesignTokenLintTests`) her ölçü bu
/// token'lardan geçer; çarpan tek noktadan tüm arayüze iner ve SwiftUI layout'u
/// gerçekten baştan hesaplar.
///
/// `nonisolated(unsafe)`: yalnız `LayoutStore` köprüsünden (MainActor) yazılır,
/// okuyanlar view body'leridir. İzole edilseydi token'lar MainActor'a bağlanır
/// ve nonisolated bağlamlardaki (`Style` varsayılan parametreleri) her çağrı
/// yeri kırılırdı.
public extension Theme {
    nonisolated(unsafe) static var uiScale: CGFloat = 1

    /// Token değerini yürürlükteki ölçeğe çevirir. Sıfır (`Radius.none`,
    /// `Spacing` yok) ölçekten etkilenmez — çarpım zaten sıfırdır.
    static func scaled(_ value: CGFloat) -> CGFloat { value * uiScale }
}
