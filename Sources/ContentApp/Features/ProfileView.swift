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
    /// Shown inside the Settings sheet (the round photo at the top right of every
    /// tab) rather than as a tab of its own.
    var asSheet = false
    @Environment(AppSession.self) private var session
    @Environment(\.requestReview) private var requestReview
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL

    @State private var approving: PendingPost?
    /// Asked before setup is restarted, because it throws somebody out of the
    /// app they are using.
    @State private var confirmingSetup = false
    /// The first-launch intro, played again on request (19 Oct 2026).
    @State private var watchingIntro = false
    @State private var web: WebPage?
    @State private var exporting = false
    @State private var exported: ExportShare?
    @State private var confirmingSignOut = false
    /// From the tap on Sign Out until the welcome screen is up: the sheet says so
    /// instead of sitting there as if nothing happened (Abel, 7 Nov 2026).
    @State private var signingOut = false
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingDelete = false
    @State private var typingDelete = false
    @State private var deleteWord = ""
    @State private var deleting = false
    @State private var signingUp = false
    @State private var managingSubscription = false
    /// The generator's settings sheet, from the Autocast group.
    @State private var generatorSettings = false
    /// The chat's settings -- the same sheet as the gear on the chat list.
    @State private var chatSettings = false

    /// What is typed in "Search settings".
    @State private var query = ""

    /// Where a "connect an account" finding sends somebody: the Accounts
    /// group, further down this same screen.
    private static let accountsAnchor = "accounts"

    /// Whether a group stays while searching: one of its rows is named like it.
    private func shows(_ titles: String...) -> Bool {
        let typed = query.trimmingCharacters(in: .whitespaces)
        return typed.isEmpty || titles.contains { $0.localizedCaseInsensitiveContains(typed) }
    }

    var body: some View {
        ScrollViewReader { scroll in
        List {
            // Grok's Settings, top to bottom (Abel, 3 Nov 2026, with his screen
            // recording: "put their profile at the top"): the person, their
            // subscription as a card of its own, then short groups -- and Sign
            // Out last. The full-screen "Connect your first account" gate that
            // stood between the profile and everything else (29 Sep) is gone;
            // with nothing connected, Accounts is simply the first group.
            // Searching (the pill at the bottom, Grok's) keeps only the groups
            // with a matching row; the profile card and Sign Out step aside.
            if query.isEmpty {
                Section {
                    ProfileHeader()
                }

                subscription
                account
                if session.needsAccount {
                    accounts.id(Self.accountsAnchor)
                } else {
                    attention(scroll)
                }
            } else if shows("Subscription", "Usage", "Upgrade", "Plan") {
                subscription
            }
            if shows("Brand", "Content pillars", "Posting hours") {
                brandSection
            }
            if !session.needsAccount || !query.isEmpty, shows("Accounts", "Connections", "TikTok", "YouTube", "Instagram") {
                accounts.id(Self.accountsAnchor)
            }
            if shows("Customize Postpilot", "Chat", "Memory", "Autopilot", "Video generators", "Picture & video settings", "Post defaults") {
                autocast
            }
            if shows("Appearance", "Notifications", "Show setup again", "Watch the intro") {
                app
            }
            if shows("Activity", "Export my data", "Data & Information") {
                data
            }
            if shows("Rate the App", "Terms of Use", "Privacy Policy") {
                legal
            }
            if shows("Report a Problem", "Support") {
                report
            }
            if query.isEmpty {
                signOutAndDelete
            }
        }
        .listStyle(.insetGrouped)
        .overlay { if signingOut { signingOutCover } }
        .disabled(signingOut)
        // On the list, not on its section: a sheet hung on a row of a List
        // closed by itself whenever the list redrew -- tapping Picture model
        // inside it shut the whole thing (Abel, 4 Nov 2026).
        .sheet(isPresented: $generatorSettings) { GeneratorSettingsSheet() }
        .animation(.snappy(duration: 0.25), value: query)
        .safeAreaInset(edge: .bottom) {
            if asSheet {
                SearchPill(text: $query, prompt: "Search settings")
                    .padding(.horizontal, 26)
                    .padding(.bottom, 8)
            }
        }
        // The tab says "You", so the screen does too. They disagreed.
        .tabChrome(title: asSheet ? "Settings" : "You", mode: .inline)
        .refreshable {
            await session.refreshConnections()
            await session.refreshSettings()
            await session.refreshHealth()
            await session.refreshPosts()
            await session.refreshSubscription()
        }
        .task {
            await session.refreshSubscription()
            await session.refreshCredits()
        }
        .sheet(item: $approving) { ApprovalSheet(post: $0) }
        .sheet(item: $web) { page in SafariSheet(url: page.url).ignoresSafeArea() }
        .sheet(item: $exported) { file in ShareSheet(items: [file.url]).presentationDetents([.medium, .large]) }
        .alert("Show setup again?", isPresented: $confirmingSetup) {
            Button("Cancel", role: .cancel) {}
            Button("Show it") { session.restartOnboarding() }
        } message: {
            Text("You'll go back to the first screen and walk through the questions. Nothing you have made is deleted.")
        }
        .alert("Sign out?", isPresented: $confirmingSignOut) {
            Button("Cancel", role: .cancel) {}
            Button("Sign Out", role: .destructive) { startSigningOut() }
        } message: {
            Text("Everything stays in your Apple account. Sign in with Apple again to get it back.")
        }
        .alert("Delete your account?", isPresented: $confirmingDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Continue", role: .destructive) { typingDelete = true }
        } message: {
            Text("Your brands, plans, videos and connected accounts are deleted from Postpilot for good. Videos already on TikTok stay there.")
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
    }

    // MARK: - Needs attention

    @ViewBuilder
    private func attention(_ scroll: ScrollViewProxy) -> some View {
        if !session.health.isEmpty || !session.failedRecently.isEmpty {
            Section {
                ForEach(session.health) { finding in
                    AttentionRow(finding: finding) {
                        withAnimation { scroll.scrollTo(Self.accountsAnchor, anchor: .top) }
                    }
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

    // MARK: - Subscription

    /// Grok's SuperGrok card: the plan on a colour of its own, with the one
    /// thing to do about it -- Upgrade, or Manage -- as a pill. Usage under it.
    @ViewBuilder
    private var subscription: some View {
        Section {
            if let plan = session.subscription, plan.isPro {
                // Named from the plan: this row said "Postpilot Pro" on a Max
                // subscription, under a profile card that said Max (3 Nov 2026).
                SubscriptionCard(
                    title: "Postpilot \(plan.title)",
                    detail: proDetail(plan),
                    action: plan.productId == "owner" ? nil : "Manage"
                ) { managingSubscription = true }
            } else {
                SubscriptionCard(
                    title: "Postpilot Pro",
                    detail: "Upgrade for pictures and videos",
                    action: "Upgrade"
                ) { session.showingPaywall = true }
            }
        } header: {
            Text("Subscription")
        }
        .manageSubscriptionsSheet(isPresented: $managingSubscription)

        // How much of the month is gone, right under the plan it comes from.
        Section {
            NavigationLink { UsageView().pushedPage() } label: {
                SettingsValueLabel("Usage", symbol: "gauge.with.dots.needle.33percent",
                                   value: session.credits.map { "\(UsageFormat.percent($0.percentUsed)) used" })
            }
        }
    }

    private func proDetail(_ plan: MyPlan) -> String {
        guard let date = plan.expires else { return plan.title }
        let when = date.formatted(date: .abbreviated, time: .omitted)
        if plan.isTrial { return "Trial ends \(when)" }
        return plan.autoRenew == false ? "Ends \(when)" : "Renews \(when)"
    }

    // MARK: - Account

    /// Only while the account lives on this iPhone alone: how they are signed
    /// in is already the line on the profile card at the top.
    @ViewBuilder
    private var account: some View {
        if session.isAnonymous {
            Section {
                Button { signingUp = true } label: {
                    SettingsRow("Save your account", symbol: "person.crop.circle.badge.checkmark", accessory: .chevron)
                }
            } footer: {
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
            Text("Your brand")
        }
    }

    // MARK: - Accounts

    private var accounts: some View {
        Section {
            ForEach([Platform.tiktok, .shorts, .reels]) { platform in
                if let connection = session.connection(for: platform) {
                    NavigationLink { AccountDetailView(connection: connection).pushedPage() } label: {
                        // The network's own mark, its name over the handle,
                        // and "Sign in again" only when it needs it.
                        AccountRow(platform: platform, connection: connection)
                    }
                } else {
                    Button {
                        Task { await session.connect(platform) }
                    } label: {
                        AccountRow(platform: platform, connection: nil, opening: session.isConnecting)
                    }
                    .buttonStyle(.plain)
                    .disabled(session.isConnecting)
                }
            }
        } header: {
            Text("Accounts")
        } footer: {
            Text("Instagram needs a Business or Creator account. While Google and Meta review Postpilot, only accounts added as testers can connect.")
        }
    }

    // MARK: - Autocast

    /// What Grok calls its own group ("Customize Grok, Skills, Connectors"):
    /// how the assistant talks, and what it makes and runs on its own.
    private var autocast: some View {
        Section {
            // Grok's "Customize Grok", and Claude's memory beside it.
            NavigationLink { ChatSettingsView() } label: {
                SettingsLabel("Customize Postpilot", symbol: "slider.horizontal.3")
            }
            NavigationLink { MemoryView() } label: {
                SettingsLabel("Memory", symbol: "book.closed")
            }
            NavigationLink { AutopilotView() } label: {
                SettingsValueLabel("Autopilot", symbol: "airplane", value: session.autopilotState?.title)
            }
            NavigationLink { GeneratorsView() } label: {
                SettingsValueLabel("Video generators", symbol: "wand.and.stars",
                                   // Autocast brings its own models; "Connected" was a claim about
                                   // something the person never connected.
                                   value: session.hasWorkingGenerator && !session.houseMakesVideo ? "Connected"
                                       : session.houseMakesVideo ? "Built in" : nil)
            }
            // The generator's settings, the same sheet as the sliders in the
            // chat bar: model, how many, shape, quality, length.
            Button { generatorSettings = true } label: {
                SettingsRow("Picture & video settings", symbol: "photo.on.rectangle.angled", accessory: .chevron)
            }
            NavigationLink { PostDefaultsView().pushedPage() } label: {
                SettingsLabel("Post defaults", symbol: "slider.horizontal.3")
            }
        } header: {
            Text("Postpilot")
        }
    }

    // MARK: - App

    private var app: some View {
        Section {
            NavigationLink { AppearanceView().pushedPage() } label: {
                SettingsValueLabel("Appearance", symbol: "circle.lefthalf.filled", value: AppAppearance.current.title)
            }
            NavigationLink { NotificationsView().pushedPage() } label: {
                SettingsLabel("Notifications", symbol: "bell")
            }
            // 🔴 Asked first. This threw somebody back to the welcome
            // screen on ONE tap, wearing a chevron -- which the design system
            // says means "opens a screen inside Postpilot", not "restart the
            // whole app's setup".
            Button { confirmingSetup = true } label: {
                SettingsRow("Show setup again", symbol: "arrow.counterclockwise")
            }
            Button { watchingIntro = true } label: {
                SettingsRow("Watch the intro", symbol: "play.rectangle")
            }
            .fullScreenCover(isPresented: $watchingIntro) {
                HomeIntroView { watchingIntro = false }
            }
        } header: {
            // Two unlabelled blocks ran together here, so "Usage this month"
            // and "Appearance" read as one long list of unrelated rows.
            Text("App")
        }
    }

    // MARK: - Data, legal, report

    /// Grok's "Data & Information": what happened, and a copy of all of it.
    private var data: some View {
        Section {
            NavigationLink { ActivityHistoryView().pushedPage() } label: {
                SettingsLabel("Activity", symbol: "list.bullet.rectangle")
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
            Text("Data & Information")
        }
    }

    /// Rate, Terms, Privacy -- one unlabelled group, as Grok has it.
    private var legal: some View {
        Section {
            Button { requestReview() } label: {
                SettingsRow("Rate the App", symbol: "star", accessory: .none)
            }
            Button { web = WebPage(url: AutocastLinks.terms) } label: {
                SettingsRow("Terms of Use", symbol: "doc.text", accessory: .chevron)
            }
            Button { web = WebPage(url: AutocastLinks.privacy) } label: {
                SettingsRow("Privacy Policy", symbol: "hand.raised", accessory: .chevron)
            }
        }
    }

    /// Report a Problem on its own, above Sign Out. It writes to support.
    private var report: some View {
        Section {
            Button { openURL(AutocastLinks.supportMail) } label: {
                SettingsRow("Report a Problem", symbol: "exclamationmark.bubble", accessory: .external)
            }
        }
    }

    // MARK: - Sign out, delete

    /// Covers the whole sheet while the account is let go.
    private var signingOutCover: some View {
        VStack(spacing: 18) {
            // The app's mark, breathing, in place of a spinner.
            BreathingMark()
            Text("Logging you out…")
                .font(.headline)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
        .transition(.opacity)
    }

    /// Says so, closes the sheet, then signs out of the phone and the server
    /// (`AppSession.signOut` revokes the session there) and lands on the
    /// welcome screen. `session` is held in a local first: this view is gone by
    /// the time the sign-out finishes, and an environment value read after
    /// that is not safe.
    private func startSigningOut() {
        let account = session
        let closes = asSheet
        withAnimation(.easeOut(duration: 0.2)) { signingOut = true }
        Task {
            try? await Task.sleep(for: .milliseconds(700))
            if closes { dismiss() }
            try? await Task.sleep(for: .milliseconds(300))
            await account.signOut()
        }
    }

    /// Grok's ending: Sign Out as a red row with its icon, then the version,
    /// and Delete account under it -- still one tap away and asked twice, as
    /// App Review requires, but no longer a red bar the same size as Sign Out.
    private var signOutAndDelete: some View {
        Section {
            if !session.isAnonymous {
                Button(role: .destructive) { confirmingSignOut = true } label: {
                    Label {
                        Text("Sign Out")
                    } icon: {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                            .frame(width: 28)
                    }
                    .foregroundStyle(Color.red)
                }
            }
        } footer: {
            VStack(spacing: 10) {
                Text(AutocastLinks.versionLine)
                Button(role: .destructive) { confirmingDelete = true } label: {
                    if deleting {
                        ProgressView()
                    } else {
                        Text("Delete account")
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(Color.red.opacity(0.85))
                    }
                }
                .buttonStyle(.plain)
                .disabled(deleting)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 14)
        }
    }
}

/// Grok's SuperGrok card in Autocast's colour: the plan, one line about it,
/// and one pill to act on it -- Upgrade, or Manage.
private struct SubscriptionCard: View {
    let title: String
    let detail: String
    /// "Upgrade" or "Manage"; nil when there is nothing to do here.
    let action: String?
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.title3.weight(.semibold))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                    Text(detail)
                        .font(.footnote)
                        .opacity(0.85)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if let action {
                    Text(action)
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Color.black.opacity(0.28), in: Capsule())
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(LinearGradient(
                        colors: [Theme.accent, Theme.accent.opacity(0.78)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
            }
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(PressButtonStyle())
        .disabled(action == nil)
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
        .accessibilityLabel("\(title), \(detail)")
        .accessibilityHint(action == "Upgrade" ? "Shows the plans" : "Manage your subscription")
    }
}

/// A page to show in the in-app Safari sheet.
struct WebPage: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

// MARK: - Needs attention rows

/// One finding from `autopilot_health`, and the one tap that fixes it.
///
/// 🔴 Only `.plan` findings were ever tappable. A finding that said the
/// generator was not connected, or that nothing was connected to post to,
/// rendered as an inert row under a heading that says "Needs attention" --
/// telling somebody something is wrong and then giving them no way to act on
/// it. Every route leads somewhere now: the generator to its own screen, the
/// connections to the Accounts group further down this same page.
private struct AttentionRow: View {
    let finding: HealthFinding
    /// Takes them to Accounts, which is on this screen rather than another.
    let showAccounts: () -> Void

    private var route: HealthRoute? { finding.route.flatMap(HealthRoute.init(rawValue:)) }

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

        switch route {
        case .plan:
            NavigationLink { PlanView() } label: { row }
        case .generator:
            NavigationLink { GeneratorsView() } label: { row }
        case .connections:
            Button(action: showAccounts) {
                HStack(spacing: 8) {
                    row
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.down")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color(uiColor: .tertiaryLabel))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        case nil:
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
