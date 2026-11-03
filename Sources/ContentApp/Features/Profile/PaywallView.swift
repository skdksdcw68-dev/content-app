import SwiftUI
import StoreKit
import UIKit

/// Autocast's plans: Pro and Max monthly or yearly, Ultra monthly only. No free
/// trial on any of them (Netro, 2 Oct 2026).
///
/// Netro, 29 Sep 2026: "we do need to provide a pricing things as well, like we
/// can split it, pro, max and 1 more so they choose and subscribe."
///
/// The shape is SuperGrok's, from Abel's screen recording of the real app (3
/// Nov 2026; it was Drobe's until 1 Nov): a heading that changes with the plan,
/// the plan switch, one card with the plan's name, the ways to pay, the button
/// and what is included, and the small print pinned to the bottom. The choice
/// is two questions -- how much, and how long -- and the first is the one that
/// matters, because Pro, Max and Ultra differ in how much a person can make
/// each month.
///
/// Every number about what a plan GIVES is read from the server
/// (`plan_tiers()`), never typed here: a figure on this screen that the server
/// does not enforce is the kind of lie that ends in a refund request. Every
/// number about what it COSTS is StoreKit's, in the person's own currency.
///
/// A subscriber gets the same screen with a status header instead of the pitch,
/// and the button changes their plan. Apple does the rest: an upgrade is
/// immediate and prorated, a downgrade waits for the renewal.
struct PaywallView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var products: [Product] = []
    @State private var tier: Tier = Tier.recommended
    @State private var yearly = true
    @State private var trialEligible = false
    @State private var loading = true
    @State private var buying = false
    @State private var restoring = false
    @State private var managing = false
    /// A subscriber who tapped Upgrade: the plans above theirs are showing.
    @State private var upgrading = false

    /// The tier just bought: the welcome is showing (18 Oct 2026).
    @State private var welcomed: Tier?

    /// Set when shown as an onboarding step rather than a sheet.
    private let onClose: (() -> Void)?

    /// `previewWelcome` opens straight on the welcome, for the simulator lane
    /// that photographs it (Debug only, see ContentAppApp).
    init(onClose: (() -> Void)? = nil, previewWelcome: Tier? = nil) {
        self.onClose = onClose
        _welcomed = State(initialValue: previewWelcome)
    }

    private func close() {
        if let onClose { onClose() } else { dismiss() }
    }

    // MARK: - What is chosen

    private var isSubscriber: Bool { session.subscription?.isPro == true }

    /// The tier they are on now, when they are on one. A trial is Pro.
    private var currentTier: Tier? {
        guard isSubscriber else { return nil }
        let rank = session.planRank
        return Tier.allCases.first { $0.rank == rank }
    }

    private func product(_ tier: Tier, yearly: Bool) -> Product? {
        let id = tier.productID(yearly: yearly)
        return products.first { $0.id == id }
    }

    /// Whether this tier is billed yearly under the toggle as it stands. A tier
    /// with no yearly product (Ultra) is sold monthly whichever side is picked --
    /// without this its button had nothing to buy and did nothing.
    private func billsYearly(_ tier: Tier) -> Bool {
        guard yearly else { return false }
        return products.isEmpty ? tier.sellsYearly : product(tier, yearly: true) != nil
    }

    private var choice: Product? { product(tier, yearly: billsYearly(tier)) }

    /// The tiers to show: all three until StoreKit has answered, then only the
    /// ones App Store Connect actually sells. A tier with no product is a row
    /// that cannot be bought, and the paywall lights it up by itself the day
    /// the product exists.
    ///
    /// Under Annual, only the tiers that HAVE a yearly product. Netro, 18 Oct
    /// 2026: "turn off the ultra yearly plan, the monthly stays" -- Ultra was
    /// never sold yearly, but it sat under the Annual tab saying "Monthly only",
    /// which read as a yearly Ultra. It shows under Monthly.
    private var offered: [Tier] {
        // A subscriber is shown only what is above their plan (Netro, 19 Oct
        // 2026: "if you are a pro, you are on the pro subscriber page... there
        // should be an upgrade button").
        let above: (Tier) -> Bool = { tier in (currentTier?.rank ?? 0) < tier.rank }
        guard !products.isEmpty else {
            return (yearly ? Tier.allCases.filter(\.sellsYearly) : Tier.allCases).filter(above)
        }
        let sold = Tier.allCases.filter {
            yearly ? product($0, yearly: true) != nil
                   : product($0, yearly: false) != nil
        }.filter(above)
        return sold.isEmpty ? Tier.allCases.filter { (!yearly || $0.sellsYearly) && above($0) } : sold
    }

    /// The plan above theirs, for the one Upgrade button.
    private var nextTier: Tier? {
        guard let currentTier else { return nil }
        return Tier.allCases.first { $0.rank == currentTier.rank + 1 }
    }

    /// The product they already have, so the button can say so.
    private var isCurrentChoice: Bool {
        guard let choice else { return false }
        return session.subscription?.productId == choice.id
    }

    // MARK: - What a tier gives, from the server

    private struct Facts {
        /// How much it gives next to Pro: 1, 3, 8.
        let usage: Double
        let planDays: Int
        let accounts: Int
    }

    private func facts(_ tier: Tier) -> Facts {
        if let row = session.planTiers.first(where: { $0.code == tier.planCode }) {
            return Facts(usage: row.usage ?? tier.fallbackUsage, planDays: row.planDays, accounts: row.accounts)
        }
        return Facts(usage: tier.fallbackUsage, planDays: tier.fallbackPlanDays, accounts: tier.fallbackAccounts)
    }

    /// "Standard usage", "3× the usage of Pro": how a meter in % is compared.
    private func usageText(_ tier: Tier) -> String {
        let usage = facts(tier).usage
        guard tier != .pro, usage > 1 else { return "A full month of usage" }
        let times = usage == usage.rounded() ? String(Int(usage)) : String(format: "%.1f", usage)
        return "\(times)× the usage of Pro"
    }

    /// What is included, a symbol and a short line each. Only things the tier
    /// really has.
    ///
    /// Built the way SuperGrok's are (Abel's recording of the real app, 3 Nov
    /// 2026): a higher plan opens with "Everything in <the plan below>", and a
    /// line two plans share is worded identically in both. The list is keyed
    /// by those words, so switching plans leaves a shared line where it is and
    /// only cross-fades the lines that differ -- "it just adds the text right
    /// there".
    private func features(_ tier: Tier) -> [PlanFeature] {
        let facts = facts(tier)
        let usage = PlanFeature(symbol: "gauge.with.dots.needle.67percent", text: usageText(tier))
        let days = PlanFeature(symbol: "calendar", text: "Plan \(facts.planDays) days ahead")
        let accounts = PlanFeature(symbol: "person.2", text: "Post to \(facts.accounts) accounts")
        // Not "Veo 3.1": fal turns it off on 17 Nov 2026.
        let flagship = PlanFeature(symbol: "crown", text: "Flagship models like Seedance 2.5, up to 30 seconds")
        switch tier {
        case .pro:
            return [
                usage,
                PlanFeature(symbol: "film", text: "Video models like Kling 3 and Gemini Omni"),
                PlanFeature(symbol: "photo", text: "Pictures with GPT Image 2 and Nano Banana"),
                PlanFeature(symbol: "waveform", text: "Photo videos with a voice and captions"),
                days,
                accounts,
            ]
        case .max:
            return [
                PlanFeature(symbol: "checkmark.seal", text: "Everything in Pro"),
                usage,
                flagship,
                days,
                accounts,
            ]
        case .ultra:
            return [
                PlanFeature(symbol: "checkmark.seal", text: "Everything in Max"),
                usage,
                flagship,
                PlanFeature(symbol: "repeat", text: "Enough for a series every day"),
                days,
                accounts,
            ]
        }
    }

    /// The heading changes with the plan, as SuperGrok's does.
    private func headline(_ tier: Tier) -> String {
        switch tier {
        case .pro: return "Unlock the full power of Autocast"
        case .max: return "For people who post every day"
        case .ultra: return "The most powerful version of Autocast"
        }
    }

    // MARK: - What it costs, from StoreKit

    /// The price to print: live when StoreKit has answered, otherwise what it
    /// said last time on this phone -- so the cards are never blank while
    /// anything is known.
    ///
    /// 🔴 There is no "loading" state left while anything is known. The words
    /// "Loading plans…" were shown on EVERY open once, because the products
    /// lived in a `@State` that a re-presented sheet is born without (Abel,
    /// 25 Sep 2026). They are held on the session now and fetched at launch.
    private func priceText(_ tier: Tier, yearly: Bool) -> String? {
        if let live = product(tier, yearly: yearly) { return live.displayPrice }
        return RememberedPricing.saved?.prices[tier.productID(yearly: yearly)]
    }

    /// "$20.83/mo" for a yearly plan, from the real price.
    private func perMonthText(_ tier: Tier) -> String? {
        guard let live = product(tier, yearly: true) else { return nil }
        let monthly: Decimal = live.price / 12
        return monthly.formatted(live.priceFormatStyle)
    }

    /// "SAVE 31%": the yearly price against twelve months of the monthly one.
    private func saving(_ tier: Tier) -> Int? {
        guard let year = product(tier, yearly: true),
              let month = product(tier, yearly: false),
              month.price > 0 else { return nil }
        let twelve: Decimal = month.price * 12
        let fraction: Decimal = (twelve - year.price) / twelve
        let percent = Int((NSDecimalNumber(decimal: fraction).doubleValue * 100).rounded())
        return percent > 0 ? percent : nil
    }

    private func hasTrial(_ product: Product) -> Bool {
        trialEligible && product.subscription?.introductoryOffer?.paymentMode == .freeTrial
    }

    private var canChoose: Bool { !products.isEmpty }

    // MARK: - The screen

    /// SuperGrok's paywall, from Abel's recording of the real app (3 Nov 2026):
    /// a round X, a heading that changes with the plan, the plan switch, then
    /// ONE card holding the plan's name, the ways to pay, the button and what
    /// is included -- in that order, the button above the list -- and the
    /// small print pinned to the bottom of the screen.
    ///
    /// It follows the phone's appearance. It was black whatever the phone said
    /// (1 Nov), and Abel, watching it open black over the white app: "I don't
    /// even know why it's giving a black screen while I'm on the white." In
    /// dark mode it is SuperGrok's black; in light mode the same layout on the
    /// app's own grouped grey and white.
    var body: some View {
        ScrollView {
            if isSubscriber && !upgrading {
                subscriberPage
                    .padding(.horizontal, 20)
                    .padding(.bottom, 32)
            } else {
                VStack(spacing: 0) {
                    header
                    tierSwitch
                        .padding(.top, 20)
                    planCard
                        .padding(.top, 16)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 32)
            }
        }
        .scrollIndicators(.hidden)
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack {
                // A sheet closes with an X, not a back chevron.
                Button { close() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 42, height: 42)
                        .background(Color.primary.opacity(0.08), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 4)
            .background(Theme.canvas)
        }
        // Pinned to the bottom of the screen and out of the scrolling
        // content, as SuperGrok has it: Terms, Privacy and Restore on one
        // quiet line that never sits among the plans.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            legalLine
                .padding(.horizontal, 24)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .background(Theme.canvas)
        }
        .animation(.smooth(duration: 0.3), value: upgrading)
        .background(Theme.canvas.ignoresSafeArea())
        .overlay {
            if let welcomed {
                PurchaseWelcomeView(
                    tier: welcomed,
                    features: features(welcomed).map(\.text),
                    standing: session.credits,
                    confirmed: (session.subscription?.tier ?? (session.subscription?.isPro == true ? 1 : 0)) >= welcomed.rank,
                    onDone: close
                )
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .animation(.smooth(duration: 0.35), value: welcomed)
        .manageSubscriptionsSheet(isPresented: $managing)
        .task { await load() }
    }

    // MARK: - Header

    /// SuperGrok's: one line that changes with the plan, and a quiet one under
    /// it. A subscriber moving up gets the same, plus the way back.
    private var header: some View {
        VStack(spacing: 6) {
            Text(isSubscriber ? "Upgrade your plan" : headline(tier))
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
                .contentTransition(.opacity)
            Text(isSubscriber ? "Moving up starts now, and Apple credits what is left of your plan." : "Choose the right plan for you")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if isSubscriber {
                Button {
                    upgrading = false
                } label: {
                    Label("Back to your plan", systemImage: "chevron.backward")
                        .font(.subheadline.weight(.semibold))
                }
                .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    /// The card: the plan's name, the ways to pay, the button, the small line
    /// Apple wants beside it, then what is included.
    private var planCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            // "SuperGrok Plus": the plan's own word in the accent.
            Text("Autocast \(Text(tier.name).foregroundStyle(Theme.accent))")
                .font(.title3.weight(.semibold))
                .contentTransition(.opacity)

            priceChoices

            footer

            FeatureList(features: features(tier))
                .padding(.top, 4)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        }
    }

    /// What a subscriber sees: their plan, as a status page, and the way up.
    /// Never "Subscribe to Pro" to somebody already on Pro.
    private var subscriberPage: some View {
        VStack(spacing: 0) {
            status
            if let currentTier {
                VStack(alignment: .leading, spacing: 16) {
                    Text("YOUR \(currentTier.name.uppercased()) PLAN INCLUDES")
                        .font(.caption.weight(.bold))
                        .kerning(0.6)
                        .foregroundStyle(.secondary)
                    FeatureList(features: features(currentTier))
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .padding(.top, 12)
            }
            VStack(spacing: 12) {
                if let nextTier {
                    Button {
                        tier = nextTier
                        if !nextTier.sellsYearly { yearly = false }
                        upgrading = true
                    } label: {
                        Text("Upgrade to \(nextTier.name)")
                    }
                    .buttonStyle(UpgradeButtonStyle(busy: false))
                    Text("\(nextTier.name) gives you \(usageText(nextTier)).")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                } else {
                    Label("You're on our biggest plan", systemImage: "crown.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                }
                accountLinks
            }
            .padding(.top, 24)
        }
    }

    /// A status header, not a sales pitch: which plan, when it renews, and how
    /// much of this month's usage is left.
    private var status: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.caption.weight(.bold))
                Text("\((session.subscription?.title ?? "PRO").uppercased()) ACTIVE")
                    .font(.caption2.weight(.bold))
                    .kerning(1)
            }
            .foregroundStyle(Theme.onAccent)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Theme.accent, in: Capsule())

            Text("You’re on Autocast \(session.subscription?.title ?? "Pro")")
                .font(.system(size: 28, weight: .heavy))
                .multilineTextAlignment(.center)

            if let plan = session.subscription, let date = plan.expires {
                Text(renewalLine(plan, date))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if let credits = session.credits, credits.allowance > 0 {
                PaywallUsageMeter(credits: credits)
                    .padding(.top, 6)
            }
        }
        .padding(.vertical, 16)
    }

    // MARK: - Choosing

    /// The plans to pick between: the ones above the subscriber's own, and
    /// only the ones App Store Connect sells once StoreKit has answered.
    private var choosableTiers: [Tier] {
        let above: (Tier) -> Bool = { (currentTier?.rank ?? 0) < $0.rank }
        let sold: (Tier) -> Bool = { products.isEmpty || product($0, yearly: false) != nil || product($0, yearly: true) != nil }
        return Tier.allCases.filter { above($0) && sold($0) }
    }

    private var tierSwitch: some View {
        TierSwitch(tiers: choosableTiers, chosen: tier) { picked in
            // One quick cross-fade for the heading, the prices and the list,
            // as SuperGrok's switch does.
            withAnimation(.easeInOut(duration: 0.25)) {
                tier = picked
            }
        }
    }

    private var pricesKnown: Bool {
        priceText(tier, yearly: false) != nil || priceText(tier, yearly: true) != nil
    }

    /// Whether the picked plan can be paid for yearly at all.
    private var hasYearly: Bool {
        products.isEmpty ? tier.sellsYearly : product(tier, yearly: true) != nil
    }

    /// Monthly beside Yearly, for the plan that is picked, as SuperGrok's two
    /// tiles. Ultra is sold monthly only, so it shows one tile with nothing to
    /// pick, as SuperGrok Heavy does.
    @ViewBuilder
    private var priceChoices: some View {
        if !pricesKnown && loading {
            SkeletonCard(height: 76)
        } else if !pricesKnown {
            Text("Plans aren’t available right now. Please check your connection and try again.")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
        } else {
            HStack(spacing: 10) {
                PriceTile(
                    price: priceText(tier, yearly: false) ?? "N/A",
                    note: "Billed monthly",
                    badge: nil,
                    chosen: !billsYearly(tier),
                    selectable: hasYearly
                ) {
                    withAnimation(.snappy(duration: 0.2)) { yearly = false }
                }
                if hasYearly {
                    PriceTile(
                        price: priceText(tier, yearly: true) ?? "N/A",
                        note: "Billed yearly",
                        badge: saving(tier).map { "Save \($0)%" },
                        chosen: billsYearly(tier),
                        selectable: true
                    ) {
                        withAnimation(.snappy(duration: 0.2)) { yearly = true }
                    }
                }
            }
        }
    }

    // MARK: - Buying

    /// The button and the one short line Apple wants beside it. While Apple's
    /// sheet is opening the button goes grey with a spinner in it, as
    /// SuperGrok's does. The small print lives on its own line at the very
    /// bottom (`legalLine`).
    private var footer: some View {
        VStack(spacing: 10) {
            Button {
                Task { await buy() }
            } label: {
                ZStack {
                    Text(buttonTitle)
                        .opacity(buying ? 0 : 1)
                    if buying {
                        ProgressView()
                            .tint(Color.primary)
                    }
                }
            }
            .buttonStyle(UpgradeButtonStyle(busy: buying))
            .disabled(choice == nil || buying || isCurrentChoice)
            .animation(.easeInOut(duration: 0.2), value: buying)

            Text(renewalTerms)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
        }
    }

    /// A subscriber's way to Apple's own page. The small print is not here: it
    /// is pinned to the bottom of the screen (`legalLine`).
    @ViewBuilder
    private var accountLinks: some View {
        if isSubscriber {
            Button {
                managing = true
            } label: {
                Text("Manage subscription")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(session.subscription?.productId == "owner")
        }
    }

    /// Terms, Privacy and Restore on one quiet line at the very bottom, the way
    /// SuperGrok has them (Abel, 3 Nov 2026: "keep it so clean"). Required, not
    /// decorative: a screen selling an auto-renewable subscription must carry
    /// working links to the terms and the privacy policy, and Restore has to be
    /// reachable. No underlines, nothing beside Autocast's own words.
    private var legalLine: some View {
        HStack(spacing: 6) {
            Button("Terms of Use") { openURL(AutocastLinks.terms) }
            Text("·")
            Button("Privacy Policy") { openURL(AutocastLinks.privacy) }
            Text("·")
            Button(restoring ? "Restoring…" : "Restore Purchases") {
                Task { await restore() }
            }
            .disabled(restoring || buying)
        }
        .font(.system(size: 11.5, weight: .medium))
        .foregroundStyle(.secondary)
        .buttonStyle(.plain)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .frame(maxWidth: .infinity)
    }

    /// SuperGrok's wording: "Upgrade to <plan>", for somebody on Free as much
    /// as for somebody moving up.
    private var buttonTitle: String {
        guard let choice else { return "Upgrade to Autocast \(tier.name)" }
        if isSubscriber && isCurrentChoice { return "Your current plan" }
        if hasTrial(choice) && !isSubscriber { return "Start \(trialText(choice).lowercased())" }
        return "Upgrade to Autocast \(tier.name)"
    }

    // MARK: - Words

    private func renewalLine(_ plan: MyPlan, _ date: Date) -> String {
        let when = date.formatted(date: .long, time: .omitted)
        if plan.isTrial { return "Trial ends \(when)" }
        return plan.autoRenew == false ? "Ends \(when)" : "Renews \(when)"
    }

    private func trialText(_ product: Product) -> String {
        guard let period = product.subscription?.introductoryOffer?.period else { return "Free trial" }
        let unit: String
        switch period.unit {
        case .day: unit = period.value == 1 ? "day" : "days"
        case .week: unit = period.value == 1 ? "week" : "weeks"
        case .month: unit = period.value == 1 ? "month" : "months"
        case .year: unit = period.value == 1 ? "year" : "years"
        @unknown default: unit = "days"
        }
        return "\(period.value) \(unit) free"
    }

    /// The one line beside the button. The tile above already says the price
    /// and how often it is billed; this says it renews and how to stop it.
    private var renewalTerms: String {
        guard let choice else {
            return "Renews automatically. Cancel anytime."
        }
        let period = billsYearly(tier) ? "year" : "month"
        if hasTrial(choice) && !isSubscriber {
            return "\(trialText(choice)), then \(choice.displayPrice) a \(period). Renews automatically. Cancel anytime."
        }
        if isSubscriber && !isCurrentChoice {
            return "Moving up starts now and is prorated."
        }
        return "Renews automatically. Cancel anytime."
    }

    // MARK: - StoreKit

    private func load() async {
        // Whatever the session already fetched at launch, which is the usual
        // case and costs nothing.
        if !session.storeProducts.isEmpty {
            products = session.storeProducts
            loading = false
        }
        if products.isEmpty {
            await session.loadProducts()
            products = session.storeProducts
            loading = false
        }

        // Start on the tier they are on, or the recommended one -- as long as
        // it is one that is sold. A monthly subscriber starts on Monthly, so
        // an Ultra one (monthly only) still sees their own plan.
        if let id = session.subscription?.productId, id.hasSuffix(".monthly") { yearly = false }
        if let currentTier { tier = currentTier }
        if !offered.contains(tier) { tier = offered.first ?? .pro }

        await session.loadPlanTiers()
        await session.refreshCredits()

        // 🔴 Deliberately after `loading = false`. Trial eligibility is a
        // second round trip, and holding the prices behind it meant the sheet
        // said "Loading plans…" for both. The badge can arrive late; the price
        // cannot.
        guard let group = products.first?.subscription?.subscriptionGroupID else { return }
        trialEligible = await Product.SubscriptionInfo.isEligibleForIntroOffer(for: group)
    }

    private func buy() async {
        guard let choice else { return }
        buying = true
        defer { buying = false }
        var options: Set<Product.PurchaseOption> = []
        // Bound to this Autocast user, so the server refuses anyone else's receipt.
        if let userID = session.userID { options.insert(.appAccountToken(userID)) }
        do {
            switch try await choice.purchase(options: options) {
            case .success(let verification):
                guard case .verified = verification else {
                    session.lastError = "Apple couldn’t confirm that purchase."
                    return
                }
                // 🔴 The welcome first, the server after. Apple has confirmed
                // the purchase on the phone already; waiting for
                // `verify-purchase` before saying so left a spinner on the
                // button for up to a minute (Netro, 18 Oct 2026). The welcome
                // fills in the month's numbers when the server has them.
                welcomed = tier
                buying = false
                await session.completePurchase(verification)
                await session.refreshCredits()
            case .pending:
                // Ask to Buy, or a card that needs another step: nothing is
                // bought yet, and saying nothing looked like a frozen button.
                session.lastError = "Your purchase is waiting for approval. Your plan starts as soon as it goes through."
            case .userCancelled:
                break
            @unknown default:
                break
            }
        } catch {
            session.lastError = "The purchase didn’t go through. You weren’t charged."
        }
    }

    private func restore() async {
        restoring = true
        defer { restoring = false }
        try? await AppStore.sync()
        // Announced, not silent. Restore is a button somebody pressed on
        // purpose, so a server that refuses the receipt -- because it belongs
        // to another Autocast account -- has to say so. It used to swallow
        // that and show "none found", which is a different thing entirely and
        // sent people looking in the wrong place.
        await session.claimPurchasesAfterSignIn()
        await session.syncPurchases()
        await session.refreshCredits()
        if session.subscription?.isPro == true {
            close()
        } else if (session.lastError ?? "").isEmpty {
            session.lastError = "No Autocast subscription was found for this Apple ID."
        }
    }
}

// MARK: - Pieces

/// This month's usage as a bar and a sentence: how much is left, and when it
/// fills up again. (Was a second `CreditsMeter`, the same name as the You
/// page's -- two types of one name in one module do not compile.)
struct PaywallUsageMeter: View {
    let credits: CreditsStanding

    private var resets: String {
        guard let date = credits.resets else { return "" }
        return " · back on \(date.formatted(.dateTime.month(.abbreviated).day()))"
    }

    var body: some View {
        VStack(spacing: 6) {
            ProgressView(value: credits.fractionLeft)
                .tint(Theme.proGreen)
            Text("\(UsageFormat.percent(credits.percentLeft)) of this month left\(resets)")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}

/// One line of what a plan includes.
private struct PlanFeature: Hashable {
    let symbol: String
    let text: String
}

/// SuperGrok's list: an outline symbol and the words, no marks, no circles.
///
/// Keyed by the words, so when the plan changes a line the two plans share
/// stays where it is (sliding if it has to) while the others cross-fade.
private struct FeatureList: View {
    let features: [PlanFeature]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(features, id: \.text) { feature in
                HStack(spacing: 14) {
                    Image(systemName: feature.symbol)
                        .font(.system(size: 16))
                        .foregroundStyle(.primary)
                        .frame(width: 22)
                        .accessibilityHidden(true)
                    Text(feature.text)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// SuperGrok's plan switch: the plans in one soft capsule, the picked one on
/// a lighter pill that slides to it.
private struct TierSwitch: View {
    let tiers: [Tier]
    let chosen: Tier
    let pick: (Tier) -> Void

    @Namespace private var pill

    var body: some View {
        HStack(spacing: 2) {
            ForEach(tiers) { option in
                Button {
                    pick(option)
                } label: {
                    Text(option.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(option == chosen ? Color.primary : Color.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background {
                            if option == chosen {
                                Capsule()
                                    .fill(Color.paywallPill)
                                    .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
                                    .matchedGeometryEffect(id: "pill", in: pill)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(option == chosen ? .isSelected : [])
            }
        }
        .padding(4)
        .background(Color.primary.opacity(0.06), in: Capsule())
    }
}

/// One way to pay, as SuperGrok's tile: a round mark that fills when picked,
/// a "Save" badge on the yearly one, the price, and how often it is billed.
/// The only way to pay (Ultra, monthly) has nothing to pick, so no mark.
private struct PriceTile: View {
    let price: String
    let note: String
    let badge: String?
    let chosen: Bool
    let selectable: Bool
    let tap: () -> Void

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
    }

    private var lit: Bool { chosen && selectable }

    var body: some View {
        Button(action: tap) {
            VStack(alignment: .leading, spacing: 10) {
                if selectable || badge != nil {
                    HStack(spacing: 6) {
                        if selectable {
                            if lit {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 22))
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(Theme.onAccent, Theme.accent)
                            } else {
                                Circle()
                                    .strokeBorder(Color.primary.opacity(0.22), lineWidth: 1.5)
                                    .frame(width: 22, height: 22)
                            }
                        }
                        Spacer(minLength: 0)
                        if let badge {
                            Text(badge)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Theme.accent)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Theme.accent.opacity(0.14), in: Capsule())
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(price)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .contentTransition(.numericText())
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.03), in: shape)
            .overlay {
                shape.strokeBorder(
                    lit ? Theme.accent : Color.primary.opacity(0.08),
                    lineWidth: lit ? 2 : 1
                )
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .disabled(!selectable)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}

/// SuperGrok's button: a full-width pill in the text colour (white on the
/// dark card, black on the light one), going grey while Apple's sheet opens.
private struct UpgradeButtonStyle: ButtonStyle {
    let busy: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let quiet = busy || !isEnabled
        configuration.label
            .font(.body.weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .frame(maxWidth: .infinity, minHeight: 52)
            .padding(.horizontal, 16)
            .foregroundStyle(.background)
            .background(quiet ? Color.primary.opacity(0.22) : Color.primary, in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.snappy(duration: 0.18), value: configuration.isPressed)
    }
}

private extension Color {
    /// The lit pill of the plan switch: white on the light page, a lifted grey
    /// on the dark one (SuperGrok's).
    static let paywallPill = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(white: 0.20, alpha: 1)
            : UIColor.white
    })
}
