# AS-BUILT: Çizeylem iOS SDK (Görev 11 sonu, çekirdek)

Bu belge yapılanı ve **neyin kanıtlandığını, neyin kanıtlanmadığını** yazar. Kanıt tarihi: 2026-10-26,
Xcode 26.2 (17C52), Swift 6.2.3.

## 1. Kanıt tablosu

| İddia | Durum | Kanıt |
|---|---|---|
| Paket testleri macOS'ta geçer | kanıtlandı | `swift test` (önceki görevler) |
| Paket testleri **iOS simülatöründe** geçer | kanıtlandı | `scripts/test-simulators.sh`: iOS 26.2, iPad Air 11-inch (M3), **366 test, 0 başarısızlık**, `** TEST SUCCEEDED **` |
| Paket testleri **tvOS simülatöründe** geçer | **KANITLANMADI** | Bu makinede tvOS simülatör runtime'ı yoktu (`simctl list runtimes` yalnız iOS 18.3 ve 26.2). `xcodebuild` tvOS için `generic/platform=tvOS Simulator` hedefini bile kurmuyor ("tvOS 26.2 is not installed"). Betik tvOS'u ATLANDI diye bildirdi ve çıkış 1 verdi (katı varsayılan) |
| tvOS kodu derlenir | kısmen | `swiftc -typecheck` (appletvsimulator26.2 SDK, `arm64-apple-tvos15.0-simulator`, Swift 6, strict concurrency, `-warnings-as-errors`): çekirdek modül ve tvOS örnek kaynakları temiz. Bu **yalnız tür denetimi**; bağlama, paketleme ve çalıştırma yok |
| iOS örnek uygulaması 0 uyarıyla derlenir ve arşivlenir | kanıtlandı | `xcodebuild build` ve `archive` (generic iOS, imzasız), `SWIFT_TREAT_WARNINGS_AS_ERRORS=YES` |
| iOS örneği açılır, rızasızken **diske hiçbir şey yazmaz** | kanıtlandı (tek koşu) | iPad simülatöründe taze kurulum+açılış: ekranda `running: false`, `distinctId: nil`, `queued: 0`, üç rıza `false`. Uygulama veri konteynerinde yalnız sistemin `Saved Application State` dosyaları var; `Library/Preferences`, `Application Support`, `Caches` altında SDK dosyası **yok** |
| Rıza verilince kimlik/kuyruk oluşur, `flush` gider | **denenmedi** | Düğmelere simülatörde dokunulmadı (bu ortamda dokunma otomasyonu kurulmadı). Yalnız rızasız başlangıç ekranı görüldü |
| tvOS örneği çalışır | **denenmedi** | Runtime yok |
| Privacy report | bkz. §3: **üretilemedi** | |
| Gerçek cihaz | **yapılmadı** | Hiçbir gerçek iPhone/Apple TV'de denenmedi (bkz. §6) |

Simülatör koşusu iOS 18.3 runtime'ında **yapılmadı**; betik en yüksek sürümlü iOS runtime'ını seçer. Dağıtım
tabanı olan iOS 15 hiçbir yerde çalıştırılmadı: SDK 26.2 ile derlenip `-target ios15.0` ile bağlandı, testler
iOS 26.2 çalışma zamanında koştu. Düşük sürümlerde eksik API riski (derleyici `@available` ile yakalar ama
çalışma zamanı davranışı görülmedi) kanıtsızdır.

### Betik davranışı (`scripts/test-simulators.sh`)

