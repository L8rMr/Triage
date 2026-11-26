// swift-tools-version:5.9
import PackageDescription
import Foundation

let infoPlist = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Resources/Info.plist").path

let package = Package(
    name: "Triage",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Triage",
            path: "Sources/Triage",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("QuickLookThumbnailing"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreWLAN"),
                .linkedFramework("CoreLocation"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("IOBluetooth"),
                .linkedFramework("CoreBluetooth"),
                .linkedFramework("UserNotifications"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("ScreenCaptureKit"),
                // Embed Info.plist so macOS can show permission prompts (Location, Audio) even when run from Xcode.
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", infoPlist]),
            ]
        )
    ]
)
