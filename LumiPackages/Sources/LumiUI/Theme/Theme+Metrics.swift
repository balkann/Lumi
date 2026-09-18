import CoreGraphics

/// Köşe yarıçapı ve boşluk ölçekleri (Faz 7.1).
///
/// Önce 9 farklı literal yarıçap vardı (3·4·5·6·7·8·10·11·12·16); dört basamağa
/// indirildi. 1pt'lik sapmalar (3→4, 5→4, 7→6, 10→8) gözle ayırt edilmez ama
/// "hangi köşe hangi bağlama ait" sorusunu tek kaynağa bağlar.
public extension Theme {
    enum Radius {
        /// 0pt — tam genişlik liste satırı (hover zemini kenara dayanır).
        public static var none: CGFloat { Theme.scaled(0) }
        /// 4pt — rozet, keycap, chip, minik ikon butonu (eski 3/4/5).
        public static var sm: CGFloat { Theme.scaled(4) }
        /// 6pt — input, buton, satır, açılır menü (eski 6/7); modülün varsayılanı.
        public static var md: CGFloat { Theme.scaled(6) }
        /// 8pt — kart ve liste kabı (eski 8/10).
        public static var lg: CGFloat { Theme.scaled(8) }
        /// 16pt — modal panel.
        public static var panel: CGFloat { Theme.scaled(16) }

        /// Ölçeğin tamamı (lint/test).
        public static var scale: [CGFloat] { [sm, md, lg, panel] }
    }

    /// Boşluk ölçeği — 2pt tabanlı.
    enum Spacing {
        /// 1pt — rozet gibi çok sıkı dikey dolgular.
        public static var xxxs: CGFloat { Theme.scaled(1) }
        /// 2pt
        public static var xxs: CGFloat { Theme.scaled(2) }
        /// 4pt
        public static var xs: CGFloat { Theme.scaled(4) }
        /// 6pt
        public static var sm: CGFloat { Theme.scaled(6) }
        /// 8pt
        public static var md: CGFloat { Theme.scaled(8) }
        /// 12pt
        public static var lg: CGFloat { Theme.scaled(12) }
        /// 16pt
        public static var xl: CGFloat { Theme.scaled(16) }
        /// 24pt — form alanları arası / bölüm arası.
        public static var xxl: CGFloat { Theme.scaled(24) }
        /// 32pt — panel iç kenar payı.
        public static var xxxl: CGFloat { Theme.scaled(32) }

        /// Ölçeğin tamamı (lint/test).
        public static var scale: [CGFloat] { [xxxs, xxs, xs, sm, md, lg, xl, xxl, xxxl] }
    }

    /// Liste satırı yükseklikleri.
    ///
    /// Explorer satırı önce dolgudan türeyen değişken bir yüksekliğe sahipti;
    /// sabit yükseklik hem tarama ritmini düzeltir hem de klavye ile gezinirken
    /// satırların yerinde durmasını sağlar.
    enum Row {
        /// 22pt — file-tree / arama sonucu satırı (yoğun liste).
        public static var compact: CGFloat { Theme.scaled(22) }
        /// 16pt — satır ikonunun sabit kolon genişliği; adlar aynı x'te hizalanır.
        public static var iconColumn: CGFloat { Theme.scaled(16) }
        /// 40pt — iki satırlı commit graph satırı (mesaj + meta).
        ///
        /// Bu değer AYNI ZAMANDA graph'ın swimlane segment yüksekliğidir:
        /// lane çizgilerinin satırlar arasında kesintisiz akması için canvas
        /// yüksekliği satır yüksekliğine eşit olmak zorunda.
        public static var commit: CGFloat { Theme.scaled(40) }
        /// 28pt — tam genişlik buton/bölünmüş buton yüksekliği (Commit ▾).
        public static var control: CGFloat { Theme.scaled(28) }
    }

    /// Çizgi kalınlığı — tüm kenarlıklar ve ayraçlar 1pt (hairline).
    enum Stroke {
        public static var hairline: CGFloat { Theme.scaled(1) }
        /// 1.5pt — commit graph lane'i (Orca `CIRCLE_STROKE_WIDTH`).
        public static var graph: CGFloat { Theme.scaled(1.5) }
    }
}
