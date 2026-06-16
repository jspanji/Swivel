// Re-export the system frameworks the public/internal API surfaces, so a
// `@testable import SwivelCore` brings them along. This also lets the test
// target avoid importing Foundation directly alongside swift-testing — which
// triggers a cross-import overlay that isn't fully present in a Command Line
// Tools-only toolchain.
@_exported import Foundation
@_exported import SwiftUI
