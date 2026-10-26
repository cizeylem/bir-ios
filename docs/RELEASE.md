# Yayın rehberi (iOS / tvOS SDK)

Dağıtım: **Swift Package Manager, git tag'i**. Paket kayıt defterine yüklenen bir şey yok; tüketici
depo adresini ve tag'i verir. Ürünler: `Cizeylem` (çekirdek) ve `CizeylemAttribution`.

## Sürüm numarası

- Tek kaynak: depo kökündeki `VERSION` dosyası. `Cizeylem.version` (`context.lib_version`) bu değerin
  **elle yazılmış** kopyasıdır (`Sources/Cizeylem/Cizeylem.swift`). SPM'de derleme anı enjeksiyonu yok;
  bunun için derleme eklentisi gerekir ve sıfır bağımlılık/sıfır araç kuralıyla çelişir (bkz. AS-BUILT).
  İki yeri **birlikte** güncelleyin.
- Ayrışmayı iki yer yakalar: `CizeylemTests.testLibVersionSurumKaynagiylaAyni` ve CI'nın
  "Sürüm tutarlılığı" adımı. Tag atıldığında CI ayrıca tag == `VERSION` doğrular.
- Biçim semver: `MAJOR.MINOR.PATCH`, ön sürüm `1.0.0-beta.1`. 1.0.0'a kadar küçük sürümde kırıcı değişiklik olabilir.
- İki ürün aynı depodan, **aynı sürümle** çıkar.

## Tag biçimi: ÖNEKSİZ

`1.0.0-beta.1`. **`v` öneki yok**, `ios-` öneki de yok. Neden: SwiftPM `from: "1.0.0-beta.1"` ile
çözerken tag'i semver olarak ayrıştırır; `v1.0.0` de çözülür ama bu depoda tek biçim tutulur ki
`VERSION` dosyasıyla birebir eşleşsin (CI karşılaştırması düz metindir). Android'in `android-v*` kalıbı
burada **uygulanmaz**: o, tek depoda birden çok platform yayınlandığı için vardı.

Tag'i push etmek CI'yı çalıştırır (`tags: ['[0-9]*']`). Tag, `VERSION` ile eşleşmezse CI kırmızı olur.

## Yayın öncesi kontrol listesi

- [ ] `VERSION` ve `Cizeylem.version` yayınlanacak sürüme ayarlandı, ana dala alındı.
- [ ] Ana dalda CI **yeşil** (iki iş: `paket`, `simulator`). Yeşil CI'nın neyi kanıtlamadığı aşağıda.
- [ ] `scripts/test-floor.env` güncel (CI "alt sınırı yükselt" uyarısı vermiyor).
- [ ] **Privacy report** üretildi ve saklandı (aşağıda). İlk yayından önce bir kez **elle** yapılmalı:
      komut satırı karşılığı yok (AS-BUILT §3), şu an üretilmemiş durumda.
- [ ] Örnek uygulamalar (iOS, tvOS) el ile açıldı; rıza verilince `flush` denendi (AS-BUILT §1: denenmedi).
- [ ] En az bir gerçek cihazda duman testi (AS-BUILT §6: hiç yapılmadı).
- [ ] Sunucu sözleşmesi: attribution alan adları/uç yolu teyit edildi (AS-BUILT: tahmin).
- [ ] Tag atıldı: `git tag 1.0.0-beta.1 && git push origin 1.0.0-beta.1`.
- [ ] GitHub Release oluşturuldu: `gh release create 1.0.0-beta.1 --prerelease --notes-file <not>`
      (ön sürümde `--prerelease`). Notlara privacy report'un bağlantısı konur.
- [ ] Temiz bir projeden `.package(url: "<depo>", from: "1.0.0-beta.1")` çözülüyor ve derleniyor.
- [ ] Hatalı etiket **yeniden kullanılmaz**: SwiftPM önbellekleri etiketi hatırlar. Düzeltme = yeni PATCH/ön sürüm.

## Privacy report nereye konur

