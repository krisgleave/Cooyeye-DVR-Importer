// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "CooyeyeImporter",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "CooyeyeImporter", targets: ["CooyeyeImporter"])],
    targets: [.executableTarget(name: "CooyeyeImporter", resources: [.copy("Resources/cooyeye_backend.py"), .copy("Resources/cooyeye_client.py")])]
)
