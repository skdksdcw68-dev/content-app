import SwiftUI
import StoreKit

/// The creator's control room: who is posting and how it is going on top,
/// then everything Autocast runs on, one short group at a time -- the account,
/// the brand, the accounts it posts to, Autopilot and AI, what happened, the
/// app, and support.
///
/// Remi's Profile, in its way: a native inset-grouped list, outline symbols in
/// one column, sub-pages as forms, destructive things centred and asked twice.
struct ProfileView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.requestReview) private var requestReview
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL

    @State private var approving: PendingPost?
    @State private var web: WebPage?
    @State private var exporting = false
    @State private var exported: ExportShare?
    @State private var confirmingSignOut = false
    @State private var confirmingDelete = false
    @State private var typingDelete = false
    @State private var deleteWord = ""
    @State private var deleting = false
    @State private var signingUp = false
    @State private var managingSubscription = false

    var body: some View {
        List {
            Section {
                ProfileHeader()
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 8, trailing: 0))
            }

            attention
            pro
            account
            brandSection
            accounts
            autopilot
            insights
            app
            support
            signOutAndDelete
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Profile")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await session.refreshConnections()
            await session.refreshSettings()
            await session.refreshHealth()
            await session.refreshPosts()
            await session.refreshSubscription()
        }
        .task { await session.refreshSubscription() }
        .sheet(item: $approving) { ApprovalSheet(post: $0) }
        .sheet(item: $web) { page in SafariSheet(url: page.url).ignoresSafeArea() }
        .sheet(item: $exported) { file in ShareSheet(items: [file.url]).presentationDetents([.medium, .large]) }
        .alert("Sign out?", isPresented: $confirmingSignOut) {
            Button("Cancel", role: .cancel) {}
            Button("Sign Out", role: .destructive) { Task { await session.signOut() } }
        } message: {
            Text("Everything stays in your Apple account. Sign in with Apple again to get it back.")
        }
        .alert("Delete your account?", isPresented: $confirmingDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Continue", role: .destructive) { typingDelete = true }
        } message: {
            Text("Your brands, plans, videos and connected accounts are deleted from Autocast for good. Videos already on TikTok stay there.")
        }
        .alert("Type DELETE to confirm", isPresented: $typingDelete) {
            TextField("DELETE", text: $deleteWord)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
            Button("Cancel", role: .cancel) { deleteWord = "" }
            Button("Delete Account", role: .destructive) {
                deleteWord = ""
                Task {
                    deleting = true
                    await session.deleteAccount()
                    deleting = false
                }
            }
            .disabled(deleteWord != "DELETE")
        } message: {
            Text("This can’t be undone.")
        }
        .sheet(isPresented: $signingUp) { AuthSheet() }
    }

    // MARK: - Needs attention

    @ViewBuilder
    private var attention: some View {
        if !session.health.isEmpty || !session.failedRecently.isEmpty {
            Section {
                ForEach(session.health) { finding in
                    AttentionRow(finding: finding)
                }
                ForEach(session.failedRecently.prefix(5)) { post in
                    Button { approving = post } label: {
                        FailedPostRow(post: post)
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("Needs attention")
            }
        }
    }

    // MARK: - Autocast Pro

    @ViewBuilder
    private var pro: some View {
        Section {
            if let plan = session.subscription, plan.isPro {
                Button { managingSubscription = true } label: {
                    SettingsRow("Autocast Pro", symbol: "sparkles", value: proDetail(plan), accessory: .chevron)
                }
                .disabled(plan.productId == "owner")
            } else {
                Button { session.showingPaywall = true } label: {
                    SettingsRow("Get Autocast Pro", symbol: "sparkles", accessory: .chevron)
                }
            }
        } footer: {
            if let plan = session.subscription, !plan.isPro {
                Text("Free: \(plan.limits.planDays)-day plans, \(plan.limits.aiWrites) AI caption writes and \(plan.limits.chat) chat messages a month.")
            }
        }
        .manageSubscriptionsSheet(isPresented: $managingSubscription)
    }

    private func proDetail(_ plan: MyPlan) -> String {
        guard let date = plan.expires else { return plan.title }
        let when = date.formatted(date: .abbreviated, time: .omitted)
        if plan.isTrial { return "Trial ends \(when)" }
        return plan.autoRenew == false ? "Ends \(when)" : "Renews \(when)"
    }

    // MARK: - Account

    @ViewBuilder
    private var account: some View {
        Section {
            if session.isAnonymous {
                Button { signingUp = true } label: {
                    SettingsRow("Save your account", symbol: "person.crop.circle.badge.checkmark", accessory: .chevron)
                }
            } else {
                SettingsRow("Signed in", symbol: "checkmark.seal", value: session.accountEmail ?? "Apple ID")
            }
        } footer: {
            if session.isAnonymous {
                Text("Everything is on this iPhone only. Save it with Apple, Google or your email so it comes back anywhere.")
            }
        }
    }

    // MARK: - Brand

    private var brandSection: some View {
        Section {
            NavigationLink { BrandView() } label: {
                SettingsValueLabel("Brand", symbol: "sparkles",
                                   value: session.brand?.isComplete == true ? nil : "Add details")
            }
            NavigationLink { PillarsView().pushedPage() } label: {
                SettingsLabel("Content pillars", symbol: "square.grid.2x2")
            }
            NavigationLink { ScheduleView().pushedPage() } label: {
                SettingsValueLabel("Posting hours", symbol: "clock",
                                   value: session.settings.map { "\($0.postsPerDay) a day" })
            }
        } header: {
            Text(session.brand?.name ?? "Brand")
        }
    }

    // MARK: - Accounts

    private var accounts: some View {
        Section {
            ForEach([Platform.tiktok, .shorts, .reels]) { platform in
                if let connection = session.connection(for: platform) {
                    NavigationLink { AccountDetailView(connection: connection).pushedPage() } label: {
                        HStack(spacing: 8) {
                            SettingsLabel(platform.networkName, symbol: platform.symbolName)
                            Spacer(minLength: 0)
                            if !connection.isHealthy {
                                Image(systemName: "exclamationmark.circle")
                                    .foregroundStyle(Color.orange)
                            }
                            Text(connection.label)
                                .foregroundStyle(Color(uiColor: .secondaryLabel))
                                .lineLimit(1)
                        }
                    }
                } else {
                    Button {
                        Task { await session.connect(platform) }
                    } label: {
                        SettingsRow(platform.networkName, symbol: platform.symbolName,
                                    value: session.isConnecting ? "Opening…" : "Connect", accessory: .chevron)
                    }
                    .disabled(session.isConnecting)
                }
            }
        } header: {
            Text("Accounts")
        } footer: {
            Text("Instagram needs a Business or Creator account. While Google and Meta review Autocast, only accounts added as testers can connect.")
        }
    }

    // MARK: - Autopilot & AI

    private var autopilot: some View {
        Section {
            NavigationLink { AutopilotView().pushedPage() } label: {
                SettingsValueLabel("Autopilot", symbol: "airplane", value: session.autopilotState?.title)
            }
            NavigationLink { GeneratorsView().pushedPage() } label: {
                SettingsValueLabel("AI generators", symbol: "wand.and.stars",
                                   value: session.hasWorkingGenerator ? "Connected" : nil)
            }
            NavigationLink { PostDefaultsView().pushedPage() } label: {
                SettingsLabel("Post defaults", symbol: "slider.horizontal.3")
            }
        } header: {
            Text("Autopilot & AI")
        }
    }

    // MARK: - Insights

    private var insights: some View {
        Section {
            NavigationLink { UsageView().pushedPage() } label: {
                SettingsLabel("Usage this month", symbol: "chart.bar")
            }
            NavigationLink { ActivityHistoryView().pushedPage() } label: {
                SettingsLabel("Activity", symbol: "list.bullet.rectangle")
            }
        }
    }

    // MARK: - App

    private var app: some View {
        Section {
            NavigationLink { AppearanceView().pushedPage() } label: {
                SettingsValueLabel("Appearance", symbol: "circle.lefthalf.filled", value: AppAppearance.current.title)
            }
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            } label: {
                SettingsRow("Notifications", symbol: "bell", accessory: .external)
            }
            Button { session.restartOnboarding() } label: {
                SettingsRow("Show setup again", symbol: "arrow.counterclockwise", accessory: .chevron)
            }
        }
    }

    // MARK: - Support

    private var support: some View {
        Section {
            Button { openURL(AutocastLinks.supportMail) } label: {
                SettingsRow("Contact support", symbol: "envelope", accessory: .external)
            }
            Button { requestReview() } label: {
                SettingsRow("Rate Autocast", symbol: "star", accessory: .none)
            }
            Button { web = WebPage(url: AutocastLinks.privacy) } label: {
                SettingsRow("Privacy Policy", symbol: "hand.raised", accessory: .chevron)
            }
            Button { web = WebPage(url: AutocastLinks.terms) } label: {
                SettingsRow("Terms of Use", symbol: "doc.text", accessory: .chevron)
            }
            Button {
                Task {
                    exporting = true
                    if let url = await session.exportData() { exported = ExportShare(url: url) }
                    exporting = false
                }
            } label: {
                HStack {
                    SettingsRow("Export my data", symbol: "square.and.arrow.up")
                    if exporting { ProgressView() }
                }
            }
            .disabled(exporting)
        } header: {
            Text("Support")
        }
    }

    // MARK: - Sign out, delete

    private var signOutAndDelete: some View {
        Section {
            if !session.isAnonymous {
                Button { confirmingSignOut = true } label: {
                    Text("Sign Out").frame(maxWidth: .infinity)
                }
            }
            Button(role: .destructive) { confirmingDelete = true } label: {
                HStack {
                    Spacer()
                    if deleting { ProgressView() } else { Text("Delete Account") }
                    Spacer()
                }
            }
            .disabled(deleting)
        } footer: {
            Text(AutocastLinks.versionLine)
                .frame(maxWidth: .infinity)
                .padding(.top, 12)
        }
    }
}

/// A page to show in the in-app Safari sheet.
struct WebPage: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

// MARK: - Needs attention rows

/// One finding from `autopilot_health`, with its one action when the fix lives
/// on another screen.
private struct AttentionRow: View {
    let finding: HealthFinding

    var body: some View {
        let row = Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(finding.title)
                Text(finding.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } icon: {
            Image(systemName: finding.isBlocked ? "exclamationmark.circle" : "info.circle")
                .foregroundStyle(finding.isBlocked ? Color.orange : Color.secondary)
        }

        if finding.route.flatMap(HealthRoute.init(rawValue:)) == .plan {
            NavigationLink { PlanView().pushedPage() } label: { row }
        } else {
            row
        }
    }
}

private struct FailedPostRow: View {
    let post: PendingPost

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(post.caption.isEmpty ? post.post.hook : post.caption)
                    .lineLimit(1)
                Text(post.failureReason ?? "It did not go out.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } icon: {
            Image(systemName: "arrow.uturn.backward.circle")
                .foregroundStyle(Color.orange)
        }
        .contentShape(Rectangle())
    }
}
