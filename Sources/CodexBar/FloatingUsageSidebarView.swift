import CodexBarCore
import SwiftUI

typealias FloatingSidebarAccountProjection = @MainActor (UsageProvider) ->
    AccountProjection

private extension ProviderAccountIdentity {
    var floatingSidebarSelectionKey: String {
        "\(self.source):\(self.opaqueID)"
    }
}

private struct FloatingSidebarContentSizeKey: PreferenceKey {
    static let defaultValue = CGSize.zero

    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

private struct FloatingSidebarNotchShape: Shape {
    func path(in rect: CGRect) -> Path {
        let shoulder = min(30, rect.height / 5)
        var path = Path()
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addCurve(
            to: CGPoint(x: rect.minX, y: rect.minY + shoulder),
            control1: CGPoint(x: rect.maxX - 2, y: rect.minY + shoulder * 0.65),
            control2: CGPoint(x: rect.minX + shoulder * 0.65, y: rect.minY + shoulder))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - shoulder))
        path.addCurve(
            to: CGPoint(x: rect.maxX, y: rect.maxY),
            control1: CGPoint(x: rect.minX + shoulder * 0.65, y: rect.maxY - shoulder),
            control2: CGPoint(x: rect.maxX - 2, y: rect.maxY - shoulder * 0.65))
        path.closeSubpath()
        return path
    }
}

private struct FloatingSidebarGearArcShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + 7, y: rect.minY + 2))
        path.addCurve(
            to: CGPoint(x: rect.maxX - 2, y: rect.maxY - 5),
            control1: CGPoint(x: rect.midX + 9, y: rect.minY + 2),
            control2: CGPoint(x: rect.maxX - 2, y: rect.midY - 2))
        return path
    }
}

@MainActor
struct FloatingUsagePillView: View {
    @Bindable var store: UsageStore
    @Bindable var settings: SettingsStore
    @Bindable var presentation: FloatingSidebarPresentation
    let accountProjection: FloatingSidebarAccountProjection
    let openProvider: @MainActor (UsageProvider) -> Void
    let openSettings: @MainActor () -> Void
    @AppStorage("floatingSidebarCodexAccountID") private var selectedCodexAccountID = ""
    @AppStorage("floatingSidebarClaudeAccountID") private var selectedClaudeAccountID = ""
    @AppStorage("floatingSidebarHideExhaustedAccounts") private var hideExhaustedAccounts = false
    @AppStorage("selectedMenuProvider") private var selectedProviderID = ""
    @State private var isSettingsHovered = false

