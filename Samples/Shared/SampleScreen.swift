import SwiftUI

/// Tek ekran: üç rıza anahtarı, altı eylem, `stats()` çıktısı ve SDK günlüğü.
struct SampleScreen: View {
    @ObservedObject var model: SampleModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Çizeylem örnek").font(.title2).bold()

                Toggle("analytics", isOn: $model.analytics)
                Toggle("attribution", isOn: $model.attribution)
                Toggle("adSharing", isOn: $model.adSharing)

                Button("Rızayı uygula (setConsent)") { model.pushConsent() }

                HStack {
                    Button("track") { model.track() }
                    Button("identify") { model.identify() }
                    Button("reset") { model.reset() }
                    Button("flush") { model.flush() }
                }
                HStack {
                    Button("setOptOut(true)") { model.setOptOut(true) }
                    Button("setOptOut(false)") { model.setOptOut(false) }
                    Button("stats yenile") { model.scheduleRefresh() }
                }

                Text("distinctId: \(model.distinctId)")
                Text(model.stats).font(.system(.footnote, design: .monospaced))

                Text("Günlük").font(.headline)
                ForEach(Array(model.log.enumerated()), id: \.offset) { _, line in
                    Text(line).font(.system(.caption, design: .monospaced))
                }
            }
            .padding()
        }
        .task {
            // Zamanlayıcı/arka plan etkileri (gönderim, gerileme) ekranda görünsün.
            while !Task.isCancelled {
                await model.refresh()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }
}
