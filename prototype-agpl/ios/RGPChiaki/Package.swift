// swift-tools-version:5.9
// PRIVATE PROTOTYPE — NOT FOR DISTRIBUTION. This package links the AGPL chiaki-ng library.
import PackageDescription

let package = Package(
    name: "RGPChiaki",
    platforms: [.iOS(.v17)],
    products: [.library(name: "RGPChiaki", targets: ["RGPChiaki"])],
    dependencies: [.package(path: "../../../Packages/RGPCore")],
    targets: [
        // Built by ../build-ios-libs.sh and ../make-xcframework.sh; not checked in.
        .binaryTarget(name: "Chiaki", path: "Chiaki.xcframework"),
        .target(name: "CChiakiShim", dependencies: ["Chiaki"],
                cSettings: [.define("CHIAKI_LIB_ENABLE_MBEDTLS")],
                // The library's HTTPS client uses Apple's Secure Transport.
                linkerSettings: [.linkedFramework("Security"), .linkedFramework("SystemConfiguration"),
                                 .linkedFramework("CoreFoundation")]),
        .target(name: "RGPChiaki", dependencies: [
            "CChiakiShim",
            .product(name: "RGPCore", package: "RGPCore"),
            .product(name: "RGPPS5", package: "RGPCore"),
        ]),
    ]
)