    var body: some View {
        ZStack(alignment: .leading) {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                self.expandedSidebar
            }
            .opacity(self.presentation.isTucked ? 0 : 1)
            .allowsHitTesting(!self.presentation.isTucked)

            Button {
                self.presentation.requestReveal?()
            } label: {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.black.opacity(0.96))
                    .frame(width: FloatingSidebarGeometry.tuckedWidth, height: 52)
            }
            .buttonStyle(.plain)
            .opacity(self.presentation.isTucked ? 1 : 0)
            .allowsHitTesting(self.presentation.isTucked)
            .accessibilityLabel("Show usage sidebar")
        }
        .frame(width: FloatingSidebarLayout.panelWidth)
        .background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: FloatingSidebarContentSizeKey.self,
                    value: proxy.size)
            }
        }
        .onPreferenceChange(FloatingSidebarContentSizeKey.self) { size in
            self.presentation.requestResize?(size)
        }
        .animation(.easeOut(duration: 0.14), value: self.presentation.isTucked)
    }

    private var expandedSidebar: some View {
        let maximumProviderHeight = max(
            FloatingSidebarLayout.providerRowHeight,
            self.presentation.maximumContentHeight - FloatingSidebarLayout.settingsHeight + 9)
        return VStack(spacing: -9) {
            ScrollView(.vertical, showsIndicators: false) {
                self.providerNotch
            }
            .frame(maxHeight: maximumProviderHeight)

            self.settingsHandle
        }
        .frame(width: FloatingSidebarLayout.sidebarWidth)
    }

    private var providerNotch: some View {
        VStack(spacing: 12) {
            ForEach(self.providers, id: \.self) { provider in
                self.providerRow(provider)
            }
        }
        .padding(.vertical, 28)
        .frame(width: FloatingSidebarLayout.sidebarWidth)
        .background {
            FloatingSidebarNotchShape()
                .fill(Color.black.opacity(0.96))
        }
        .overlay {
            FloatingSidebarNotchShape()
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.45), radius: 15, x: -3, y: 4)
    }

    private func providerRow(_ provider: UsageProvider) -> some View {
        let projection = self.accountProjection(provider)
        let subscriptionOptions = self.filteredAccountOptions(projection.subscriptions, provider: provider)
        let apiSpendOptions = self.filteredAccountOptions(projection.apiSpend, provider: provider)
        let options = subscriptionOptions + apiSpendOptions
        let selectedID = switch provider {
        case .codex: self.selectedCodexAccountID
        case .claude: self.selectedClaudeAccountID
        default: ""
        }
        let usableOptions = options.filter { $0.snapshot != nil }
        let selectableOptions = usableOptions.isEmpty ? options : usableOptions
        let option = selectableOptions.first(where: { $0.id.floatingSidebarSelectionKey == selectedID })
            ?? selectableOptions.first(where: \.isActive)
            ?? selectableOptions.first
        return FloatingUsagePillItem(
            provider: provider,
            snapshot: option == nil ? self.fallbackSnapshot(for: provider) : option?.snapshot,
            isSelected: self.selectedProviderID == provider.instanceID.rawValue,
            accentColor: ProviderAccentPalette.color(for: provider),
            showsUsed: self.showsUsed(for: provider),
            hidePersonalInfo: self.settings.hidePersonalInfo,
            accountDisplayLabel: option?.displayLabel,
            subscriptionOptions: subscriptionOptions,
            apiSpendOptions: apiSpendOptions,
            selectedAccountID: option?.id.floatingSidebarSelectionKey,
            statusMessage: option?.error ?? projection.lastError ?? self.statusMessage(for: provider),
            isRefreshing: projection.isRefreshing
                || self.store.refreshingProviders.contains(provider.instanceID),
            presentation: self.presentation,
            selectAccount: { id in self.selectAccount(id, for: provider) },
            openProvider: { selected in
                self.selectedProviderID = selected.instanceID.rawValue
                self.openProvider(selected)
            })
            .frame(height: FloatingSidebarLayout.providerRowHeight)
    }

    private var settingsHandle: some View {
        ZStack(alignment: .topTrailing) {
            FloatingSidebarGearArcShape()
                .stroke(Color.white.opacity(0.22), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .frame(width: FloatingSidebarLayout.sidebarWidth, height: FloatingSidebarLayout.settingsHeight)

            if self.isSettingsHovered {
                Button(action: self.openSettings) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(.white.opacity(0.92))
                        .frame(width: 46, height: 46)
                        .background(Circle().fill(Color.black.opacity(0.98)))
                        .overlay(Circle().stroke(Color.white.opacity(0.12), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .transition(.scale(scale: 0.72, anchor: .topTrailing).combined(with: .opacity))
                .help("Settings")
                .accessibilityLabel("Open Settings")
            }
        }
        .frame(width: FloatingSidebarLayout.sidebarWidth, height: FloatingSidebarLayout.settingsHeight)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.14)) {
                self.isSettingsHovered = hovering
            }
        }
    }

    private var providers: [UsageProvider] {
        self.store.enabledFirstPartyProvidersForDisplay()
    }

    private func filteredAccountOptions(
        _ rawOptions: [ProviderAccountUsageSnapshot],
        provider: UsageProvider) -> [ProviderAccountUsageSnapshot]
    {
        guard self.hideExhaustedAccounts else { return rawOptions }
        let available = rawOptions.filter { !self.isExhausted(provider: provider, snapshot: $0.snapshot) }
        return available.isEmpty ? rawOptions : available
    }

    private func selectAccount(_ id: String, for provider: UsageProvider) {
        switch provider {
        case .codex:
            self.selectedCodexAccountID = id
        case .claude:
            self.selectedClaudeAccountID = id
        default:
            break
        }
    }

    private func fallbackSnapshot(for provider: UsageProvider) -> UsageSnapshot? {
        FloatingSidebarSnapshotResolver.snapshot(
            for: provider,
            providerSnapshot: self.store.presentationSnapshot(for: provider),
            claudeAccounts: [])
    }

    private func statusMessage(for provider: UsageProvider) -> String? {
        if self.store.error(for: provider) != nil || self.store.diagnostic(for: provider) != nil {
            return self.store.userFacingError(for: provider)
        }
        if self.store.refreshingProviders.contains(provider.instanceID),
           self.fallbackSnapshot(for: provider) == nil
        {
            return "Refreshing"
        }
        return nil
    }

    private func showsUsed(for provider: UsageProvider) -> Bool {
        ProviderUsageDisplayPolicy.showsUsed(
            for: provider,
            defaultShowUsed: self.settings.usageBarsShowUsed)
    }

    private func isExhausted(provider: UsageProvider, snapshot: UsageSnapshot?) -> Bool {
        FloatingSidebarMetricResolver.metric(provider: provider, snapshot: snapshot, showsUsed: true)?
            .usedPercent ?? 0 >= 100
    }
}

