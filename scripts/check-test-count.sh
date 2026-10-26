#!/usr/bin/env bash
# Koşulan test sayısını alt sınırla doğrular: sessizce atlanan test sınıfı CI'yı yeşil bırakmasın.
#
# Kullanım: scripts/check-test-count.sh <MACOS|IOS|TVOS> <test-çıktısı-dosyası>
# Alt sınır `scripts/test-floor.env` dosyasında durur (sabit yazılmaz). Kural:
#   - Executed N tests: N < alt sınır      -> çıkış 1 (test kayboldu / atlandı)
#   - atlanan test (skipped) > 0           -> çıkış 1 (CI'da hiçbir test atlanmamalı)
#   - N > alt sınır                        -> çıkış 0 ama "alt sınırı yükselt" uyarısı (yeni testler korunsun)
#
# Neden ayrıştırma: `Executed N tests` satırı hem her test paketi hem de toplam için basılır;
# toplam her zaman en büyüğüdür.
set -uo pipefail

platform="${1:-}"; log="${2:-}"
if [ -z "$platform" ] || [ ! -r "$log" ]; then
  echo "kullanım: $0 <MACOS|IOS|TVOS> <log-dosyası>" >&2; exit 2
fi
cd "$(dirname "$0")/.."

floor="$(sed -n "s/^${platform}=//p" scripts/test-floor.env | head -1)"
if ! [[ "$floor" =~ ^[0-9]+$ ]]; then
  echo "HATA: scripts/test-floor.env içinde ${platform}=<sayı> yok" >&2; exit 2
fi

# Toplam = her "Test Suite 'All tests' passed/failed" satırını izleyen "Executed N tests" satırlarının
# TOPLAMI. En büyüğünü almak yanlış olurdu: xcodebuild her test paketini ayrı bir "All tests" koşusu olarak
# basar (çekirdek 387 + attribution 40), `swift test` ise tek toplam basar; ikisi de toplamla doğru çıkar.
summary="$(awk '/^Test Suite .All tests. (passed|failed)/ {want=1; next}
  want && /Executed [0-9]+ tests?/ {
    match($0, /Executed [0-9]+/); e += substr($0, RSTART+9, RLENGTH-9)
    if (match($0, /with [0-9]+ tests? skipped/)) { split(substr($0, RSTART, RLENGTH), t, " "); k += t[2] }
    want=0; n++ }
  END { print e+0, k+0, n+0 }' "$log")"
read -r executed skipped suites <<<"$summary"
if [ "${suites:-0}" -eq 0 ]; then
  echo "HATA [$platform]: çıktıda 'All tests' özeti yok; testler hiç koşmamış olabilir" >&2; exit 1
fi

echo "[$platform] koşulan test: $executed (alt sınır: $floor), atlanan: $skipped"
if [ "$executed" -lt "$floor" ]; then
  echo "HATA [$platform]: $executed test koştu, en az $floor bekleniyordu. Bir test sınıfı sessizce atlanmış ya da silinmiş olabilir." >&2
  exit 1
fi
if [ "$skipped" -gt 0 ]; then
  echo "HATA [$platform]: $skipped test ATLANDI. CI'da atlanan test kabul edilmez." >&2
  exit 1
fi
if [ "$executed" -gt "$floor" ]; then
  echo "UYARI [$platform]: $executed > $floor. scripts/test-floor.env içindeki ${platform} değerini $executed yapın (yeni testler korunsun)." >&2
  [ -n "${GITHUB_ACTIONS:-}" ] && echo "::warning::scripts/test-floor.env ${platform} alt sınırı $executed'e yükseltilmeli"
fi
exit 0
