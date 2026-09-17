#!/bin/bash
# Lumi'yi ÇALIŞIRKEN güncelle: kurulumu, uygulamadan çıktığın ana ertele.
#
# Kullanım:
#   Scripts/install-on-quit.sh                # build al + izleyiciyi kur
#   Scripts/install-on-quit.sh --skip-build   # dist/Lumi.app hazırsa build'i atla
#   Scripts/install-on-quit.sh --cancel       # bekleyen izleyiciyi iptal et
#
# NEDEN VAR: `make-app.sh --install` Lumi çalışırken bilerek reddeder (çalışan
# uygulamanın bundle'ını silmek, süreç eski inode'u tuttuğu için sessizce "eski
# sürümü kullanmaya devam etme" durumu yaratır). Ama Claude Code'u Lumi'nin kendi
# terminal kartında çalıştırıyorsan Lumi'yi kapatmak o oturumu da düşürür, yani
# kurulumu oturum içinden tamamlayamazsın.
#
# Çözüm: kurulumu launchd'ye devret. Bu script bir LaunchAgent kaydeder; agent
# Lumi'nin kapanmasını bekler, /Applications'a kurar, uygulamayı yeniden açar ve
# kendini siler. launchd süreci sahiplendiği için Lumi'nin quit'i (PTY SIGHUP)
# onu etkilemez — `setsid`/`nohup` ile detach etmek YETMEZ, denendi ve ⌘Q anında
# süreç öldü, kurulum sessizce yapılmadı.
#
# Sen sadece ⌘Q yapıp Lumi'yi tekrar açılmış bulursun; oturumların resume edilir.
set -euo pipefail

LABEL="com.lumi.install-once"
STATE_DIR="$HOME/.lumi-installer"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$STATE_DIR/install.log"
TARGET="/Applications/Lumi.app"
# Beklemenin üst sınırı: 12 saat. Dolarsa izleyici kurulum YAPMADAN temizlenir —
# günler sonra beklenmedik bir anda uygulamayı değiştirmesindense iptal olsun.
MAX_WAIT_SECONDS=43200

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SELF="$ROOT/Scripts/$(basename "${BASH_SOURCE[0]}")"

# Lumi çalışıyor mu?
#
# İKİ TUZAK VAR, ikisi de yaşandı:
#  1. `pgrep` KULLANMA: `-x Lumi` hiç eşleşmez (macOS'ta süreç adı tam yoldur)
#     ve bazı bağlamlarda (ör. Claude Code'un Bash aracı) çalışan uygulamayı
#     hiç göremeyip "kapalı" der.
#  2. `ps … | grep -q` KULLANMA: `set -o pipefail` ile BOZUK. `grep -q`
#     eşleşmeyi bulur bulmaz çıkar, `ps` SIGPIPE alır ve pipefail pipeline'ı
#     141 yapar — yani eşleşme VARKEN koşul "bulunamadı"ya düşer. `ps -eo args=`
#     çıktısı ~150 KB, pipe buffer 64 KB olduğu için bu kaçınılmaz.
#
# Bu yüzden pipe hiç kurulmaz: çıktı tamamen okunur, eşleşme kabukta yapılır.
lumi_running() {
  local procs
  procs="$(ps -eo args= 2>/dev/null || true)"
  case "$procs" in
    *"Lumi.app/Contents/MacOS/Lumi"*) return 0 ;;
    *) return 1 ;;
  esac
}

unload_agent() {
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  rm -f "$PLIST"
}

# --- izleyici modu: LaunchAgent buradan çağırır -----------------------------
if [ "${1:-}" = "--watch" ]; then
  SRC="${2:?--watch bir kaynak .app yolu ister}"
  mkdir -p "$STATE_DIR"
  exec >>"$LOG" 2>&1
  echo "=== $(date) izleyici başladı (PID=$$ PPID=$PPID) kaynak=$SRC"

  waited=0
  while lumi_running; do
    if [ "$waited" -ge "$MAX_WAIT_SECONDS" ]; then
      echo "$(date) $MAX_WAIT_SECONDS sn doldu, Lumi hâlâ açık — kurulum YAPILMADI"
      unload_agent
      exit 0
    fi
    sleep 1
    waited=$((waited + 1))
  done

  echo "$(date) Lumi kapalı (${waited} sn beklendi), kuruluma geçiliyor"
  # Uygulamanın dosya tanıtıcılarını gerçekten bırakması için kısa pay.
  sleep 2

  if [ ! -d "$SRC" ]; then
    echo "$(date) HATA: kaynak yok → $SRC"
    unload_agent
    exit 1
  fi

  if rm -rf "$TARGET" && ditto "$SRC" "$TARGET"; then
    echo "$(date) kuruldu: $(/usr/bin/stat -f '%z bayt, %Sm' -t '%Y-%m-%d %H:%M:%S' "$TARGET/Contents/MacOS/Lumi")"
    open "$TARGET" && echo "$(date) açıldı"
  else
    echo "$(date) KURULUM BAŞARISIZ"
  fi

  echo "$(date) izleyici bitiyor, LaunchAgent kaldırılıyor"
  unload_agent
  exit 0
fi

# --- kurulum modu ----------------------------------------------------------
SKIP_BUILD=0
for arg in "$@"; do
  case "$arg" in
    --skip-build) SKIP_BUILD=1 ;;
    --cancel)
      unload_agent
      echo "✓ Bekleyen izleyici iptal edildi (kurulum yapılmadı)."
      exit 0
      ;;
    *) echo "Bilinmeyen parametre: $arg (desteklenen: --skip-build, --cancel)" >&2; exit 1 ;;
  esac
done

SRC="$ROOT/dist/Lumi.app"

if [ "$SKIP_BUILD" -eq 0 ]; then
  "$ROOT/Scripts/make-app.sh"
elif [ ! -d "$SRC" ]; then
  echo "HATA: --skip-build verildi ama $SRC yok. Önce build al." >&2
  exit 1
fi

if ! lumi_running; then
  echo "▸ Lumi kapalı — ertelemeye gerek yok, doğrudan kuruluyor…"
  rm -rf "$TARGET"
  ditto "$SRC" "$TARGET"
  echo "✓ $TARGET kuruldu"
  exit 0
fi

mkdir -p "$STATE_DIR" "$HOME/Library/LaunchAgents"
# Önceki bir bekleyiş varsa değiştir (idempotent).
unload_agent

cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$SELF</string>
    <string>--watch</string>
    <string>$SRC</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <false/>
</dict>
</plist>
PLIST_EOF

plutil -lint "$PLIST" >/dev/null
launchctl bootstrap "gui/$(id -u)" "$PLIST"

# "Kuruldu" varsayma, ÖLÇ: agent gerçekten koşuyor mu?
# Burada da pipe YOK — yukarıdaki SIGPIPE tuzağı `launchctl print | grep -q`
# için de geçerli (çıktısı uzun) ve doğrulamanın kendisi yanlış negatif verirdi.
AGENT_STATE="$(launchctl print "gui/$(id -u)/$LABEL" 2>/dev/null || true)"
case "$AGENT_STATE" in
  *"state = running"*|*"state = waiting"*)
    echo "✓ İzleyici hazır — Lumi'den ⌘Q ile çık, kurulum kendiliğinden yapılıp uygulama yeniden açılacak."
    echo "  Günlük: $LOG"
    echo "  İptal : Scripts/install-on-quit.sh --cancel"
    ;;
  *)
    echo "HATA: LaunchAgent kaydedildi ama çalışmıyor. $LOG dosyasına bak." >&2
    exit 1
    ;;
esac