private enum FloatingSidebarStatusColor {
    static func color(provider: UsageProvider, usedPercent: Double, brandColor: Color) -> Color {
        guard provider == .claude else { return brandColor }
        let providerColor = ProviderDescriptorRegistry.descriptor(for: provider).branding.color
        let riskColor = ProviderUsageRiskPalette.color(usedPercent: usedPercent, brandColor: providerColor)
        if riskColor == providerColor { return brandColor }
        return Color(red: riskColor.red, green: riskColor.green, blue: riskColor.blue)
    }
}

@MainActor
private struct FloatingUsagePillItem: View {
    let provider: UsageProvider
    let snapshot: UsageSnapshot?
    let isSelected: Bool
    let accentColor: ProviderColor
    let showsUsed: Bool
    let hidePersonalInfo: Bool
    let accountDisplayLabel: String?
    let subscriptionOptions: [ProviderAccountUsageSnapshot]
    let apiSpendOptions: [ProviderAccountUsageSnapshot]
    let selectedAccountID: String?
    let statusMessage: String?
    let isRefreshing: Bool
    @Bindable var presentation: FloatingSidebarPresentation
    let selectAccount: @MainActor (String) -> Void
    let openProvider: @MainActor (UsageProvider) -> Void
    @State private var isAccountPickerPresented = false
    @State private var isHovered = false

