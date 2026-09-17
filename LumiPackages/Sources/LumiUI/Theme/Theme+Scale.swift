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

    /// Bir cihaz pikselinin punto karşılığı (`1 / backingScaleFactor`); Retina'da
    /// 0.5. `AppDelegate` ölçek uygularken yürürlükteki ekrandan tazeler.
    ///
    /// Varsayılan 2x'tir: Apple yıllardır 1x ekran satmıyor ve yanlış tahminin
    /// bedeli yalnız yuvarlama ızgarasının bir kademe ince olması.
    nonisolated(unsafe) static var devicePixel: CGFloat = 0.5

    /// Token değerini yürürlükteki ölçeğe çevirir ve **cihaz pikseline oturtur**.
    ///
    /// Yuvarlama olmadan piksele oturmayan bir ölçek (0.8'de `Spacing.md` 8 →
    /// 6.4pt, `Stroke.hairline` 1 → 0.8pt) tüm layout'u yarım piksele kaydırır:
    /// metin taban çizgileri keyfi alt-piksel fazlarına düşer, her glyph farklı
    /// gri dağılımıyla raster'lanır ve yazı "parıldıyor" gibi görünür. Chromium'un
    /// page zoom'unda bu olmaz çünkü o da layout'u cihaz pikseline snap'ler —
    /// yani yuvarlama, karar 57'nin taklit ettiği davranışın eksik kalan yarısıdır.
    ///
    /// Sıfır (`Radius.none`) sıfır kalır; sıfırdan farklı bir değer ise asla
    /// sıfıra çökmez (bir çizgi tamamen kaybolurdu).
    static func scaled(_ value: CGFloat) -> CGFloat {
        snapped(value * uiScale, to: devicePixel)
    }

    /// Punto için ölçek — cihaz pikseline değil **tam sayıya** oturur.
    ///
    /// Punto kesirli kalırsa ondan türeyen ascent/descent/satır yüksekliği de
    /// kesirli olur ve taban çizgisi yine ızgaradan kaçar; `scaled` ile
    /// hizalanmış bir kap bunu kurtaramaz. Tam sayı punto, kullanıcının
    /// "Electron'la aynı" dediği %100 durumunun sağladığı koşulun ta kendisidir.
    static func scaledFontSize(_ value: CGFloat) -> CGFloat {
        snapped(value * uiScale, to: 1)
    }

    private static func snapped(_ value: CGFloat, to grid: CGFloat) -> CGFloat {
        guard value != 0, grid > 0 else { return value }
        let result = (value / grid).rounded() * grid
        guard result == 0 else { return result }
        return value < 0 ? -grid : grid
    }
}
