# AS-BUILT: Çizeylem iOS SDK (Görev 14 sonu)

Bu belge yapılanı ve **neyin kanıtlandığını, neyin kanıtlanmadığını** yazar. Kanıt tarihi: 2026-10-26,
Xcode 26.2 (17C52), Swift 6.2.3.

## 1. Kanıt tablosu

| İddia | Durum | Kanıt |
|---|---|---|
| Paket testleri macOS'ta geçer | kanıtlandı | `swift test` (önceki görevler) |
| Paket testleri **iOS simülatöründe** geçer | kanıtlandı | `scripts/test-simulators.sh`: iOS 26.2, iPad Air 11-inch (M3), **427 test (çekirdek 387 + attribution 40), 0 başarısızlık** (Görev 14 koşusu; önceki 379, Görev 11), `** TEST SUCCEEDED **` |
| Paket testleri **tvOS simülatöründe** geçer | **EVET** | tvOS 26.2 runtime'ı `xcodebuild -downloadPlatform tvOS` ile kuruldu, `Cizeylem Apple TV` (Apple TV 4K 3. nesil) cihazı `simctl create` ile açıldı. `./scripts/test-simulators.sh` → `tvOS: GECTI (tvOS 26.2, Cizeylem Apple TV)`, **427 test, 0 başarısızlık** (Görev 14 koşusu), `** TEST SUCCEEDED **` |
| tvOS kodu derlenir | **EVET** | Yalnız `swiftc -typecheck` değil: tvOS simülatöründe gerçekten derlendi, bağlandı ve koşturuldu (yukarıdaki satır) |
| iOS örnek uygulaması 0 uyarıyla derlenir ve arşivlenir | kanıtlandı | `xcodebuild build` ve `archive` (generic iOS, imzasız), `SWIFT_TREAT_WARNINGS_AS_ERRORS=YES` |
| iOS örneği açılır, rızasızken **diske hiçbir şey yazmaz** | kanıtlandı (tek koşu) | iPad simülatöründe taze kurulum+açılış: ekranda `running: false`, `distinctId: nil`, `queued: 0`, üç rıza `false`. Uygulama veri konteynerinde yalnız sistemin `Saved Application State` dosyaları var; `Library/Preferences`, `Application Support`, `Caches` altında SDK dosyası **yok** |
| Rıza verilince kimlik/kuyruk oluşur, `flush` gider | **denenmedi** | Düğmelere simülatörde dokunulmadı (bu ortamda dokunma otomasyonu kurulmadı). Yalnız rızasız başlangıç ekranı görüldü |
| tvOS örneği çalışır | **denenmedi** | Runtime artık kurulu; paket testleri tvOS'ta koştu ama tvOS ÖRNEK UYGULAMASI elle açılıp denenmedi |
| Privacy report | bkz. §3: **üretilemedi** | |
| Gerçek cihaz | **yapılmadı** | Hiçbir gerçek iPhone/Apple TV'de denenmedi (bkz. §6) |

Simülatör koşusu iOS 18.3 runtime'ında **yapılmadı**; betik en yüksek sürümlü iOS runtime'ını seçer. Dağıtım
tabanı olan iOS 15 hiçbir yerde çalıştırılmadı: SDK 26.2 ile derlenip `-target ios15.0` ile bağlandı, testler
iOS 26.2 çalışma zamanında koştu. Düşük sürümlerde eksik API riski (derleyici `@available` ile yakalar ama
çalışma zamanı davranışı görülmedi) kanıtsızdır.

### Betik davranışı (`scripts/test-simulators.sh`)

Çalışma zamanı varlığı `xcrun simctl list runtimes available` ile, cihaz `simctl list devices available -j`
ile seçilir; cihaz adı sabit değil. Gerçek çıktı (her iki runtime kuruluyken):

```
iOS : GECTI (iOS 26.2, iPad Air 11-inch (M3) Review)
tvOS: GECTI (tvOS 26.2, Cizeylem Apple TV)
SONUC: BASARILI
exit=0
```