    private var accountOptions: [ProviderAccountUsageSnapshot] {
        self.subscriptionOptions + self.apiSpendOptions
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button {
                self.openProvider(self.provider)
            } label: {
                VStack(spacing: 4) {
                    ZStack {
                        Circle()
                            .stroke(Color.white.opacity(0.14), lineWidth: 3)
                        if let metric = self.metric {
                            Circle()
                                .trim(from: 0, to: max(0.02, metric.ringFraction))
                                .stroke(
                                    self.statusColor(usedPercent: metric.usedPercent),
                                    style: StrokeStyle(lineWidth: 3, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                        }
                        self.providerMark
                    }
                    .frame(width: 40, height: 40)

                    if let metric = self.metric {
                        self.valueLabel(
                            metric.compactPercent,
                            direction: self.rowStatusLabel ?? metric.directionLabel,
                            available: true)
                    } else if let costText = self.costText {
                        self.valueLabel(
                            costText,
                            direction: self.rowStatusLabel ?? (self.showsUsed ? "used" : "remaining"),
                            available: true)
                    } else {
                        self.valueLabel(
                            "—",
                            direction: self.rowStatusLabel ?? (self.showsUsed ? "used" : "remaining"),
                            available: false)
                    }
                }
                .padding(.horizontal, 5)
                .padding(.vertical, 3)
                .background {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(self.brandColor.opacity(self.isSelected ? 0.18 : (self.isHovered ? 0.08 : 0)))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(self.brandColor.opacity(self.isSelected ? 0.72 : 0), lineWidth: 1)
                }
            }
            .buttonStyle(.plain)
            .help(self.helpText)
            .accessibilityLabel(self.helpText)
            .accessibilityHint("Opens \(self.metadata.displayName) details")
            .accessibilityAddTraits(self.isSelected ? .isSelected : [])

            if self.accountOptions.count > 1 {
                Button {
                    self.isAccountPickerPresented.toggle()
                } label: {
                    Image(systemName: "chevron.down.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(self.brandColor, Color.black.opacity(0.9))
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Color.black.opacity(0.9)))
                }
                .buttonStyle(.plain)
                .offset(y: -4)
                .help("Choose \(self.metadata.displayName) account")
                .accessibilityLabel("Choose \(self.metadata.displayName) account")
                .popover(isPresented: self.$isAccountPickerPresented, arrowEdge: .leading) {
                    self.accountPicker
                        .preferredColorScheme(.dark)
                }
            }
        }
        .onHover { self.isHovered = $0 }
        .overlay(alignment: .leading) {
            if self.isHovered, !self.isAccountPickerPresented {
                self.detailCard
                    .offset(x: -205)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .trailing)))
                    .allowsHitTesting(false)
            }
        }
        .onChange(of: self.isAccountPickerPresented) { _, isPresented in
            self.presentation.isAccountPickerOpen = isPresented
        }
    }

    private func valueLabel(_ value: String, direction: String, available: Bool) -> some View {
        VStack(spacing: 0) {
            Text(value)
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(available ? 0.85 : 0.35))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(direction)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white.opacity(available ? 0.45 : 0.28))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    @ViewBuilder
    private var providerMark: some View {
        if let image = ProviderBrandIcon.image(for: self.provider) {
            Image(nsImage: image)
                .resizable()
                .renderingMode(.template)
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(self.hasValue ? self.brandColor : self.brandColor.opacity(0.45))
                .frame(width: 20, height: 20)
        } else {
            Image(systemName: "sparkle")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(self.hasValue ? self.brandColor : self.brandColor.opacity(0.45))
                .frame(width: 20, height: 20)
        }
    }

    private var metadata: ProviderMetadata {
        ProviderDescriptorRegistry.descriptor(for: self.provider).metadata
    }

    private var metric: FloatingUsageMetric? {
        FloatingSidebarMetricResolver.metric(
            provider: self.provider,
            snapshot: self.snapshot,
            showsUsed: self.showsUsed)
    }

    private var costText: String? {
        guard let cost = self.snapshot?.providerCost else { return nil }
        let amount: Double
        if self.showsUsed {
            amount = cost.used
        } else if let balance = cost.balance {
            amount = balance
        } else if cost.limit > 0 {
            amount = max(0, cost.limit - cost.used)
        } else {
            return nil
        }
        guard amount.isFinite else { return nil }
        let prefix = cost.currencyCode.uppercased() == "USD" ? "$" : "\(cost.currencyCode.uppercased()) "
        return prefix + String(format: amount >= 100 ? "%.0f" : "%.2f", amount)
    }

    private var hasValue: Bool {
        self.metric != nil || self.costText != nil
    }

    private var brandColor: Color {
        Color(red: self.accentColor.red, green: self.accentColor.green, blue: self.accentColor.blue)
    }

    private var accountLabel: String? {
        guard !self.hidePersonalInfo else { return nil }
        return self.accountDisplayLabel ?? self.snapshot?.identity?.accountEmail
    }

    private var rowStatusLabel: String? {
        if self.statusMessage != nil {
            return self.snapshot == nil ? "error" : "stale"
        }
        if self.isRefreshing, !self.hasValue {
            return "refreshing"
        }
        return nil
    }

    private var helpText: String {
        let account = self.accountLabel.map { " · \($0)" } ?? ""
        if let metric {
            let status = self.rowStatusLabel.map { " · \($0)" } ?? ""
            return "\(self.metadata.displayName)\(account) · \(metric.compactPercent) \(metric.directionLabel)\(status)"
        }
        if let costText {
            let status = self.rowStatusLabel.map { " · \($0)" } ?? ""
            return "\(self.metadata.displayName)\(account) · \(costText) "
                + (self.showsUsed ? "used" : "remaining") + status
        }
        if let statusMessage {
            return "\(self.metadata.displayName)\(account) · \(self.rowStatusLabel ?? "unavailable"): \(statusMessage)"
        }
        return "\(self.metadata.displayName)\(account) · usage unavailable"
    }

    private var accountPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Choose \(self.metadata.displayName) account")
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 6)
                .padding(.bottom, 2)

            self.accountSection("Subscriptions", options: self.subscriptionOptions)
            self.accountSection("API spend", options: self.apiSpendOptions)

            Divider()

            Button {
                self.isAccountPickerPresented = false
                self.openProvider(self.provider)
            } label: {
                Label("\(self.metadata.displayName) details", systemImage: "arrow.up.right.square")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(6)
        }
        .padding(8)
        .frame(width: 230)
    }

    @ViewBuilder
    private func accountSection(
        _ title: String,
        options: [ProviderAccountUsageSnapshot]) -> some View
    {
        if !options.isEmpty {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.top, 3)

            ForEach(options) { option in
                let isSelected = option.id.floatingSidebarSelectionKey == self.selectedAccountID
                Button {
                    self.selectAccount(option.id.floatingSidebarSelectionKey)
                    self.isAccountPickerPresented = false
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: isSelected
                            ? "checkmark.circle.fill"
                            : "circle")
                            .foregroundStyle(isSelected
                                ? self.brandColor
                                : Color.secondary)
                            .accessibilityHidden(true)
                        Text(self.hidePersonalInfo ? "Account" : option.displayLabel)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        self.accountOptionValue(option)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 6)
                .padding(.vertical, 5)
                .accessibilityLabel(self.hidePersonalInfo ? "Account" : option.displayLabel)
                .accessibilityValue(isSelected ? "Selected" : "Not selected")
                .accessibilityHint("Shows this account in the sidebar")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
    }

    @ViewBuilder
    private func accountOptionValue(_ option: ProviderAccountUsageSnapshot) -> some View {
        if let metric = FloatingSidebarMetricResolver.metric(
            provider: self.provider,
            snapshot: option.snapshot,
            showsUsed: self.showsUsed)
        {
            Text(metric.compactPercent)
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(option.error == nil ? Color.secondary : Color.orange)
                .frame(width: 48, alignment: .trailing)
        } else if let error = option.error {
            Text(error)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.orange)
                .lineLimit(1)
                .frame(width: 72, alignment: .trailing)
        } else {
            Text("Loading")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 72, alignment: .trailing)
        }
    }

    private var detailCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Circle()
                    .fill(self.brandColor)
                    .frame(width: 7, height: 7)
                Text(self.metadata.displayName)
                    .font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 0)
            }

            if let accountLabel = self.accountLabel {
                Text(accountLabel)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.58))
                    .lineLimit(1)
            }

            if let metric = self.metric {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(metric.compactPercent)
                        .font(.system(size: 18, weight: .bold))
                        .monospacedDigit()
                    Text(metric.directionLabel)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                }
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.12))
                        Capsule()
                            .fill(self.statusColor(usedPercent: metric.usedPercent))
                            .frame(width: geometry.size.width * metric.ringFraction)
                    }
                }
                .frame(height: 5)
            } else if let costText = self.costText {
                Text("\(costText) \(self.showsUsed ? "used" : "remaining")")
                    .font(.system(size: 14, weight: .bold))
                    .monospacedDigit()
            } else if self.rowStatusLabel == "refreshing" {
                Text("Refreshing…")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.65))
            } else {
                Text("Usage unavailable")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
            }

            if let statusMessage {
                HStack(alignment: .top, spacing: 5) {
                    Image(systemName: self.rowStatusLabel == "stale"
                        ? "clock.arrow.circlepath"
                        : "exclamationmark.triangle.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(self.rowStatusLabel == "stale" ? .yellow : .orange)
                    Text(self.rowStatusLabel == "stale"
                        ? "Showing the last successful update: \(statusMessage)"
                        : statusMessage)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.white.opacity(0.58))
                        .lineLimit(3)
                }
            }

            if let snapshot {
                Text("Updated \(snapshot.updatedAt.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.38))
            }
        }
        .foregroundStyle(.white.opacity(0.92))
        .padding(12)
        .frame(width: 195, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.black.opacity(0.96)))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(self.brandColor.opacity(0.22), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.42), radius: 14, x: -2, y: 4)
    }

    private func statusColor(usedPercent: Double) -> Color {
        FloatingSidebarStatusColor.color(
            provider: self.provider,
            usedPercent: usedPercent,
            brandColor: self.brandColor)
    }
}
