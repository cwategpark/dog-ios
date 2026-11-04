import SwiftUI

@main
struct PawlyDemoApp: App {
    @StateObject private var mobile = MobileAppStore()
    var body: some Scene {
        WindowGroup {
            MobileRootView().environmentObject(mobile)
        }
    }
}
