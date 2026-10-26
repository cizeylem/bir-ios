#!/usr/bin/env bash
# Verilen platform (iOS | tvOS) için simülatör runtime'ını ve en az bir cihazı hazırlar.
# `scripts/test-simulators.sh` runtime/cihaz yoksa bilerek çıkış 1 verir; CI bu betikle onu önler.
#
# Eşzamanlılık: yalnız eksik olanı yapar (idempotent). Runtime kuruluysa indirme yok, cihaz varsa
# yaratma yok. Hiçbir cihazı BAŞLATMAZ (xcodebuild test kendisi açar).
set -euo pipefail

family="${1:-}"
case "$family" in iOS|tvOS) ;; *) echo "kullanım: $0 <iOS|tvOS>" >&2; exit 2 ;; esac

has_runtime() { xcrun simctl list runtimes available | grep -q "SimRuntime\.${family}-"; }

if ! has_runtime; then
  echo "==> $family runtime'ı yok, indiriliyor (xcodebuild -downloadPlatform $family)"
  xcodebuild -downloadPlatform "$family"
fi
if ! has_runtime; then
  echo "HATA: $family runtime'ı indirmeye rağmen kurulu görünmüyor" >&2
  exit 1
fi

# Cihaz var mı? Varsa dokunma.
existing="$(xcrun simctl list devices available -j | /usr/bin/python3 -I -c '
import json, sys
fam = sys.argv[1]
data = json.load(sys.stdin)["devices"]
print(sum(len(d) for rt, d in data.items() if "SimRuntime." + fam + "-" in rt))
' "$family")"
if [ "$existing" -gt 0 ]; then
  echo "==> $family: $existing cihaz zaten var, yaratılmadı"
  exit 0
fi

# En yüksek sürümlü runtime + o aileye uyan ilk cihaz tipi. Cihaz adı/sürümü sabit yazılmaz.
picked="$(xcrun simctl list runtimes available -j | /usr/bin/python3 -I -c '
import json, subprocess, sys
fam = sys.argv[1]
rts = [r for r in json.load(sys.stdin)["runtimes"] if r.get("platform") == fam or "SimRuntime." + fam + "-" in r["identifier"]]
rts = [r for r in rts if r.get("isAvailable", True)]
rts.sort(key=lambda r: [int(p) for p in r["version"].split(".") if p.isdigit()])
rt = rts[-1]
types = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devicetypes", "-j"]))["devicetypes"]
want = "Apple-TV" if fam == "tvOS" else "iPhone"
ids = [t["identifier"] for t in types if want in t["identifier"]]
supported = {t["identifier"] for t in rt.get("supportedDeviceTypes", [])}
ids = [i for i in ids if not supported or i in supported] or ids
print(rt["identifier"] + "\t" + ids[-1])
' "$family")"
runtime_id="$(printf '%s' "$picked" | cut -f1)"
type_id="$(printf '%s' "$picked" | cut -f2)"
echo "==> $family: cihaz yok, yaratılıyor ($type_id, $runtime_id)"
xcrun simctl create "Cizeylem $family" "$type_id" "$runtime_id"
