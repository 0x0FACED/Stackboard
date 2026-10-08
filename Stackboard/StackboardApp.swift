import SwiftUI

@main
struct StackboardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appController = AppController.shared

    init() {
        AppDelegate.enforceSingleInstance()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarMenuView(appController: appController)
        } label: {
            Image(nsImage: StatusBarIcon.menuBarImage)
                .accessibilityLabel("Stackboard")
        }
        .menuBarExtraStyle(.window)

        Settings {
            EmptyView()
        }
    }
}
    
