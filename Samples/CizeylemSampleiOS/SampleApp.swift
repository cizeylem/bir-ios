import Cizeylem
import SwiftUI
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // `startsActive` tuzağı: burada `applicationState == .inactive`. SDK bunu "ilk
        // cz_app_opened kaçırılmadı" diye okur ve hemen ardından gelen didBecomeActive
        // bildirimi event'i üretir. `initialize` `@MainActor`; delegate zaten ana aktörde.
        Cizeylem.initialize(SampleConfig.make())
        return true
    }
}

@main
struct SampleApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            SampleScreen(model: SampleModel.shared)
                .onOpenURL { Cizeylem.handleDeepLink($0) }
        }
    }
}
