// swift-tools-version: 5.9
import PackageDescription

// 数据层与单元测试的 SwiftPM 包。
//
// - 包根目录 = ios/；库 target 直接指向 App target 同一份源码目录
//   `PawlyDemo/Core/Data`（不复制源码，Xcode 工程仍然自动同步编译）。
// - 测试 target 在 macOS 上跑 `swift test`，用 URLProtocol stub，不连真实网络。
// - 测试目录 `Tests/` 不在 `PawlyDemo` 同步组内，不会进入 App target。
let package = Package(
    name: "DogiosDataLayer",
    platforms: [
        .iOS(.v17),
        .macOS(.v13)
    ],
    products: [
        .library(name: "DogiosDataLayer", targets: ["DogiosDataLayer"])
    ],
    targets: [
        .target(
            name: "DogiosDataLayer",
            path: "PawlyDemo/Core/Data"
        ),
        .target(
            name: "MobileSessionState",
            dependencies: ["DogiosDataLayer"],
            path: "PawlyDemo/Features/Mobile",
            exclude: ["GLBModelView.swift", "MobileAccountView.swift", "MobileRootView.swift",
                      "NearbyPetsView.swift", "PetContactsView.swift", "PetSpaceView.swift"],
            sources: ["MobileAppStore.swift"]
        ),
        .testTarget(
            name: "DataLayerTests",
            dependencies: ["DogiosDataLayer", "MobileSessionState"],
            path: "Tests/DataLayerTests"
        )
    ]
)
