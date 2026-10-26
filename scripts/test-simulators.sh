#!/usr/bin/env bash
# Paketin testlerini iOS ve tvOS simülatöründe koşturur.
#
# Çıkış kodu:
#   0  iOS ve tvOS testlerinin İKİSİ de geçti
#   1  bir test düştü, derleme patladı, iOS runtime'ı yok ya da tvOS ATLANDI
#
# Neden katı: "tvOS runtime'ı yok, atladım" mesajı yeşil bir CI'ya dönüşürse tvOS'un hiç
# denenmediği kimsenin gözüne çarpmaz. Atlama yalnız `--allow-missing-tvos` ile ve yüksek
# sesle kabul edilir; o durumda bile çıkış satırı "KISMEN" der.
set -uo pipefail

ALLOW_MISSING_TVOS=0
for arg in "$@"; do
  case "$arg" in
    --allow-missing-tvos) ALLOW_MISSING_TVOS=1 ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) echo "bilinmeyen bayrak: $arg" >&2; exit 2 ;;
  esac
done

cd "$(dirname "$0")/.."

# Cihaz adı sabit yazılmaz: makinede hangi runtime/cihaz varsa o seçilir.
# stdout: "<runtime-kimliği>\t<udid>\t<runtime-adı>\t<cihaz-adı>" ya da boş.
pick_device() {
  local family="$1"
  xcrun simctl list devices available -j | /usr/bin/python3 -I -c '
import json, sys
family = sys.argv[1]
data = json.load(sys.stdin)["devices"]
def ver(k):
    tail = k.rsplit(".", 1)[-1].split("-", 1)[1]
    return tuple(int(p) for p in tail.split("-") if p.isdigit())
best = None
for runtime, devs in data.items():
    if "SimRuntime." + family + "-" not in runtime:
        continue
    if not devs:
        continue
    key = ver(runtime)
    if best is None or key > best[0]:
        best = (key, runtime, devs[0])
if best:
    print("%s\t%s\t%s\t%s" % (best[1], best[2]["udid"], ".".join(map(str, best[0])), best[2]["name"]))
' "$family"
}

# Runtime kurulu mu, `simctl list runtimes` ile sınanır; kurulu ama cihazı yoksa ayrı bildirilir.
has_runtime() {
  xcrun simctl list runtimes available | grep -q "SimRuntime\.$1-"
}

IOS_RESULT="ATLANMADI"; TVOS_RESULT="ATLANMADI"

run_family() {
  local family="$1" label="$2" var="$3"
  if ! has_runtime "$family"; then
    eval "$var=\"ATLANDI (runtime yok)\""
    return
  fi
  local picked
  picked="$(pick_device "$family")"
  if [ -z "$picked" ]; then
    eval "$var=\"ATLANDI (runtime var, cihaz yok)\""
    return
  fi
  local udid rtname dname
  udid="$(printf '%s' "$picked" | cut -f2)"
  rtname="$(printf '%s' "$picked" | cut -f3)"
  dname="$(printf '%s' "$picked" | cut -f4)"
  echo "==> $label: $dname ($family $rtname, $udid)"
  local log; log="$(mktemp -t "cizeylem-$family")"
  if xcodebuild test -scheme Cizeylem-Package -destination "id=$udid" \
       -skipPackagePluginValidation 2>&1 | tee "$log" | grep -E "^[[:space:]]*(Test Suite 'All tests'|\*\* TEST|Executed )" ; then :; fi
  if grep -q "\*\* TEST SUCCEEDED \*\*" "$log"; then
    # Geçti demek yetmez: sessizce atlanan test sınıfı da "geçer". Sayı alt sınırın altındaysa düşer.
    # UIKit dalları yalnız simülatörde derlenir; macOS'taki uyarı kapısı onları görmez.
    if grep -E '\.swift:[0-9]+:[0-9]+: warning:' "$log"; then
      eval "$var=\"BASARISIZ (derleyici uyarısı var; $family $rtname, $dname); tam çıktı: $log\""
      return
    fi
    local floor_key; floor_key="$(printf '%s' "$family" | tr '[:lower:]' '[:upper:]')"
    if ./scripts/check-test-count.sh "$floor_key" "$log"; then
      eval "$var=\"GECTI ($family $rtname, $dname)\""
    else
      eval "$var=\"BASARISIZ (test sayısı kapısı; $family $rtname, $dname); tam çıktı: $log\""
    fi
  else
    eval "$var=\"BASARISIZ ($family $rtname, $dname); tam çıktı: $log\""
  fi
}

run_family iOS "iOS" IOS_RESULT
run_family tvOS "tvOS" TVOS_RESULT

echo
echo "iOS : $IOS_RESULT"
echo "tvOS: $TVOS_RESULT"

case "$IOS_RESULT" in GECTI*) ;; *) echo "SONUC: BASARISIZ (iOS)"; exit 1 ;; esac
case "$TVOS_RESULT" in
  GECTI*) echo "SONUC: BASARILI"; exit 0 ;;
  ATLANDI*)
    if [ "$ALLOW_MISSING_TVOS" = 1 ]; then
      echo "SONUC: KISMEN (tvOS KANITLANMADI; --allow-missing-tvos ile kabul edildi)"
      exit 0
    fi
    echo "SONUC: BASARISIZ (tvOS atlandı; kurmak için: xcodebuild -downloadPlatform tvOS)"
    exit 1 ;;
  *) echo "SONUC: BASARISIZ (tvOS)"; exit 1 ;;
esac
