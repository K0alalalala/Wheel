import SwiftUI

struct AboutView: View {
    static var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "Version \(v) (\(b))"
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().frame(width: 72, height: 72)
            VStack(spacing: 2) {
                Text("Wheel").font(.title.bold())
                Text(Self.version).font(.caption).foregroundStyle(.secondary)
            }
            Text("Drag a file, hold Shift, drop it on a slice.")
                .font(.callout).foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(Credits.roles.enumerated()), id: \.offset) { _, role in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(role.who).font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(role.who == Credits.human ? Theme.accent : .primary)
                            .frame(width: 128, alignment: .trailing)
                        Text(role.did).font(.system(size: 12)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))

            Text("No humans were overworked in the making of this app.")
                .font(.caption).italic().foregroundStyle(.secondary)

            Link("github.com/\(Credits.human)", destination: Credits.humanURL).font(.caption)
        }
        .padding(24)
        .frame(width: 460)
    }
}