Apple'ın "Generate Privacy Report" komutu yalnız Xcode arayüzünde: Organizer > Archives > arşiv > sağ tık.
Elle üretilir: `Samples/CizeylemSampleiOS`'u arşivle (hem çekirdek hem attribution manifest'i birleşir),
PDF'i `docs/privacy-report/<sürüm>.pdf` olarak depoya koy ve GitHub Release notuna bağla.
Beklenen sonuç: çekirdekte tracking yok, yalnız `NSPrivacyAccessedAPICategoryUserDefaults` / `CA92.1`;
attribution hedefi `DeviceID` ve `AdvertisingData` toplanan veri türlerini beyan eder (`Tracking=false`).
`Package.swift` manifest'i `.process` ile paketler; arşivdeki paket bundle'ında kaynağıyla bayt bayt aynı
çıktığı doğrulandı (simülatör derlemesinde), ama Xcode'un rapor toplayıcısının onu okuduğu **hâlâ elle
doğrulanmalı**.

## CocoaPods: kullanılmıyor

CocoaPods trunk'a **yayın yapılmaz** (karar: bu SDK SPM-önceliklidir; trunk hesabı/sırrı yönetmemek için).
Bir tüketici zorunlu olarak CocoaPods istiyorsa, **bu depoda** bir podspec tutulur ve tüketici
`pod 'Cizeylem', :git => '<depo>', :tag => '1.0.0-beta.1'` ile bağlanır. Şu an podspec yok; ihtiyaç
doğarsa eklenir (tag'le birlikte sürümlenir).

## `Sources/spec-adapter/` neden YOK

Plan (Görev 14) stdin'den JSON komut okuyan bir `spec-adapter` yürütülebilir hedefi öngörür; bunun
karşı tarafı `bir-js/spec/` (ortak uyum paketi, "S5") **henüz yok**. Karşı taraf olmadan yazılan adaptör,
şemasını tahmin etmek zorunda kalır ve yanlış bir sözleşmeyi kodlar. Plan da "S5 geldiğinde" der.
O güne kadar kabul kriteri birim testlerdir (SPEC §9). S5 gelince: hedefi ekle, CI'ya ayrı adım olarak koy,
ayrı commit. Hedef `Package.swift`'e yürütülebilir ürün olarak girecek; çekirdeğin bağımlılıksızlığını bozmaz.

## CI (`.github/workflows/ci.yml`)

İki iş, `macos-26` runner'ında. Her adımın kanıtladığı:

| Adım | Kanıtladığı | Kanıtlamadığı |
|---|---|---|
| Sürüm tutarlılığı | `VERSION` == `Cizeylem.version`; tag ise tag == `VERSION` | sürümün değerinin doğru olduğunu |
| `swift build --build-tests -strict-concurrency=complete` | kaynak + test kodu strict concurrency'de derlenir (macOS) | UIKit dalları (macOS'ta derlenmez; simülatör işi kapsar) |
| Uyarı kapısı | derleme günlüğünde `dosya.swift:satır:sütun: warning:` yok | araç uyarıları (bilerek süzülür) |
| `swift test` + test sayısı kapısı | macOS'ta tüm testler geçti **ve** toplam sayı `MACOS` alt sınırından az değil, atlanan 0 | testlerin doğru olduğunu; yalnız "kaybolmadı" |
| iOS/tvOS hazırlığı | runtime ve en az bir cihaz var (yoksa indirildi/`simctl create`) | |
| `test-simulators.sh` | testler iOS **ve** tvOS simülatöründe geçti; tvOS atlanamaz; her platformda test sayısı alt sınırın altında değil, atlanan 0, derleyici uyarısı 0 (UIKit dalları dahil) | gerçek cihaz, iOS 15 çalışma zamanı |

Test sayısı kapısı: `scripts/check-test-count.sh`, alt sınırlar `scripts/test-floor.env`'de. Sayı, her
`Test Suite 'All tests'` özetinin **toplamıdır** (xcodebuild her test paketini ayrı koşu basar; en büyüğünü
almak 40 testlik bir paketin kaybını gizlerdi). Test eklenince betik "alt sınırı yükselt" uyarısı verir.

## Bilinen sınırlar

- Workflow'un **kendisi GitHub'da hiç koşmadı**; betikler yerelde, adımlar YAML olarak yazıldı ve ayrıştırıldı.
  İlk koşu bir doğrulamadır (`macos-26` imajının adı/Xcode sürümü, `xcodebuild -downloadPlatform tvOS`'un
  runner'da süresi ve diski dahil).
- `macos-26` imajında Xcode sürümü AS-BUILT'in kanıt sürümünden (26.2) farklı olabilir; adım sürümü günlüğe yazar.
