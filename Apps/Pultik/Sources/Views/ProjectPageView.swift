import SwiftUI

// MARK: - Project page (the on-call view)

/// One product at a glance: its prod issues, PRs, service tiles, quick links.
struct ProjectPageView: View {
    let project: ProjectSpec
    let store: StatusStore
    let onBack: () -> Void

    private var projectPRs: [StatusStore.InboxPR] {
        let repos = Set(project.repos.map { $0.lowercased() })
        return store.inbox.filter { repos.contains($0.repoSlug.lowercased()) }
    }

    private var projectIssues: [ProdIssue] {
        store.prodIssues.filter { project.sentryProjects.contains($0.project) }
    }

    private var projectServices: [ServiceStatus] {
        store.serviceStatuses.filter { project.services.contains($0.name) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Button(action: onBack) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 10, weight: .bold))
                    }
                    .buttonStyle(.borderless)
                    .help("Back (Esc)")
                    Text(project.title)
                        .font(.system(size: 14, weight: .semibold))
                    Spacer()
                    ForEach(project.links) { link in
                        Button {
                            if let url = URL(string: link.url) {
                                NSWorkspace.shared.open(url)
                            }
                        } label: {
                            Text(link.title)
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 10)
                .padding(.bottom, 4)

                if !projectServices.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(projectServices) { service in
                            ServiceTile(service: service)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 4)
                }

                if !projectIssues.isEmpty {
                    Kicker(
                        text: "▲ Prod",
                        count: projectIssues.count,
                        tone: .red,
                        action: { if let url = OverviewURL.sentryIssues { OverviewURL.open(url) } },
                        actionRole: .link,
                        actionHelp: "Open the Sentry issue overview"
                    )
                        .padding(.horizontal, 8)
                        .padding(.top, 6)
                        .padding(.bottom, 2)
                    ForEach(projectIssues.prefix(6)) { prodIssue in
                        ProdIssueRow(prodIssue: prodIssue)
                    }
                }

                if projectPRs.isEmpty {
                    Text("no open PRs")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 14)
                } else {
                    Kicker(
                        text: "Pull Requests",
                        count: projectPRs.count,
                        action: { OverviewURL.open(OverviewURL.projectPulls(project.repos)) },
                        actionRole: .link,
                        actionHelp: "Open the GitHub pull-request overview"
                    )
                        .padding(.horizontal, 8)
                        .padding(.top, 6)
                        .padding(.bottom, 2)
                    ForEach(projectPRs) { entry in
                        InboxPRRow(entry: entry)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
    }
}
