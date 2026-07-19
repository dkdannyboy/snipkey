// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SnipKey",
    // 현지화된 리소스(.lproj)가 있으면 SwiftPM이 기본 언어를 요구한다. en을 기준으로
    // 삼아, 지원하지 않는 시스템 언어에서도 영어로 안전하게 떨어지게 한다.
    defaultLocalization: "en",
    platforms: [.macOS(.v13)],
    targets: [
        // Core logic: models, storage, TextExpander import, macro parsing.
        // Kept UI-free so it is unit-testable.
        .target(name: "SnipKeyKit"),
        // The menu bar application.
        .executableTarget(
            name: "SnipKey",
            dependencies: ["SnipKeyKit"],
            // en/ko/ja Localizable.strings. .process가 .lproj를 현지화 리소스로 인식해
            // Bundle.module 안에 언어별로 넣는다. 즉시-전환은 이 번들에서 lproj를 직접
            // 골라 읽는다(LocalizationManager 참고).
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "SnipKeyKitTests",
            dependencies: ["SnipKeyKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
