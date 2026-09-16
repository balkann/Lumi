import CoreGraphics

/// Kabuğun geometri sabitleri (Faz 6.4).
///
/// Top bar ölçüleri LumiApp ile PAYLAŞILIR (`TrafficLightLayout` titlebar
/// container'ı `TopBarMetrics.height`'a büyütür — karar 27/30), bu yüzden
/// header view'ının içinde değil, kabuğun ortak metrik dosyasında dururlar.
public enum TopBarMetrics {
    /// İnce bar (karar 30).
    public static let height: CGFloat = 36
    /// Traffic light ilk butonunun sol kenarı (Orca `TRAFFIC_LIGHT_X`).
    public static let trafficLightLeading: CGFloat = 16
    /// İçeriğin başladığı x: 3 buton (16 + 2×20 + 12 = 68) + nefes payı.
    public static let contentLeading: CGFloat = 80
    /// Bar içi kontrol yüksekliği (ikon buton, chip, usage, grid).
    public static let controlHeight: CGFloat = 26
    /// Bar'ın sağ kenar payı.
    public static let trailingPadding: CGFloat = 10
    /// Sol grup ile üretim bölgesi arasındaki en küçük boşluk.
    public static let regionGap: CGFloat = 8

    /// Karar 55: bar, panellerle hizalı üç parçadır — sol parça sol panel,
    /// sağ parça sağ panel genişliğinde, orta parça kalan alan. Bölge
    /// genişlikleri bar'ın KENDİ dolgularını düşer ki sınır tam panel kenarına
    /// otursun. Yuva gizliyse `nil` döner: hizalanacak bir panel yokken bölge
    /// doğal genişliğinde kalır ve orta alan boşa daralmaz.
    public static func leadingRegionWidth(leftPanelWidth: CGFloat?) -> CGFloat? {
        leftPanelWidth.map { max(0, $0 - contentLeading) }
    }

    public static func trailingRegionWidth(rightPanelWidth: CGFloat?) -> CGFloat? {
        rightPanelWidth.map { max(0, $0 - trailingPadding) }
    }
}

/// Panel yuvalarının genişlik default'u burada **tekrarlanmaz**: tek kaynak
/// LumiKit'teki `PanelLayout.defaultWidth`'tir (280) ve çizim tarafı ona
/// `LayoutStore.width(for:)` → `PanelLayout.width(for:)` zinciriyle ulaşır
/// (`PanelHostView`). UI'da ikinci bir 280 literali yoktur; olsaydı persist
/// edilen yerleşimle sessizce ayrışabilirdi.
