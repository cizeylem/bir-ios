# bir-ios

Çizeylem'in iOS, tvOS ve macOS için native Swift analitik SDK'sı: olay toplama, oturum, dayanıklı kuyruk,
rıza yönetimi ve isteğe bağlı attribution. Davranışı web/JS SDK'sıyla aynıdır; alan adları Android SDK'sıyla
([`cizeylem/bir-android`](https://github.com/cizeylem/bir-android)) ortaktır.

- **Sıfır bağımlılık**: yalnız Apple sistem framework'leri.
- Swift 6, strict concurrency.
- Her hedefte Privacy Manifest.

> **1.0 öncesi.** Sürüm `0.x` iken küçük sürümlerde kırıcı değişiklik olabilir (bkz. [Sürümleme](#sürümleme)).

## Desteklenen platformlar

| Platform | En düşük sürüm |
|---|---|
| iOS / iPadOS | 15.0 |
| tvOS | 15.0 |
| macOS | 12.0 |

Swift 6 araç zinciri gerekir (`swift-tools-version: 6.0`). Testler iOS ve tvOS simülatöründe ve macOS'ta koşar;
iOS 15 / tvOS 15 çalışma zamanında henüz koşulmadı ([`docs/AS-BUILT.md`](docs/AS-BUILT.md) §1, §5).

## Kurulum (Swift Package Manager)

**Xcode:** *File > Add Package Dependencies…* → adres `https://github.com/cizeylem/bir-ios` → kural
*Up to Next Minor Version*, `0.2.0` (1.0 öncesinde; bkz. [Sürümleme](#sürümleme)). Ardından hedefinize
gereken ürünü (aşağıda) ekleyin.

**`Package.swift`:**

```swift
dependencies: [
    .package(url: "https://github.com/cizeylem/bir-ios", from: "0.2.0"),
],
targets: [
    .target(
        name: "Uygulamam",
        dependencies: [
            .product(name: "Cizeylem", package: "bir-ios"),
            // Attribution isteniyorsa:
            // .product(name: "CizeylemAttribution", package: "bir-ios"),
        ]
    ),
]
```

`from:` SwiftPM'de `0.2.0 ..< 1.0.0` aralığıdır, yani `0.3.0` gibi kırıcı olabilecek bir `0.x` sürümünü de
kabul eder. 1.0 öncesinde buna karşı korunmak için `.package(url: "https://github.com/cizeylem/bir-ios",
.upToNextMinor(from: "0.2.0"))` kullanın.

CocoaPods trunk'a yayın **yapılmaz**; dağıtım yalnız SPM ve git tag'idir (bkz. [`docs/RELEASE.md`](docs/RELEASE.md)).

## İki ürün: hangisini eklemeli?

| Ürün | İçerik | Ne zaman |
|---|---|---|
| `Cizeylem` | Çekirdek: kuyruk, taşıma, kimlik, oturum, rıza, context, yaşam döngüsü olayları, deep link | Her zaman |
| `CizeylemAttribution` | AdServices token, ATT durumu, IDFA, SKAN/AAK dönüşüm değeri yazıcısı | Yalnız reklam attribution'ı gerekiyorsa |

`CizeylemAttribution` çekirdeğe bağımlıdır, tek başına kullanılmaz. Kendi Privacy Manifest'i **IDFA
(`DeviceID`) ve `AdvertisingData` beyanı taşır**; bu beyan çekirdekte yoktur. Yani yalnız analitik
istiyorsanız Attribution'ı eklemeyin: uygulamanız IDFA beyanı devralmaz. tvOS'ta AdServices,
AdAttributionKit ve SKAdNetwork yoktur; ürün derlenir ama bu sinyalleri üretmez.

## Kullanım

`initialize` **ana thread'den** (`@MainActor`) ve uygulama açılışında bir kez çağrılır. Rıza **varsayılan
olarak kapalıdır**: `setConsent` çağrılmadan ne kalıcı kimlik yazılır ne de olay gönderilir.

```swift
import Cizeylem
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        Cizeylem.initialize(Configuration(writeKey: "ck_w_..."))
        // Değeri kendi rıza ekranınızdan getirin.
        Cizeylem.setConsent(Consent(analytics: true))
        return true
    }
}
```

```swift
Cizeylem.track("sepete_eklendi", ["urun_id": "42"])
Cizeylem.identify("kullanici-123")
```

SwiftUI'de deep link'i SDK'ya verin; yalnız `utm_*`, `click_id` ve `campaign_ids` okunur, tam URL gönderilmez:

```swift
WindowGroup {
    ContentView()
        .onOpenURL { Cizeylem.handleDeepLink($0) }
}
```

`initialize` dışındaki hiçbir çağrı `await` istemez ve çağıranı bloklamaz. `initialize` çağrılmadan yapılan
çağrılar sessizce yok sayılır.

**Genel API:** `Cizeylem.initialize` · `track` · `identify` · `setUserProperties` · `setUserPropertiesOnce` ·
`addUserProperties` · `unsetUserProperties` · `sendUserProperties` · `setConsent` · `setOptOut` ·
`handleDeepLink` · `flush` · `reset` · `distinctId()` · `stats()` — ve `Configuration`, `Consent`, `Stats`.

Çalışan bir örnek için [`Samples/`](Samples) (iOS ve tvOS örnek uygulamaları).

### Attribution

```swift
import Cizeylem
import CizeylemAttribution

// Rıza değiştiğinde yeniden çağrılır: `consent` o anki rızanın kopyasıdır.
let consent = Consent(analytics: true, attribution: true, adSharing: false)
Cizeylem.setConsent(consent)
Attribution.start(sink: Cizeylem.attributionSink, consent: consent)
```

- SDK ATT iznini **istemez**, yalnız durumu okur. İzni ve sırasını uygulama yönetir: önce uygulama içi rıza
  ekranı, sonra ATT, o da yalnız `adSharing` verildiyse. ATT hukuki rıza yerine geçmez.
- IDFA yalnız ATT `authorized` **ve** `Consent(analytics: true, attribution: true, adSharing: true)` iken
  okunur. Rıza yokken AdServices token'ı kimliksiz uca gider; o gövdede `device_id` ve IDFA bulunmaz.
- SKAN/AAK dönüşüm değeri yazıcısı **varsayılan kapalıdır**; `Attribution.enableConversionWriter(schemaURL:)`
  ile açıkça açılır. Başka bir MMP (ör. AppsFlyer) değeri yazıyorsa açmayın: iki yazıcı postback'i bozar.

## Rıza modeli

`Consent(analytics:attribution:adSharing:)`: üç anahtar, üçü de varsayılan `false`, kalıcı, geri alınabilir.

| Durum | SDK davranışı |
|---|---|
| Rıza yok | Kalıcı kimlik yazmaz, olay göndermez. Yalnız SKAN/AAK değer güncelleme (açıldıysa) ve AdServices token'ı kimliksiz `/v1/attribution/anon` ucuna |
| `analytics` | Normal analitik |
| `+ attribution` | Attribution sinyali `device_id` ile |
| `+ adSharing` | `att_status` her olayda; IDFA yalnız ATT `authorized` ise |

Üç anahtar birden kapatılınca kuyruk, `device_id`, oturum ve `user_id` diskten silinir.

## Gizlilik

- Her iki hedef de kendi `PrivacyInfo.xcprivacy` dosyasını taşır ve paketle birlikte uygulamanıza girer.
- **`Cizeylem` (çekirdek):** `NSPrivacyTracking = false`, tracking domain yok, toplanan veri türü beyanı yok;
  yalnız `NSPrivacyAccessedAPICategoryUserDefaults`, sebep `CA92.1`. Sistem açılış süresi ve disk alanı
  API'leri kullanılmaz.
- **`CizeylemAttribution`:** `DeviceID` (IDFA) ve `AdvertisingData` (AdServices token) toplanan veri türlerini
  `Linked = true`, `Tracking = false`, amaç `Analytics` olarak beyan eder.
- Takip kararı uygulamanındır: IDFA'yı kendi reklam/izleme amacınızla kullanıyorsanız **kendi** manifest'inizde
  `NSPrivacyTracking`'i `true` yapın ve `NSPrivacyTrackingDomains`'i doldurun.
- IP+UA parmak izi hiçbir yerde üretilmez. IDFV `device_id` olarak kullanılmaz ve sunucuya gitmez; yalnız
  yedekten geri yüklenmiş kimliği tespit etmek için yerel bir özeti tutulur.

## Amplitude'dan geçiş

`Configuration(legacyAmplitude: true)` (varsayılan) mevcut Amplitude `device_id`'sini **salt okuma** ile
devralır; Amplitude kaydı silinmez ya da değiştirilmez. Amplitude-Swift deposunu bulabilmesi için
`legacyAmplitudeApiKey`'e **Amplitude'un** API anahtarını verin (Çizeylem write key'i değil).
Ayrıntı: [`docs/SPEC.md`](docs/SPEC.md) §6.

## Sürümleme

- Semver, **öneksiz** tag: `0.2.0`, `1.0.0-beta.1` (`v` öneki yok). Güncel sürüm: depo kökündeki
  [`VERSION`](VERSION) dosyası.
- `1.0.0`'a kadar küçük sürümde (`0.x`) kırıcı değişiklik olabilir. SwiftPM `0.x`'i özel ele almaz:
  `from: "0.2.0"` `1.0.0`'a kadar her sürümü kabul eder; kırıcı değişikliği bilinçli almak için
  `.upToNextMinor(from:)` kullanın.
- İki ürün aynı depodan, aynı sürümle çıkar. Sürüm notları GitHub Releases'tadır.

## Belgeler

- [`docs/SPEC.md`](docs/SPEC.md): şartname (protokol, context alanları, rıza, kimlik, attribution)
- [`docs/AS-BUILT.md`](docs/AS-BUILT.md): yapılan ve kanıtlanan/kanıtlanmayan
- [`docs/RELEASE.md`](docs/RELEASE.md): yayın süreci

## Lisans

[Apache License 2.0](LICENSE). Ayrıca bkz. [`NOTICE`](NOTICE).
