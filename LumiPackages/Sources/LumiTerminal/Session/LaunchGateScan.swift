import Foundation

/// Launch-gate'e (`LaunchCommandGate`) verilecek satırların emülatör grid'inden
/// seçimi. Taze spawn edilmiş shell'in prompt'u grid'in ÜSTÜNDE (satır 0-1)
/// render olur; grid `initialRows` (30-48) kadar yüksekse sabit "alt N satır"
/// penceresi prompt'u kaçırır → gate boş ekran görüp sonsuza dek hold'a girer
/// (`claude` hiç enjekte edilmez, chat başlamaz — sandout_word-puzzle bugı).
///
/// Bu yüzden launch-gate için pencere uygulanmaz: grid'in tüm satırları verilir;
/// gate zaten son DOLU satıra bakar, dolayısıyla prompt üstte de olsa bulunur.
enum LaunchGateScan {
    static func lines(fromGrid grid: [String]) -> [String] {
        grid
    }
}
