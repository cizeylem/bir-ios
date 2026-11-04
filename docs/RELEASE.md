# Yayın rehberi (iOS / tvOS SDK)

Dağıtım: **Swift Package Manager, git tag'i**. Paket kayıt defterine yüklenen bir şey yok; tüketici
depo adresini (`https://github.com/cizeylem/bir-ios`) ve tag'i verir. Ürünler: `Cizeylem` (çekirdek) ve
`CizeylemAttribution`. Lisans Apache 2.0 (`LICENSE`, `NOTICE`; Android deposuyla aynı metin).

Bir yayın = sürümü ana dala al, **öneksiz tag'i elle push et**. Gerisi otomatik: tag CI'yı koşturur, CI yeşil
biterse `release.yml` GitHub Release'i açar. Swift Package Index yeni tag'i kendisi bulur.

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

Tag'i push etmek CI'yı çalıştırır (`tags: ['[0-9]*']`). Tag, `VERSION` ile eşleşmezse CI kırmızı olur ve
Release açılmaz.

## Tek seferlik: herkese açık yayın hazırlığı

Depoda olanlar (bu dosyalar ana dalda olmalı):

- [x] `LICENSE` (Apache 2.0, tam metin) ve `NOTICE`.
- [x] `README.md`: kurulum, iki ürün, kullanım, gizlilik, sürümleme, lisans.
- [x] `.spi.yml`: Swift Package Index doküman hedefleri (aşağıda).
- [x] `.github/workflows/release.yml`: GitHub Release otomasyonu (aşağıda). `workflow_run` yalnız **varsayılan
      daldaki** dosyayla tetiklenir: ilk tag'den önce ana dala alınmış olmalı.

Kullanıcının elle yapacakları (yetki gerektirir, otomasyonu yok):

- [ ] **Depo public yapıldı** (GitHub > Settings > General > Danger Zone > Change visibility). Public depoda
      standart runner'lar (`macos-26` dahil) ücretsizdir; private iken CI işleri faturalama sınırı yüzünden hiç
      başlamadı (bkz. Bilinen sınırlar).
- [ ] Public yapıldıktan sonra ana dalda CI **gerçekten koştu ve yeşil** (ilk koşu; hiç koşmadı).
- [ ] İlk tag atıldı ve `Yayın` workflow'u Release'i açtı (aşağıdaki kontrol listesi).
- [ ] **Swift Package Index'e eklendi**: <https://swiftpackageindex.com/add-a-package> üzerinden
      `https://github.com/cizeylem/bir-ios` önerilir (sayfadaki yönergeyle; ekleme SPI tarafında onaylanır).
      Depo public olmalı ve en az bir semver tag'i bulunmalı. Sonrasında yeni tag'ler kendiliğinden alınır.

## Yayın öncesi kontrol listesi

- [ ] `VERSION` ve `Cizeylem.version` yayınlanacak sürüme ayarlandı, ana dala alındı.
- [ ] `README.md`'deki kurulum sürümü (`from: "…"`, `upToNextMinor(from: "…")`, Xcode adımı) yeni sürüme güncellendi.
- [ ] Ana dalda CI **yeşil** (iki iş: `paket`, `simulator`). Yeşil CI'nın neyi kanıtlamadığı aşağıda.
- [ ] `scripts/test-floor.env` güncel (CI "alt sınırı yükselt" uyarısı vermiyor).
- [ ] **Privacy report** üretildi ve saklandı (aşağıda). İlk yayından önce bir kez **elle** yapılmalı:
      komut satırı karşılığı yok (AS-BUILT §3), şu an üretilmemiş durumda.
- [ ] Örnek uygulamalar (iOS, tvOS) el ile açıldı; rıza verilince `flush` denendi (AS-BUILT §1: denenmedi).
- [ ] En az bir gerçek cihazda duman testi (AS-BUILT §6: hiç yapılmadı).
- [ ] Sunucu sözleşmesi: attribution alan adları/uç yolu teyit edildi (AS-BUILT: tahmin).
- [ ] Tag atıldı: `git tag 1.0.0-beta.1 && git push origin 1.0.0-beta.1`.
- [ ] CI tag koşusu yeşil bitti, ardından **`Yayın` workflow'u** (`release.yml`) GitHub Release'i açtı
      (Actions sekmesi). Elle `gh release create` **yapılmaz**. Notlar `--generate-notes` ile otomatik;
      tag'de `-` varsa ön sürüm işaretlenir.
- [ ] Release notuna privacy report'un bağlantısı eklendi: `gh release edit 1.0.0-beta.1 --notes-file <not>`
      (ya da arayüzden düzenle). Otomatik notlar bunu içermez.
- [ ] Temiz bir projeden `.package(url: "<depo>", from: "1.0.0-beta.1")` çözülüyor ve derleniyor.
- [ ] Hatalı etiket **yeniden kullanılmaz**: SwiftPM önbellekleri etiketi hatırlar. Düzeltme = yeni PATCH/ön sürüm.

