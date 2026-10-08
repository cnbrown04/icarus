import UIKit
import SyncKit

/// Only the background URLSession hook is needed. SwiftUI owns the rest of the lifecycle.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == BackgroundUploader.identifier else {
            completionHandler()
            return
        }
        BackgroundUploader.handleEvents(completion: completionHandler)
    }
}