Varsayılan katı: tvOS atlanırsa çıkış 1. `--allow-missing-tvos` çıkışı 0 yapar ama son satır
`KISMEN (tvOS KANITLANMADI ...)` der. tvOS runtime'ı kurulduğunda betik aynı komutla her iki platformu koşar;
Betiğin **her iki dalı da** yürütüldü: önce "runtime yok" dalı (çıkış 1, doğru davrandı), runtime
kurulduktan sonra iki platformlu dal (çıkış 0). tvOS'ta `flushAt` varsayılanı 5, iOS'ta 30
(`Platform.current`) ve tvOS dalının testleri o koşuda gerçekten görüldü.

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
- Manifest, SPM'in ürettiği kaynak paketinde (`Cizeylem_Cizeylem.bundle`) duruyor; `Package.swift` Görev 14'ten beri `.process` kullanıyor (arşiv bu bölümdeki koşuda `.copy` idi).
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
  (≤ 1.9) suite biçimleri tag bazında doğrulanmadı; gerçek bir Amplitude yüklü cihazda devralma **denendi** (2026-10-27, iPhone 11): plist yolu
  `Library/Preferences/com.amplitude.storage.amplitude-swift-storage-<amplitudeApiKey>-$default_instance.plist`
  doğrulandı, içinde `device_id` var. Deneme bir **hata** buldu: `Core` suite adını Çizeylem'in write key'iyle
  kuruyordu, yani Amplitude-Swift devralması hiç çalışmamıştı (sessiz hata). Düzeltildi (0.2.0):
  `Configuration.legacyAmplitudeApiKey` (**Amplitude'un** API anahtarı, write key değil; `nil` ise
  Amplitude-Swift suite'i taranmaz, ObjC SQLite yolu yine denenir).

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
  kaçışını saymaz (413 ağı var); rıza öncesi `NWPathMonitor` başlatılması; (`PropValue.from` derinlik sınırı Görev 14'te eklendi, §9).

## 8. Bu görevde bulunan, düzeltilmeyen

- ~~Manifest `.copy` ile paketlenmiş~~ → **Görev 14'te `.process`'e çevrildi** (bkz. §9, kalem 7).
- Betik tek bir iOS runtime'ı (en yüksek sürüm) seçer; iOS 15 taban sürümü hiç koşulmaz.

## 8b. Attribution modülü (Görev 12)

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

## 9. Görev 14: CI, yayın ve biriken triyaj

CI ve yayın ayrıntısı: `docs/RELEASE.md`. Kısaca: `.github/workflows/ci.yml` (iki iş), test sayısı alt
sınırı `scripts/test-floor.env` + `scripts/check-test-count.sh`, tvOS runtime/cihaz hazırlığı
`scripts/prepare-simulator.sh`. **Workflow GitHub'da henüz koşmadı** (yalnız betikler yerelde koştu).

**`Sources/spec-adapter/` yazılmadı:** karşı taraf `bir-js/spec/` (S5) yok; sözleşmeyi tahmin edip kodlamak
yanlış sözleşmeyi sabitlerdi. Kabul kriteri SPEC §9'a göre birim testlerdir. S5 gelince ayrı commit.

Önceki görevlerden taşınan sekiz triyaj kalemi:

| # | Kalem | Karar |
|---|---|---|
| 1 | `LIB_VERSION` gerçek enjeksiyonu | **Açık (bilinçli).** SPM'de derleme anı değer enjeksiyonu yok; yalnız derleme eklentisi ya da üretilmiş kaynak ile olur, ikisi de sıfır araç/bağımlılık kuralına ve paket sadeliğine ters. Koruma: `VERSION` dosyası + `testLibVersionSurumKaynagiylaAyni` + CI "Sürüm tutarlılığı" adımı (tag ise tag == `VERSION` da). Elle iki yer güncellenir (RELEASE.md). |
| 2 | Rıza kaydının süreçler arası dirilişi (`write` ve `remove` birlikte düşerse) | **Açık, kapatılamaz.** Dizine ne yazılabiliyor ne silinebiliyorsa "silindi" işareti de yazılamaz; kalıcı bir tombstone aynı başarısız yazıma muhtaç. Süreç içinde davranış doğru (bellek kapanır, uyarı çıkar); yalnız sonraki süreçte eski geniş kayıt dirilir. Uygulamanın kendi konteynerinde gerçekçi değil (§7'de zaten vardı). |
| 3 | `Dispatcher` iç uyarıları `logger`'a bağlı değil | **Düzeltildi.** `Dispatcher.init(log:)` (varsayılan `nil`), Core `Configuration.logger`'ı `[cizeylem]` önekiyle geçirir. Üç veri kaybı yolunda bir satır yazar: okunamayan satır silindi, sunucu 400 ile reddetti, tek event 413. 401/403 uyarısı Core'da zaten vardı (çift yazılmaz). Test: `testOkunamayanSatirSilinirkenLoggerYazar`. |
| 4 | Yaşam döngüsü okunamazlığı `stats()`'ta görünmüyor | **Açık.** `LifecycleObserver.launch` içinde `.unreadable` sessizce dönüyor (karar verilmez, üzerine yazılmaz; bu bilerek). Görünür kılmak `Stats`'a genel bir alan eklemek (public API değişikliği) ve statik `launch`'tan Core'a bir geri bildirim yolu demek; 1.0 öncesi API kararı olduğundan bu görevde alınmadı. Etki: okunamayan durumda `cz_app_installed/updated` üretilmez, kullanıcı tarafında yalnız eksik sayım. |
| 5 | `beginBackgroundTask`: arka plan flush'ı yarım kalabilir | **Açık.** `cz_app_backgrounded` sonrası flush ağda iken sistem süreci askıya alabilir; kuyruk diskte durduğundan event kaybolmaz, sonraki açılışta gider (en kötü ihtimalle gecikir). `UIApplication.beginBackgroundTask` eklemek kalem 6'daki extension sorununu büyütür (aynı `UIApplication.shared` bağımlılığı) ve gerçek cihazda doğrulanamıyor (§6). Gerçek cihaz denemesinde ölçülüp karar verilmeli. |
| 6 | App extension uyumu | **Açık, gerçek risk (kanıtlandı).** `Sources/Cizeylem/Cizeylem.swift:41` `UIApplication.shared.applicationState` kullanır. Yeniden üretim: `xcrun --sdk iphonesimulator swiftc -typecheck -application-extension -target arm64-apple-ios15.0-simulator -package-name cz -module-name Cizeylem Sources/Cizeylem/*.swift Sources/Cizeylem/Internal/*.swift -swift-version 6` → `'shared' is unavailable in application extensions for iOS`. Yani `Cizeylem` bir app extension hedefine bağlanırsa (Share/Widget/Notification Service) **derlenmez**. Sürüm notunda ve entegrasyon belgesinde "extension desteklenmez" yazılmalı. Düzeltme (başlangıç durumunu `UIApplication` yerine bildirim sırasından okumak ya da extension'da koşulsuz `startsActive=false`) davranış değişikliği olduğundan ve extension'da `LifecycleObserver`'ın anlamı belirsiz olduğundan bu görevde yapılmadı. Ayrıca extension ayrı konteyner kullandığı için `Library/Caches` altındaki kuyruk ana uygulamayla paylaşılmaz (§7 / ledger "süreçler arası kilit" kararı). |
| 7 | Privacy manifest `.copy` vs `.process` | **Düzeltildi (kısmen doğrulandı).** `Package.swift` iki hedefte de `.process` kullanıyor (Apple'ın belgelediği biçim). Doğrulandı: iOS ve tvOS simülatör derlemesinde `Cizeylem_Cizeylem.bundle/PrivacyInfo.xcprivacy` kaynağıyla **bayt bayt aynı**; testler geçti. **Doğrulanmadı:** Xcode'un "Generate Privacy Report" ve App Store doğrulamasının bu bundle'ı nasıl okuduğu (arayüz gerekir; RELEASE.md kontrol listesinde elle adım). Arşiv bu görevde yeniden alınmadı. |
| 8 | `PropValue`/`EventJSON.sanitize` tekrarı ve derinlik sınırı | **Derinlik sınırı düzeltildi, tekrar açık.** `PropValue.from` artık 32 düzeyde keser (aşan alt ağaç `null`); sınırsız özyineleme ev sahibi yığınını taşırıp süreci çökertebilirdi. Test: 2000 düzeyli yapı çökmez, tam `maxDepth+1` düzey korunur; sınır altı yapı aynen kalır. `EventJSON.sanitize` hâlâ ayrı bir kopya ve **derinlik sınırı yok**: üretim yolunda her zaman `PropValue.json`'dan geçen değer alır (zaten sınırlı), yalnız doğrudan çağrılırsa sınırsız. İki mantığı birleştirmek test ağırlıklı bir refaktör; tel biçiminin tek yazarı `EventJSON` kaldığı için risk düşük, ertelendi. Sınırı aşan değerin sessizce `null` olması bilinçli ve belgeli. |

**CI'nın kanıtlamadıkları:** workflow GitHub'da koşmadı; `macos-26` imajı/Xcode sürümü, runner'da tvOS
indirme süresi, iOS 15 çalışma zamanı, gerçek cihaz. Test sayısı kapısı "kaybolmadı"yı kanıtlar, "doğru"yu değil.
