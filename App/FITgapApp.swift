import SwiftUI
import UIKit

/// Portrait stays the rule for regular iPhones; wide displays such as an unfolded foldable may rotate.
final class OrientationDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        let size = window?.screen.bounds.size ?? UIScreen.main.bounds.size
        return min(size.width, size.height) >= 600 ? .all : .portrait
    }
}

@main
struct FITgapApp: App {
    @UIApplicationDelegateAdaptor(OrientationDelegate.self) private var delegate
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var phase

    init() {
        StartupLog.beginLaunch()
        StartupLog.mark("App init")
        StartupLog.watchMainThread()
    }

    var body: some Scene {
        WindowGroup {
            ActivitiesView(model: model)
                .onAppear { StartupLog.mark("first view appeared", once: true) }
                .task { StartupLog.measure("AppModel.start") { model.start() } }
                .onChange(of: phase) { _, value in
                    StartupLog.mark("scene \(value)", once: value == .active)
                    model.phaseChanged(value)
                }
                // "Open in FITgap" and sharing a .fit file to FITgap from Files, Mail or another app.
                .onOpenURL { url in if url.isFileURL { model.importFiles([url]) } }
        }
    }
}
