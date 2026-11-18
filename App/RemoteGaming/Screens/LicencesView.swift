import SwiftUI

/// Where this app's source code is published. The PlayStation engine's licence (AGPL-3.0)
/// requires that everyone who receives the app can get the complete source. Leave nil until
/// the public address exists; the screen then says plainly that it is not yet published.
enum SourceInfo {
    static let sourceURL: URL? = nil
}

/// "Licences and source code": what open-source software is inside the app, the full licence
/// texts shipped with it, and where the source is.
struct LicencesView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Card {
                    Text("SOURCE CODE").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                    Text("CoastPlay PRO connects to a PlayStation 5 using chiaki-ng, open-source software under the GNU Affero General Public License, version 3 (with an OpenSSL exception). Because of that licence, this app's own source code is open too, and you are free to get it, study it, change it and share it under the same licence.")
                        .font(.subheadline).fixedSize(horizontal: false, vertical: true)
                    if let url = SourceInfo.sourceURL {
                        Link(destination: url) { Label("Get the source code", systemImage: "arrow.up.right.square") }.font(.subheadline.weight(.semibold))
                        Text(url.absoluteString).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    } else {
                        Label("The source code address has not been published yet. It will be listed here before this app is given to anyone outside the developer.", systemImage: "exclamationmark.triangle")
                            .font(.footnote).foregroundStyle(Theme.demo).fixedSize(horizontal: false, vertical: true)
                    }
                    Text("CoastPlay PRO is not made, endorsed or supported by Sony. PlayStation and PS5 are trademarks of Sony Interactive Entertainment.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Card {
                    Text("LICENCE TEXTS").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                    NavigationLink { LicenceTextView(title: "chiaki-ng (AGPL-3.0)", file: "Engine-AGPL-3.0-only-OpenSSL") } label: {
                        Label("chiaki-ng — GNU AGPL version 3", systemImage: "doc.text")
                    }
                    NavigationLink { LicenceTextView(title: "Other libraries", file: "ThirdPartyLicences") } label: {
                        Label("Opus, libevent, Mbed TLS, MiniUPnPc, json-c, curl, nanopb, Jerasure, GF-Complete", systemImage: "doc.on.doc")
                    }
                }
                .font(.subheadline)
            }
            .padding(16)
        }
        .background(Theme.background)
        .navigationTitle("Licences and source code")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct LicenceTextView: View {
    let title: String
    let file: String

    var body: some View {
        ScrollView {
            Text(text).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.background)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var text: String {
        guard let url = Bundle.main.url(forResource: file, withExtension: "txt"), let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "This licence text is missing from the app. Please tell the developer."
        }
        return text
    }
}
