import Cizeylem
import SwiftUI
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // iOS örneğiyle aynı gerekçe: `didFinishLaunching` sırasında durum `.inactive`.
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
