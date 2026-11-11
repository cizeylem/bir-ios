# bir-ios — SDK şartnamesi

Kaynak: ClickUp Doc [Mobil SDK + MMP planı](https://app.clickup.com/6653229/docs/6b19d-8375)
sayfa "1 · SDK şartnamesi" (§4) ve "2 · SDK promptları" (SJ / SJ-A / SK);
`cizeylem-1/docs/PROTOCOL.md`; `cizeylem-1/docs/ARASTIRMA-MOBIL-CIHAZ-VERISI.md` §2.14, §3, §5, §6.1.
Referans davranış: `cizeylem/bir-js` → `packages/core/src/client.ts`.

Bu dosya planın dayandığı sözleşmedir. Plan ile birlikte okunur.
Android eşi `cizeylem/bir-android` → `docs/SPEC.md`; **alan adları ikisinde aynıdır.**

## 0. Amaç

Mevcut AppsFlyer/Amplitude kurulumlarından Çizeylem'e geçiş için native Swift analitik
SDK'sı: iOS + tvOS + macOS. Davranış web/JS SDK'sıyla **birebir aynı**.

## 1. Paketler

| SPM ürünü | İçerik |
|---|---|
| `Cizeylem` | Çekirdek: kuyruk, taşıma, kimlik, oturum, rıza, context, yaşam döngüsü |
| `CizeylemAttribution` | Opt-in: AdServices token, ATT durumu, IDFA, SKAN/AAK yazıcı |

- **Sıfır bağımlılık** (yalnız Apple sistem framework'leri).
- Swift 6, strict concurrency.
- `Package.swift` depo kökünde; tag **öneksiz** (`1.0.0-beta.1`).
- **CocoaPods trunk kullanılmaz** (2 Ara 2026'da kapanıyor); gerekirse repoda `:git`/`:tag` podspec.
- Privacy Manifest her hedefte.

## 2. Protokol (PROTOCOL.md v1)

- `POST {endpoint}/v1/batch`, `Authorization: Bearer ck_w_…`, `Content-Encoding: gzip`.
- Varsayılan endpoint `https://in.cizeylem.com`.
- Gövde: `{sent_at, events:[{event, distinct_id, time, insert_id, session_id, props?,
  $set?, $set_once?, $unset?, $add?, context}]}`.
- `insert_id` retry'da **değişmez** (dedup anahtarı).
- Batch sınırı: 500 event / 1 MB sıkıştırılmış.
- Yanıtlar: `200` sil · `400` at, retry etme · `401`/`403` SDK'yı durdur ·
  `413` batch'i böl · `429` `Retry-After` kadar bekle · `5xx` backoff.
- `$identify`: `distinct_id` (eski anonim) + `user_id`; sonrası `distinct_id = user_id`.
- `reset()`: yeni anonim UUID, sunucuya çağrı yok.

## 3. §4 şartname

| Konu | iOS / macOS | tvOS |
|---|---|---|
| Kurulum | `init("ck_w_…")` tek satır | aynı |
| Kuyruk | Dosya, `.tmp` → atomik rename; Application Support; ≤ 1.000 event / 5 MB | **Caches**; ≤ 100 event |
| Flush | 30 event · 30 sn · arka plana geçiş | **5 event** · 30 sn · arka plana geçiş |
| Retry | 1 / 8 / 32 / 128 / 300 sn, ±%50 jitter; 5xx'te asla düşürme; 413 böl; 401 dur; 429 30 sn | aynı |
| device_id | Rastgele UUID v4; Application Support dosyası + `isExcludedFromBackup` + IDFV yerel özeti | **UserDefaults** (+ aynı IDFV kontrolü) |
| Oturum | `session_id` = oturum başlangıcının epoch ms'i (string); 30 dk hareketsizlik → yeni oturum | aynı |
| Yaşam döngüsü | `cz_app_installed{existing_install}` · `cz_app_updated` · `cz_app_opened` · `cz_app_backgrounded` | aynı |
| Deep link | `handleDeepLink(url)` → `cz_deep_link_opened`; yalnız `utm_*` + `click_id` + Meta `campaign_ids` | aynı |
| Rıza | `setConsent(analytics:attribution:adSharing:)`; **üçü de varsayılan kapalı** | aynı |
| Amplitude devralma | **Salt okuma**; geçersiz değer listesi; `$set_once {migrated_from}` | aynı |
| Gönderilmez | Sistem açılış süresi, disk alanı | aynı |

**Prewarm tuzağı:** veri koruması kapalıyken (cihaz kilidi hiç açılmamış) **yeni kimlik
üretilmez**. Üretilirse her prewarm yeni bir "kullanıcı" yaratır.

**Yedek tespiti:** kimliğin yanında IDFV'nin **yerel** özeti tutulur. Açılışta IDFV farklıysa
kimlik yedekten gelmiştir → yeni id. IDFV **sunucuya gitmez**.
IDFV, cihaz yeniden başladıktan sonra ilk kilit açılana kadar `nil` dönebilir; o açılışta
yedek kontrolü **atlanır**, kimlik üretimi IDFV'yi beklemez.

## 4. Context alanları (ARASTIRMA §5.1 / §5.2)

Mevcut (PROTOCOL §2): `platform`, `app_version`, `os_name`, `os_version`, `device_model`,
`device_type`, `locale`, `timezone`, `screen_width`, `screen_height`.

Eklenenler (S1 ile sunucuya girecek; o gelene kadar gönderilir ama **saklanmaz**):

| Alan | Değer kümesi |
|---|---|
| `lib` | `bir-ios` |
| `lib_version` | semver |
| `app_build` | `CFBundleVersion` |
| `device_manufacturer` | `Apple` |
| `network_type` | `wifi` · `cellular` · `ethernet` · `offline` · `other` |
| `install_source` | `app_store` · `testflight` · `marketplace` · `dev` · `unknown` |
| `app_state` | `foreground` · `background` |
| `platform` | `ios` · `tvos` · `macos` |
| `device_type` | `mobile` · `tablet` · `tv` · `desktop` |
| `os_name` | `iOS` · `iPadOS` · `tvOS` · `macOS` |
| `att_status` | `authorized` · `denied` · `restricted` · `not_determined` · `unavailable` (S3) |
| `consent_scope` | verilen rıza anahtarları (S3) |

`screen_width`/`screen_height`: **pt**, doğal yöne normalize.
`device_model`: ham model kodu (`iPhone17,3`); pazarlama adı sunucuda.

## 5. Rıza modeli

`setConsent(analytics:attribution:adSharing:)` — üçü varsayılan `false`, kalıcı, geri alınabilir.

| Durum | SDK davranışı |
|---|---|
| Rıza yok | Kalıcı kimlik **yazmaz**, event **göndermez**. Yalnız: SKAN/AAK değer güncelleme · AdServices token'ı kimliksiz `/v1/attribution/anon`'a |
| `analytics` | Normal analitik |
| `+ attribution` | Token `device_id` ile |
| `+ adSharing` | `att_status` her event'te; IDFA yalnız ATT `authorized` ise okunur |

**ATT sırası (K7):** önce uygulama içi rıza ekranı, sonra ATT — ve yalnız `adSharing`
verildiyse. ATT hukuki rıza **değildir**. SDK ATT izni **istemez**, yalnız durumu okur.

İlke: **parmak izi (IP+UA eşleşmesi) hiçbir yerde yazılmaz.**

## 6. Kimlik ve Amplitude devralma (ARASTIRMA §3)

device_id = rastgele UUID v4. IDFV device_id **olmaz** (vendor genelinde paylaşılır,
`reset()` onu değiştiremez).

Devralma sırası (salt okuma, ilk bulan kazanır):
1. Açık `Configuration(deviceId:)`
2. Kendi depomuz
3. Amplitude-Swift UserDefaults suite'i
   `com.amplitude.storage.amplitude-swift-storage-<apiKey>-<instance>`
4. Eski SQLite `Library/com.amplitude.database`, tablo `store`, anahtar `device_id`
5. Yeni UUID

Geçersiz değerler elenir: `""`, `unknown`, `000000000000000`, sıfır-UUID.
Devralma olduysa `$set_once {migrated_from}` + `cz_app_installed{existing_install: true}`.
Amplitude'un `optOut` değeri korunur. Amplitude kaydı **silinmez/değiştirilmez**.

## 7. Privacy Manifest (ARASTIRMA §6.1)

- `NSPrivacyTracking = false`
- `NSPrivacyTrackingDomains` **boş** — ingest alanı tracking domain değil
- `NSPrivacyAccessedAPITypes`: `NSPrivacyAccessedAPICategoryUserDefaults`, sebep **`CA92.1`**
- Sistem açılış süresi ve disk alanı API'leri **kullanılmaz** (dolayısıyla beyan da yok)
- Xcode privacy report çıktısı depoda (`docs/AS-BUILT.md`)

## 8. Attribution modülü (SJ-A, §5.2)

| Sinyal | Kural |
|---|---|
| AdServices token | `attributionToken()`, `#if !os(tvOS)`; sunucu çözer. Rıza yoksa kimliksiz uca |
| ATT durumu | **Okunur**, istenmez. `att_status` alanına yazılır |
| IDFA | Yalnız ATT `authorized` **ve** `adSharing` |
| SKAN / AAK yazıcı | İlk açılışta `updateConversionValue`; uzaktan, sürümlü JSON şema; fine/coarse/lockWindow. **Varsayılan KAPALI** — paralel testte AppsFlyer yazar (K8) |

tvOS'ta AdServices / AdAttributionKit / SKAdNetwork **yoktur**.

### 8.1 Uçlar ve adresler (sunucu sözleşmesi: cizeylem-1 `docs/PROTOCOL.md` §9)

| İstek | Gövde | Adres |
|---|---|---|
| `POST /v1/batch` | olaylar (IDFA yok) | `endpoint` (`in.cizeylem.com`) |
| `POST /v1/attribution/anon` | `adservices_token` (kimlik süzülür) | `endpoint` |
| `POST /v1/attribution`, IDFA yok | `device_id`, `adservices_token`, `att_status` | `endpoint` |
| `POST /v1/attribution`, IDFA var | `device_id`, `adservices_token`, `att_status`, `idfa` | `trackingEndpoint` (`attr.cizeylem.com`) |

Kural: adresi rota değil **oluşan gövde** belirler (`AttributionBody.carriesIdfa`). Gövde tek düz JSON
nesnesidir, gzip'lenir, yetki `Authorization: Bearer <write_key>`. Sunucu sinyali `$attribution` olayı
olarak saklar. İzleme adresi ayrıdır çünkü iOS 17+ `NSPrivacyTrackingDomains`'teki host'ları ATT izni
vermemiş kullanıcıda engeller; uygulama listeye yalnız `trackingEndpoint` host'unu yazar (README).

## 9. Kabul kriterleri

- [ ] Birim testler yeşil (iOS + tvOS simülatörü)
- [ ] S5 gelince `bir-js/spec/` adaptörü yeşil
- [ ] Xcode privacy report çıktısı depoda
- [ ] Öneksiz SPM tag yayınlandı (`1.0.0-beta.1`)
- [ ] Pilot uygulama PR'ı: yayınlanmış tag'e bağlı, event'ler test projesinde
      görünüyor, eski `device_id` korunmuş (merge + canlı Doğukan'da)

## 10. Bizde olmayanlar (Doğukan'ı bekleyen)

| Ne | Etkisi |
|---|---|
| Test projesi + `ck_w_` write key | Canlı sunucuya deneme gönderilemez |
| S1 — mobil context kolonları | §4 alanları gönderilir, sunucuda saklanmaz |
| S3 — `context.consent` / `att_status` | Context alanları sunucuda ayrı saklanmaz. (`/v1/attribution` ve `/v1/attribution/anon` uçları 0.3.0 ile sunucuda var) |
| S5 — ortak test seti `bir-js/spec/` | "spec yeşil" yerine birim testler |
| `research_notes/…` (sdk_engineering.md, apple_platform.md) | Doğukan'ın makinesinde; gerekirse istenecek |

## 11. Açık noktalar

- **[doğrula]** Amplitude-Swift UserDefaults suite adının `<instance>` eki.
- **[sor]** macOS hedefi şartnamede var ama kabul kriterlerinde ve pilotta yok.
  Bu planda derlenir ve birim testleri çalışır; örnek uygulama ve pilot yalnız iOS + tvOS.
- **[sor]** Dağıtım tabanı: plan `iOS 15 / tvOS 15 / macOS 12` seçiyor. Host uygulamanın
  bugünkü tabanı bunun üstündeyse yükseltilir.