Çalışma zamanı varlığı `xcrun simctl list runtimes available` ile, cihaz `simctl list devices available -j`
ile seçilir; cihaz adı sabit değil. Gerçek çıktı (tvOS runtime'sız makinede):

```
iOS : GECTI (iOS 26.2, iPad Air 11-inch (M3) Review)
tvOS: ATLANDI (runtime yok)
SONUC: BASARISIZ (tvOS atlandı; kurmak için: xcodebuild -downloadPlatform tvOS)
exit=1
```

Varsayılan katı: tvOS atlanırsa çıkış 1. `--allow-missing-tvos` çıkışı 0 yapar ama son satır
`KISMEN (tvOS KANITLANMADI ...)` der. tvOS runtime'ı kurulduğunda betik aynı komutla her iki platformu koşar;
**tvOS yolu bu makinede hiç yürütülmedi** (yalnız "runtime yok" dalı denendi). tvOS'ta `flushAt` varsayılanı 5,
iOS'ta 30 (`Platform.current`) ve tvOS dalının testleri ancak o koşuda görülür.

## 2. Örnek uygulamalar

`Samples/CizeylemSampleiOS` ve `Samples/CizeylemSampleTV`: SwiftUI, tek ekran (`Samples/Shared`). Ayrı Xcode
projeleridir; `Package.swift`'e eklenmediler, `swift test` etkilenmez. Projeler `project.yml`'den XcodeGen ile
üretilir (`xcodegen generate`, yalnız geliştirici aracı; SDK'ya bağımlılık değil) ve üretilmiş `.xcodeproj` de
depodadır. Ekranda: üç rıza anahtarı + "Rızayı uygula", `track`, `identify`, `reset`, `flush`,
`setOptOut(true/false)`, `distinctId`, `stats()` (saniyede bir yenilenir) ve SDK `logger` günlüğü.

- `initialize` `AppDelegate.didFinishLaunching` içinde, ana aktörde çağrılır. Bu anda
  `applicationState == .inactive`; SDK `startsActive`'i `false` okur ve hemen gelen `didBecomeActive`
  `cz_app_opened`'ı üretir. (Davranış birim testlerinde var; örnekte **gözlenmedi**, çünkü rıza kapalıyken event yok.)
- Varsayılan uç `http://127.0.0.1:9` (dinleyen yok) ve sahte yazma anahtarı: yanlışlıkla üretime veri gitmez.
  `CIZEYLEM_ENDPOINT` / `CIZEYLEM_WRITE_KEY` ortam değişkenleriyle ezilir. Bu yüzden elle denemede `flush`
  sonrası `queued` düşmez; gerçek gönderim için gerçek uç gerekir. `Info.plist`'te `NSAllowsLocalNetworking`.
- Rızası `Stats.consent` ile ekrandaki anahtarlar `setOptOut` sonrası eşitlenir.

## 3. Privacy report

**Üretilemedi.** Xcode'un "Generate Privacy Report" komutu (Organizer > arşiv) yalnızca arayüzde var; komut
satırı karşılığı bulunmadı. Bu oturum arayüz kullanamaz. Denenen ve görülen:

- `xcodebuild archive` (generic iOS, imzasız) **başarılı**.
- Arşivde (`Products/Applications/CizeylemSampleiOS.app/Cizeylem_Cizeylem.bundle/PrivacyInfo.xcprivacy`)
  manifest **var**, kaynak dosyayla **bayt bayt aynı** ve `plutil -lint` OK. İçerik: `NSPrivacyTracking=false`,
  `NSPrivacyTrackingDomains` boş, `NSPrivacyCollectedDataTypes` boş, yalnız `NSPrivacyAccessedAPICategoryUserDefaults`
  / `CA92.1`. Arşivde başka `PrivacyInfo.xcprivacy` yok (uygulamanın kendisinin de yok; örnek bunu eklemedi).
- Manifest, SPM'in ürettiği kaynak paketinde (`Cizeylem_Cizeylem.bundle`) duruyor; `Package.swift` `.copy` kullanıyor.
  Xcode'un rapor toplayıcısının bu paketten okuyup okumadığı **doğrulanmadı**: beklenen "tracking yok, yalnız
  `CA92.1`" sonucu arayüzde elle üretilene dek **kanıtlanmış sayılmaz**. Elle adım: Xcode > Window > Organizer >
  Archives > arşivi seç > Distribute değil, sağ tık "Generate Privacy Report".
- Not: App Store gönderiminde Apple'ın "required reason" doğrulaması kaynak-paket bundle'ını da tarar; `.copy`
  yerine `.process` kullanımı Apple belgelerinin önerdiği biçimdir. Bu ana paketi ilgilendiren bir **olası sorun**
  olarak not edildi, düzeltilmedi (§7).

## 4. `[doğrula]` maddelerinin sonucu

Kaynak: `.superpowers/sdd/2026-10-23-bir-ios-sdk/amplitude-swift-arastirmasi.md` (yalnız kaynak kod okundu,
hiçbir şey çalıştırılmadı; Amplitude-Swift v1.19.3, Amplitude-iOS 8.22.2).

- **Suite adı (SPEC §11 açık nokta): kapandı.** `com.amplitude.storage.amplitude-swift-storage-<apiKey>-<instance>`;
  varsayılan `<instance>` birebir `$default_instance` (boş → varsayılan, küçük harfe çevirme yok). Anahtarlar düz
  `device_id` ve `user_id`. Ayrıca `...-identify-...` suite'i var ama kimlik orada değil.
- **Swift `optOut` kalıcı değil** (yalnız bellek); SDK Amplitude `optOut`'unu Swift'ten okuyamaz.
- **ObjC SQLite şeması:** iOS'ta `Library/com.amplitude.database` (tvOS'ta `Library/Caches`); tablo `store(key, value)`;
  `device_id`/`user_id` orada, `opt_out` ve oturum `long_store` tablosunda; adlandırılmış örnekte
  `com.amplitude.database_<instance küçük harf>`. Eski ObjC SDK `NSUserDefaults` kullanmaz.
- **Geçersiz `device_id` kümesi (Swift):** `e3f5536a141811db40efd6400f1d0a4e`, `04bab7ee75b9a58d39b8dc54e8851084`,
  sıfır-UUID, `02:00:00:00:00:00`, `020000000000`. ("sonu S ile biten" kuralı iOS'ta yok.)
- **Kanıtlanmayan kalanlar:** host uygulamanın gömdüğü gerçek Amplitude sürümü bilinmiyor; suite plist'inin disk yolu
  (`Library/Preferences/<suite>.plist`) Apple davranışı, bu işte **doğrulanmadı**; eski Swift sürümlerinin
  (≤ 1.9) suite biçimleri tag bazında doğrulanmadı; gerçek bir Amplitude yüklü cihazda devralma **hiç denenmedi**.

## 5. Dağıtım tabanı: iOS 15 / tvOS 15 / macOS 12

Plan ve SPEC §11 bunu seçer; SPEC'te **[sor]** olarak açık duruyor ve host uygulamanın gerçek tabanı **doğrulanmadı**.
Plan bu tabanları gerekçe yazmadan seçer; aşağıdaki gerekçe geriye dönük çıkarımdır. `Package.swift`
`swift-tools-version: 6.0` (strict concurrency) kullanır ve ledger'da (Görev 5) daha yüksek OS gerektiren
`@available`/`Mutex`/`OSAllocatedUnfairLock` bilinçle **kullanılmadı** (actor tabanlı test sahtesi), yani kod tabanı
yükselmesin diye tasarlandı. host uygulamanın tabanı daha yüksekse yükseltmek kodu değiştirmez; daha düşükse (iOS 14 ve
altı) paket kurulamaz. Taban iOS 15'te çalışma zamanında **denenmedi** (§1).

## 6. Gerçek cihaz denemeleri

**Yapılmadı.** Hiçbir gerçek iPhone/iPad/Apple TV'de koşu yok. Özellikle kanıtsız: arka plana geçişte `NWPathMonitor`
ve yaşam döngüsü bildirimleri, kilitli cihazda veri koruması hatası (`deviceIdAvailable=false` yolu birim testinde
sahtelenmiş, gerçek kilit hata kodu görülmedi), gerçek IDFV, gerçek ağda gzip + 413/429 davranışı.

## 7. Bilinçli sapmalar ve bilinen açıklar

**Parity'den iki bilinçli sapma (`bir-js` ikisini de yapmıyor; JS'e bildirilecek iki hata):**
1. `identify(userId, props)` bekleyen `$set`'i **birleştirir** (çakışmada `props` kazanır). `bir-js`'te
   `takePendingProps()` nesne literalinde önce çalışıp `pendingSet`'i boşalttığından bekleyen `$set` props ile
   **ezilir**. Neden: biriktirilmiş property'lerin sessizce kaybolması (Android'de Important idi).
