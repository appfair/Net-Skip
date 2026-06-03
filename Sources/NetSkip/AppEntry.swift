// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import OSLog
import SwiftUI

let logger: Logger = Logger(subsystem: "org.appfair.Net-Skip", category: "Browser")

/// The Android SDK number we are running against, or `nil` if not running on Android
let androidSDK = ProcessInfo.processInfo.environment["android.os.Build.VERSION.SDK_INT"].flatMap({ Int($0) })

/// The shared top-level view for the app, loaded from the platform-specific App delegates below.
///
/// The default implementation merely loads the `ContentView` for the app and logs a message.
@available(iOS 17, macOS 14.0, *)
public struct RootView : View {
    public init() {
    }

    public var body: some View {
        ContentView()
            .task {
                logger.log("Welcome to Skip on \(androidSDK != nil ? "Android" : "iOS")!")
                logger.warning("Skip app logs are viewable in the Xcode console for iOS; Android logs can be viewed in Studio or using adb logcat")
            }
    }
}

#if !SKIP
public protocol BrowserApp : App {
}

/// The entry point to the browser app — the concrete implementation
/// in the host package conforms its `@main` `App` to `BrowserApp`
/// and inherits this default body.
@available(iOS 17, macOS 14.0, *)
public extension BrowserApp {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
#endif