## GitHub Release (`.github/workflows/release.yml`)

Tetikleyici `workflow_run`: `CI` workflow'u bittiğinde çalışır, Release'i yalnız şu koşulların hepsinde açar:

- CI koşusu `success` (kırmızı ya da iptal edilmiş tag'e Release çıkmaz),
- koşu bu depodaki bir **push** (PR koşuları elenir) ve ana dal değil (ana dal itişleri elenir),
- dal adı öneksiz semver (`1.2.3`, `1.2.3-beta.1`; `v` önekli ya da başka biçim hata verir),
- o ad depoda gerçekten bir **tag** ve tag hâlâ CI'nın test ettiği commit'i gösteriyor,
- o commit'teki `VERSION` == tag.

Neden tag push'u yerine `workflow_run`: ci.yml tag'de zaten koşuyor. Doğrudan tag push'unda tetiklenen bir
iş CI'yı beklemez (Release kırmızı CI'ya rağmen çıkar) ya da CI'yı ikinci kez koşturmak zorunda kalır.
`needs` yalnız aynı workflow içinde çalışır; o yol yazma iznini ci.yml'e taşırdı. Bedeli: `workflow_run`
tetikleyicide tag deseni filtresi almaz, desen adımda denetlenir; ve yalnız varsayılan daldaki dosya
tetiklenir.

İzin yalnız `contents: write`. İş **hiç action kullanmaz** (checkout bile yok): `VERSION` ve tag GitHub API'sinden
`gh api` ile okunur. Yazma jetonu olan işte üçüncü taraf kod çalışmaz. Bir action eklenirse tam commit
SHA'sına sabitlenir (ci.yml kuralı).

Yeniden koşu güvenli: o tag için Release zaten varsa iş dokunmadan çıkar. İş kırmızı biterse günlükteki
`::error::` nedeni söyler; tag/`VERSION` hatasında düzeltme yeni sürümdür (hatalı tag yeniden kullanılmaz).
Yalnız geçici bir hatada (ör. GitHub API) Actions'tan "Re-run" yeterlidir. Otomasyon hiç tetiklenmezse son
çare elle: `gh release create <tag> --verify-tag --generate-notes` (ön sürümde `--prerelease`).

## Swift Package Index (`.spi.yml`)

`documentation_targets: [Cizeylem, CizeylemAttribution]`: SPI her iki ürünün DocC dokümanını üretir ve
barındırır. `platform` verilmedi: SPI dokümanı varsayılan olarak macOS'ta SwiftPM ile (`macos-spm`) üretir;
paket macOS 12'yi desteklediği ve **genel API hiçbir platforma koşullu olmadığı** için (UIKit yalnız
`initialize`'ın gövdesinde) iOS'ta üretilen doküman aynı olurdu. Yerelde `xcodebuild docbuild` (macOS) iki
hedefte de başarılı. Uyumluluk matrisi (iOS/tvOS/macOS, Swift sürümleri) `.spi.yml`'de yazılmaz; SPI onu
kendi derlemelerinden çıkarır. Dosya en fazla 1.500 bayt olabilir (SPIManifest sınırı). Biçim kaynağı:
`SwiftPackageIndex/SPIManifest` (`Manifest.swift`, `Platform.swift`).

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

- **CI GitHub'da hiç başlamadı (2026-10-27 itibarıyla):** ana daldaki iki koşu kırmızı, ama iş adımı yok;
  açıklama "recent account payments have failed or your spending limit needs to be increased". Depo private
  iken macOS dakikası faturalanıyor. Public yapılınca ücretsiz olur; aksi halde faturalama düzeltilmeli.
  CI yeşil olmadan `release.yml` hiçbir zaman Release açmaz.
- `release.yml` de GitHub'da **hiç koşmadı**. Kabul: tag push'unun `workflow_run` etkinliğinde `head_branch`
  tag'in adıdır (GitHub'ın davranışı; burada denenemedi). Adımların kabuk mantığı yerelde sahte `gh` ile
  yedi durumda (kararlı, ön sürüm, `v` önekli, taşınmış tag, `VERSION` uyuşmazlığı, olmayan tag, zaten var)
  denendi; kullanılan iki `gh api` çağrısı gerçek depoya karşı denendi.

- Workflow'un **kendisi GitHub'da hiç koşmadı**; betikler yerelde, adımlar YAML olarak yazıldı ve ayrıştırıldı.
  İlk koşu bir doğrulamadır (`macos-26` imajının adı/Xcode sürümü, `xcodebuild -downloadPlatform tvOS`'un
  runner'da süresi ve diski dahil).
- `macos-26` imajında Xcode sürümü AS-BUILT'in kanıt sürümünden (26.2) farklı olabilir; adım sürümü günlüğe yazar.