2. `reset()` bekleyen `$set/$set_once/$add/$unset`'i **temizler**. `bir-js` temizlemez; eski kullanıcının
   property'leri yeni anonim kimliğe yazılır (kullanıcılar arası sızıntı).

**Üçüncü JS/Android farkı:** uçuş sırasında budama koruması iOS'ta **var**, JS ve Android'de **yok**. Gönderim
sürerken kuyruk taşıp en eski satırları budarsa `removeFirst(n)` gönderilmemiş yeni satırları silerdi; iOS
`droppedCount` farkıyla yalnız hâlâ kuyrukta olan gönderilmiş satırları siler. **Kullanıcı kararıyla**
("android nasıl olduysa o şekilde olsun") JS ve Android'de düzeltilmedi; bilinçli platform farkı.

**Backoff takvimi:** SDK, SPEC'in 1/8/32/128/300 sn takvimini uygular (jitter `[0.5,1.0]`; `Retry-After` takvimin
yerine geçer). `bir-js` ikiye katlar (1, 2, 4, … 256, 300). Android iOS ile aynı, JS ayrı.

**Bilinen açıklar:**
- `erase()` ile rızanın yeniden verilmesi arasında **süreç ölürse** Amplitude devralması bir kez daha koşar
  (`migrated_from` ve `cz_app_installed` ikinci kez gidebilir). Süreç içi bayrak (`erasedInProcess`) yalnız ölmeyen
  süreçte korur; rızasızken kalıcı "unut" işareti yazılamadığı için kapatılamıyor.
