import SwiftUI

/// A shelf release's own content (Prod's Releases section, D9): every
/// platform build of the version with its size and download, then the
/// release notes. ⌘↵ opens the app's page on the shelf.
struct ShelfReleaseDetail: View {
    let release: ShelfRelease

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Tile(kicker: "Builds", caption: "\(release.builds.count) · \(PultikFormat.date(release.publishedAt, now: Date()))") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(release.builds, id: \.appID) { build in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(build.platform).font(Theme.Typo.figure).foregroundStyle(Theme.ink)
                            Text(build.url.lastPathComponent).font(Theme.Typo.meta).foregroundStyle(Theme.ink2)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Text(PultikFormat.size(Double(build.size))).font(Theme.Typo.meta).monospacedDigit()
                                .foregroundStyle(Theme.ink3)
                            LinkGlyph(url: build.url, label: "Download \(build.platform)")
                        }
                    }
                }
            }
            if !release.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Tile(kicker: "Notes") {
                    Text(release.notes)
                        .font(Theme.Typo.body)
                        .foregroundStyle(Theme.ink2)
                        .lineLimit(40)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}
