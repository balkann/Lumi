import LumiKit
import SwiftUI

/// DeepSeek bakiye göstergesinin toolbar descriptor'ı (karar 75).
///
/// Görünürlüğün İKİ kapısı vardır: config anahtarı (descriptor'ın `isVisible`'ı)
/// ve anahtarın kurulu olması. İkincisi burada okunur — anahtar yokken gösterge
/// hep "—" gösterip her yenilemede hata üretirdi.
public struct DeepSeekBalanceToolbarItem: View {
    @Shell private var shell

    public init() {}

    public var body: some View {
        if shell.deepSeek.isInstalled {
            DeepSeekBalanceIndicatorView(store: shell.deepSeekBalance)
        }
    }
}