- Salt-okunur dizinde `write` **ve** `remove` birlikte düşerse eski geniş rıza kaydı diskte kalır ve sonraki
  süreçte **dirilir**. Süreç içinde davranış doğru (bellek kapanır, uyarı çıkar). Uygulamanın kendi konteynerinde
  gerçekçi değil.
- `setConsent(Consent())` (üçü kapalı) **yıkıcıdır**: kuyruk, `device_id`, oturum, `user_id` silinir.
- Ertelenen Minor'lar (Görev 6/10): uçuşta budama `skipped`/`rejected` sayacını sapabilir; 1 MB sayımı `\/`
  kaçışını saymaz (413 ağı var); rıza öncesi `NWPathMonitor` başlatılması; `PropValue.from` derinlik sınırı yok.

## 8. Bu görevde bulunan, düzeltilmeyen

- **Manifest `.copy` ile paketlenmiş** (`Package.swift`). Çalışır ve arşivde görünür, ama Xcode'un standart
  yolu `.process`'tir ve gizlilik raporu/App Store doğrulaması kaynak-paket bundle'ını nasıl tarıyor
  **doğrulanmadı**. Ana paket kaynağına dokunulmadı. Öneri: Xcode'da raporu elle üretip sonuca göre karar.
- Betik tek bir iOS runtime'ı (en yüksek sürüm) seçer; iOS 15 taban sürümü hiç koşulmaz.

## 8. Attribution modülü (Görev 12)

- **IDFA iki bağımsız katmandan geçer** (Android'de reklam kimliği kimliksiz uca sızmıştı):
  1. *Kapı*: `Attribution.run` yalnız `Consent.allowsIdfa(on:)` + ATT `authorized` ise IDFA'yı **okur**;
     `att_status` yalnız `allowsAttStatus` ile okunur/yazılır.
  2. *Süzme*: çekirdekteki `AttributionBody.anonymous` kimliksiz uca (`/v1/attribution/anon`) giden gövdeden
     `idfa`, `device_id`, `user_id`, `distinct_id` anahtarlarını (büyük/küçük harf ve iç içe nesne fark etmez)
     çağıran ne verirse versin atar. Kimlikli uçta ise `device_id` çekirdeğin kendi rızasıyla (`allowsDeviceId`)
     eklenir.
- ATT izni **istenmez**; kaynakta izin isteyen çağrının adı geçmez (test tarar). ATT hukuki rıza değildir.
- **`NSPrivacyTracking` SDK'da `false`.** Takip kararı uygulamanındır: uygulama IDFA'yı kendi reklam/izleme
  amacıyla kullanıyorsa kendi manifest'inde `true` yapmalı ve `NSPrivacyTrackingDomains`'i kendisi doldurmalıdır.
  Attribution hedefinin manifest'i `DeviceID` (IDFA) ve `AdvertisingData` (AdServices token) toplanan veri
  türlerini `Linked=true`, `Tracking=false`, amaç `Analytics` olarak beyan eder.
- Kapılar (`AttributionRoute`, `allowsIdfa` vb.) iki modül arasında kullanılsın diye `package` erişimli
  (public API değil).
- tvOS: AdServices/AdAttributionKit/SKAdNetwork yok; `AdServicesToken.read()` `nil`, `TrackingStatus` `unavailable`.
- Alan adları (`adservices_token`, `att_status`, `idfa`) ve kimlikli uç yolu (`/v1/attribution`) sunucu
  sözleşmesinde henüz yazılı değil; tahmindir (bkz. Görev 12 raporu, açık sorular).
