# CoastPlay PRO — source code

CoastPlay PRO is an iPhone app for playing your own PlayStation 5 remotely. It is not made,
endorsed or supported by Sony.

This app uses [chiaki-ng](https://github.com/streetpea/chiaki-ng) (version 1.10.1), which is
licensed under the GNU Affero General Public License, version 3, with an OpenSSL exception.
This whole app is therefore offered under the same licence: see `LICENSE`.

## What is here
- `App/` — the iPhone app (SwiftUI).
- `Packages/RGPCore/` — shared logic, the computer-mirroring protocol and the Mac host, with tests.
- `prototype-agpl/` — the bridge to chiaki-ng and the Xcode project.

## Building
Needs a Mac with Xcode 26 or later, CMake and Python 3.
1. `git clone --branch v1.10.1 --recursive https://github.com/streetpea/chiaki-ng prototype-agpl/chiaki-ng`
2. `cd prototype-agpl/ios && ./build-ios-libs.sh && ./make-xcframework.sh && ./gen-psn-client.sh`
3. Open `prototype-agpl/ios/RemoteGamingPrototype.xcodeproj`, choose your own signing team and bundle identifier, and run.
4. Tests: `cd Packages/RGPCore && swift test`

## Licences of included libraries
`App/RemoteGaming/Licences/ThirdPartyLicences.txt`
