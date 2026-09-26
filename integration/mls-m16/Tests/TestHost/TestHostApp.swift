import SwiftUI

/// Test host only: gives hosted XCTest bundles a simulator Keychain identity.
@main
struct TestHostApp: App {
    var body: some Scene { WindowGroup { EmptyView() } }
}
