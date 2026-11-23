// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MeetingRecorder",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "MeetingRecorder", targets: ["MeetingRecorder"]),
    ],
    targets: [
        .executableTarget(
            name: "MeetingRecorder",
            path: "Sources/MeetingRecorder",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreMedia"),
            ]
        ),
    ]
)
