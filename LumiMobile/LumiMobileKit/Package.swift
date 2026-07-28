// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LumiMobileKit",
    // macOS 14 desteği testlerin Mac host'ta simülatörsüz koşması içindir;
    // UIKit/VisionKit bağımlılığı bu pakete giremez.
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "LumiMobileKit", targets: ["LumiMobileKit"])
    ],
    targets: [
        .target(name: "LumiMobileKit"),
        .testTarget(name: "LumiMobileKitTests", dependencies: ["LumiMobileKit"]),
    ]
)
