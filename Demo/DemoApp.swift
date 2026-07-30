import SwiftUI
import TransportSeamUI

/// The whole app. Everything else lives in the package, which is the point:
/// the Xcode project exists to prove the library runs on a device, not to hold
/// logic of its own.
@main
struct DemoApp: App {
    var body: some Scene {
        WindowGroup {
            TransportSeamDemoView()
        }
    }
}
