import AppKit
import SwiftUI
import AIUsageMeterCore

/// Every plan the machine can reach. The plan in use sits on top with a
/// verdict — keep going, or switch — and every other plan follows.
///
/// Built from the app's own parts — premium card surfaces, the glass plan chip
/// and status dot of `DetailCard`, `UsageBar` for each window — so the board
/// reads as the same app as Settings rather than a new one bolted on.
struct PlanBoardView: View {
    @Bindable var appState: AppState
    var onRefresh: () -> Void

    var body: some View {
        // Countdowns go stale in minutes; redraw on a short tick. The advice
        // itself is recomputed by AppState on its own timer.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let rows = appState.planRows
            let workspaces = appState.unconnectedWorkspaces
            let services = ServiceType.allCases.filter { type in
                rows.contains { $0.service == type } || (type == .codex && !workspaces.isEmpty)
            }
            let inUse = Dictionary(uniqueKeysWithValues: services.compactMap { service in
                appState.inUseRow(for: service, in: rows).map { (service, $0) }
            })

            VStack(spacing: 14) {
                if services.isEmpty {
                    emptyState
                } else {
                    currentSection(services: services, rows: rows, inUse: inUse, now: context.date)

                    ForEach(services, id: \.self) { service in
                        let others = rows.filter { $0.service == service && $0.id != inUse[service]?.id }
                        let reachable = service == .codex ? workspaces : []
                        if !others.isEmpty || !reachable.isEmpty {
                            BoardSection(title: "\(service.displayName) · \(L.otherPlans)") {
                                PlanCard(
                                    rows: others,
                                    workspaces: reachable,
                                    pick: appState.recommendations[service]?.useNow,
                                    evaluations: appState.recommendations[service]?.evaluations ?? [:],
                                    now: context.date,
                                    appState: appState,
                                    onRefresh: onRefresh
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        HStack(spacing: 8) {
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
            Text(L.noPlansYet)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(12)
        .premiumCard()
    }

    /// What each provider is being used on now, with the verdict. A provider
    /// with no plan known to be in use gets the recommendation instead.
    @ViewBuilder
    private func currentSection(services: [ServiceType], rows: [PlanRow],
                                inUse: [ServiceType: PlanRow], now: Date) -> some View {
        let shown = services.filter { service in
            inUse[service] != nil || appState.recommendations[service].map { $0.reason != .noData } == true
        }
        if !shown.isEmpty {
            BoardSection(title: L.inUse) {
                VStack(spacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.element) { index, service in
                        if index > 0 { Divider().opacity(0.2) }
                        if let row = inUse[service] {
                            CurrentBlock(row: row, advice: appState.recommendations[service], rows: rows,
                                         now: now, appState: appState, onRefresh: onRefresh)
                        } else if let advice = appState.recommendations[service] {
                            AdviceBlock(advice: advice, rows: rows, now: now)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .premiumCard()
            }
        }
    }
}

// MARK: - In use

/// The plan a provider is being used on, and whether to stay on it.
private struct CurrentBlock: View {
    let row: PlanRow
    let advice: PlanRecommendation?
    let rows: [PlanRow]
    let now: Date
    let appState: AppState
    let onRefresh: () -> Void

    private var brand: Color { row.service.brandColor }
    private var pickRow: PlanRow? { advice?.useNow.flatMap { id in rows.first { $0.id == id } } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(brand)
                    .frame(width: 8, height: 8)
                Text(row.service.displayName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(brand)
                Spacer()
                if let plan = PlanText.plan(row) {
                    PlanChip(text: plan, color: brand)
                }
            }

            PlanHeading(row: row, prominent: true)

            WindowsView(row: row, now: now, onRefresh: onRefresh)

            verdict
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .contextMenu { RowMenu(row: row, appState: appState) }
    }

    @ViewBuilder
    private var verdict: some View {
        if let advice, advice.reason != .noData {
            if advice.useNow == row.id {
                keep(advice)
            } else if let pickRow {
                switchTo(pickRow, advice: advice)
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    VerdictLine(icon: "exclamationmark.circle.fill",
                                color: ThemeManager.shared.current.statusWarning,
                                text: L.everythingOut)
                    if let line = Handoff.line(advice: advice, rows: rows, now: now) {
                        SecondaryLine(text: line)
                    }
                }
            }
        }
    }

    /// This is the plan to spend: say so, and why.
    private func keep(_ advice: PlanRecommendation) -> some View {
        let text: String
        switch advice.reason {
        case .expiresFirst: text = L.keepGoingResetsFirst
        case .onlyOption: text = L.keepGoingOnlyOption
        case .mostRoom: text = L.keepGoingMostRoom
        case .allOut, .noData: text = L.everythingOut
        }
        let pace = advice.reason == .expiresFirst ? Pace.text(advice.evaluations[row.id]) : nil
        let next = Handoff.line(advice: advice, rows: rows, now: now)

        return VStack(alignment: .leading, spacing: 3) {
            VerdictLine(icon: "checkmark.circle.fill",
                        color: ThemeManager.shared.current.statusSuccess,
                        text: text)
            if let pace { SecondaryLine(text: pace) }
            if let next { SecondaryLine(text: next) }
        }
    }

    /// Another plan should go first: name it, say why, and hand over the
    /// command that starts a session on it.
    private func switchTo(_ pick: PlanRow, advice: PlanRecommendation) -> some View {
        let evaluation = advice.evaluations[pick.id]
        var why: String
        switch advice.reason {
        case .expiresFirst:
            why = evaluation?.expiresAt.map { L.resetsFirstIn(Durations.compact($0.timeIntervalSince(now))) }
                ?? L.resetsFirst
            if let pace = Pace.text(evaluation) { why += " · " + pace }
        case .onlyOption: why = L.onlyPlanWithRoom
        case .mostRoom: why = L.nothingExpiring
        case .allOut, .noData: why = L.everythingOut
        }

        var blocked: String?
        if case .blocked(let until) = advice.evaluations[row.id]?.availability {
            blocked = until.map { "\(L.out) · \(L.freesAfter(Durations.compact($0.timeIntervalSince(now))))" } ?? L.out
        }

        return VStack(alignment: .leading, spacing: 3) {
            if let blocked {
                Text(blocked)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(ThemeManager.shared.current.statusDanger)
            }
            HStack(spacing: 6) {
                VerdictLine(icon: "arrow.right.circle.fill", color: pick.service.brandColor,
                            text: L.switchTo(PlanText.name(pick)))
                Spacer(minLength: 4)
                CopyCommandButton(row: pick)
            }
            SecondaryLine(text: why)
        }
    }
}

/// With nothing known to be in use, what to start on.
private struct AdviceBlock: View {
    let advice: PlanRecommendation
    let rows: [PlanRow]
    let now: Date

    private var row: PlanRow? { rows.first { $0.id == advice.useNow } }
    private var evaluation: PlanEvaluation? { advice.useNow.flatMap { advice.evaluations[$0] } }
    private var brand: Color { advice.service.brandColor }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(brand)
                    .frame(width: 8, height: 8)
                Text(advice.service.displayName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(brand)
                Spacer()
                if let row {
                    PlanChip(text: [L.recommended, PlanText.plan(row)].compactMap { $0 }.joined(separator: " · "),
                             color: brand, prominent: true)
                }
            }

            if let row {
                PlanHeading(row: row, prominent: true)
                WindowsView(row: row, now: now, onRefresh: {})
            } else {
                Text(L.everythingOut)
                    .font(.system(size: 16, weight: .bold))
            }

            VStack(alignment: .leading, spacing: 3) {
                ForEach(reasonLines, id: \.self) { SecondaryLine(text: $0) }
            }
        }
        .padding(.vertical, 12)
    }

    private var reasonLines: [String] {
        var lines: [String] = []
        switch advice.reason {
        case .expiresFirst:
            var line = L.resetsFirst
            if let pace = Pace.text(evaluation) { line += " · " + pace }
            lines.append(line)
        case .mostRoom:
            lines.append(L.nothingExpiring)
        case .onlyOption:
            lines.append(L.onlyPlanWithRoom)
        case .allOut:
            if row != nil { lines.append(L.everythingOut) }
        case .noData:
            break
        }
        if let line = Handoff.line(advice: advice, rows: rows, now: now) { lines.append(line) }
        return lines
    }
}

// MARK: - Other plans

/// One provider's other plans in a single card, divided like the Settings lists.
private struct PlanCard: View {
    let rows: [PlanRow]
    let workspaces: [UnconnectedWorkspace]
    let pick: String?
    let evaluations: [String: PlanEvaluation]
    let now: Date
    let appState: AppState
    let onRefresh: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 { Divider().opacity(0.2) }
                PlanRowView(
                    row: row,
                    isPick: row.id == pick,
                    evaluation: evaluations[row.id],
                    now: now,
                    appState: appState,
                    onRefresh: onRefresh
                )
            }

            ForEach(Array(workspaces.enumerated()), id: \.element.id) { index, workspace in
                if index > 0 || !rows.isEmpty { Divider().opacity(0.2) }
                WorkspaceRowView(workspace: workspace, appState: appState)
            }
        }
        .padding(.horizontal, 12)
        .premiumCard()
    }
}

private struct PlanRowView: View {
    let row: PlanRow
    let isPick: Bool
    let evaluation: PlanEvaluation?
    let now: Date
    let appState: AppState
    let onRefresh: () -> Void

    private var login: ServiceViewModel { row.login }
    private var brand: Color { row.service.brandColor }
    private var isRateLimited: Bool { login.lastError.map(WindowText.isRateLimit) ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                Circle()
                    .fill(login.isAuthError && !isRateLimited ? ThemeManager.shared.current.statusDanger : brand)
                    .frame(width: 8, height: 8)

                PlanHeading(row: row, notes: notes)

                Spacer(minLength: 6)

                if isPick {
                    PlanChip(text: [L.recommended, PlanText.plan(row)].compactMap { $0 }.joined(separator: " · "),
                             color: brand, prominent: true)
                } else if let plan = PlanText.plan(row) {
                    PlanChip(text: plan, color: brand)
                }
            }

            WindowsView(row: row, now: now, onRefresh: onRefresh)
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .contextMenu { RowMenu(row: row, appState: appState) }
    }

    /// A plan that's out, and folded duplicate logins.
    private var notes: [String] {
        var notes: [String] = []
        if case .blocked(let until) = evaluation?.availability {
            notes.append(until.map { L.freesAfter(Durations.compact($0.timeIntervalSince(now))) } ?? L.out)
        }
        if row.extraLogins > 0 { notes.append(L.loginCount(row.extraLogins + 1)) }
        return notes
    }
}

private struct WorkspaceRowView: View {
    let workspace: UnconnectedWorkspace
    let appState: AppState

    private var brand: Color { ServiceType.codex.brandColor }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            // Hollow: the plan exists, but nothing here can read it yet.
            Circle()
                .strokeBorder(brand.opacity(0.6), lineWidth: 1.5)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 1) {
                Text(workspace.workspace.displayName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                // The address on a line of its own: next to the buttons it was
                // cut down to "me@examp…", which identifies nobody.
                if let email = workspace.email {
                    Text(email)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text([workspace.workspace.planName, L.notConnected].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 6)

            if AccountRegistry.shared.isConnecting(workspace.workspace) {
                ProgressView().controlSize(.small)
            } else {
                Button {
                    AccountRegistry.shared.addAccount(service: .codex, workspace: workspace.workspace) {
                        appState.reloadAccounts(interactive: true)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "link")
                            .font(.system(size: 10))
                        Text(L.connect)
                            .font(.system(size: 11, weight: .medium))
                    }
                    .padding(.horizontal, 2)
                }
                .glassCapsuleButton()

                Button {
                    AccountRegistry.shared.dismissWorkspace(workspace.workspace)
                    appState.updateAdvice()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help(L.hide)
            }
        }
        .padding(.vertical, 12)
    }
}

// MARK: - Shared parts

/// A plan's name over its account: the org or nickname, then the full email
/// address — names repeat across people ("Personal"), addresses don't.
private struct PlanHeading: View {
    let row: PlanRow
    var prominent = false
    var notes: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(PlanText.name(row))
                .font(.system(size: prominent ? 16 : 14, weight: prominent ? .bold : .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: prominent ? 11 : 10))
                    .foregroundStyle(prominent ? HierarchicalShapeStyle.secondary : .tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private var subtitle: String {
        ([PlanText.email(row), PlanText.hiddenOrg(row)].compactMap { $0 } + notes)
            .joined(separator: " · ")
    }
}

/// A plan's windows as bars, or why there are none: throttled, signed out,
/// still loading.
private struct WindowsView: View {
    let row: PlanRow
    let now: Date
    let onRefresh: () -> Void

    private var login: ServiceViewModel { row.login }
    private var brand: Color { row.service.brandColor }
    private var isRateLimited: Bool { login.lastError.map(WindowText.isRateLimit) ?? false }

    var body: some View {
        if isRateLimited, let error = login.lastError {
            // A throttled provider isn't a broken account: say when it lifts.
            HStack(spacing: 8) {
                Image(systemName: "clock.badge")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Text(WindowText.stripped(error, account: login.account))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
            }
        } else if login.isAuthError {
            AuthErrorView(service: login, onRefresh: onRefresh)
        } else if !login.hasLoaded {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(L.updating)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
            }
        } else {
            HStack(spacing: 14) {
                ForEach(Array(login.usage.windows.enumerated()), id: \.element.id) { index, window in
                    UsageBar(
                        label: WindowText.label(window),
                        percentage: WindowText.remaining(window, now: now),
                        resetText: WindowText.reset(window, now: now),
                        color: WindowText.color(window, now: now, brand: brand, primary: index == 0)
                    )
                }
            }
        }
    }
}

/// An icon and a short, bold statement: the verdict on the plan in use.
private struct VerdictLine: View {
    let icon: String
    let color: Color
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(color)
            Text(text)
                .font(.system(size: 12, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct SecondaryLine: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Copies the command that starts a session on a plan, so "switch" is one
/// paste away.
private struct CopyCommandButton: View {
    let row: PlanRow
    @State private var copied = false

    var body: some View {
        Button {
            LaunchCommand.copy(for: row)
            withAnimation { copied = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                withAnimation { copied = false }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 10))
                Text(copied ? L.copied : L.copyCommand)
                    .font(.system(size: 11, weight: .medium))
            }
            .padding(.horizontal, 2)
        }
        .glassCapsuleButton()
        .help(LaunchCommand.text(for: row))
    }
}

/// Right-click actions on a plan.
private struct RowMenu: View {
    let row: PlanRow
    let appState: AppState

    var body: some View {
        if let account = row.login.account {
            Button(AccountRegistry.shared.isPinned(account) ? L.unpinFromMenuBar : L.pinToMenuBar) {
                AccountRegistry.shared.togglePinned(account)
                appState.menuBarNeedsRedraw += 1
            }
        }
        Button(L.copyLaunchCommand) {
            LaunchCommand.copy(for: row)
        }
    }
}

/// A settings-style section: small uppercase title over its card.
private struct BoardSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
                .tracking(0.5)
                .padding(.leading, 4)
            content
        }
    }
}

/// The plan badge from `DetailCard`: brand text in a tinted glass capsule. The
/// plan to use now gets the stronger tint.
private struct PlanChip: View {
    let text: String
    let color: Color
    var prominent: Bool = false

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(prominent ? Color.white : color)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .tintedCapsule(color.opacity(prominent ? 0.85 : 0.25))
    }
}

extension View {
    /// Tinted glass capsule. Offscreen snapshots can't draw glass — the whole
    /// capture comes back blank — so a render run gets the same tint flat.
    @ViewBuilder
    func tintedCapsule(_ tint: Color) -> some View {
        if AppState.isRenderRun {
            background(tint, in: Capsule())
        } else {
            glassEffect(.regular.tint(tint), in: .capsule)
        }
    }

    /// The app's glass capsule button, flattened the same way for snapshots.
    @ViewBuilder
    func glassCapsuleButton() -> some View {
        if AppState.isRenderRun {
            buttonStyle(.bordered).buttonBorderShape(.capsule)
        } else {
            buttonStyle(.glass).buttonBorderShape(.capsule)
        }
    }
}

// MARK: - Text

/// "What comes after" in words: the runner-up, a plan to return to, or when
/// room comes back.
@MainActor
private enum Handoff {
    static func line(advice: PlanRecommendation, rows: [PlanRow], now: Date) -> String? {
        guard let thenID = advice.then, let then = rows.first(where: { $0.id == thenID }) else { return nil }
        let name = PlanText.name(then)
        let wait = advice.thenFreesAt.flatMap { $0 > now ? Durations.compact($0.timeIntervalSince(now)) : nil }
        switch (advice.handoff, wait) {
        case (.returnTo, let wait?):
            return L.backTo(name, in: wait)
        case (.nextWhenFree, let wait?):
            return advice.reason == .allOut ? L.freesIn(name, wait) : L.nextPlan(name) + " · " + L.freesAfter(wait)
        default:
            return advice.reason == .allOut ? nil : L.nextPlan(name)
        }
    }
}

/// What the pace so far says about the rest of the window.
@MainActor
private enum Pace {
    static func text(_ evaluation: PlanEvaluation?) -> String? {
        if let unused = evaluation?.projectedUnused, unused >= 5 {
            return L.unusedAtPace(Int(unused.rounded()))
        }
        if let runOut = evaluation?.projectedRunOut, let expires = evaluation?.expiresAt {
            return L.runsOutEarly(Durations.compact(expires.timeIntervalSince(runOut)))
        }
        return nil
    }
}

/// How a window is labelled and coloured, shared by every block.
@MainActor
private enum WindowText {
    static func label(_ window: UsageWindow) -> String {
        window.role == .spend ? L.credits : window.label
    }

    /// Remaining share. Past its reset the window has refilled, whatever the
    /// last snapshot said.
    static func remaining(_ window: UsageWindow, now: Date) -> Double {
        if let resetsAt = window.resetsAt, resetsAt <= now { return 100 }
        return max(0, 100 - window.percent)
    }

    static func reset(_ window: UsageWindow, now: Date) -> String? {
        guard let resetsAt = window.resetsAt, resetsAt > now else { return nil }
        return Durations.compact(resetsAt.timeIntervalSince(now))
    }

    /// `DetailCard`'s scheme — the first window in full brand colour, the rest
    /// at half — with red once little is left.
    static func color(_ window: UsageWindow, now: Date, brand: Color, primary: Bool) -> Color {
        if window.isCritical || remaining(window, now: now) < 10 {
            return ThemeManager.shared.current.statusDanger
        }
        return brand.opacity(primary ? 1.0 : 0.5)
    }

    static func isRateLimit(_ error: String) -> Bool {
        error.lowercased().contains("rate limit")
    }

    /// The error without the account label the row already shows, and without
    /// the internal marker used to recognise throttling.
    static func stripped(_ error: String, account: ProviderAccount?) -> String {
        var message = error.replacingOccurrences(of: " (rate limit)", with: "")
        if let label = account?.label, message.hasPrefix("\(label): ") {
            message = String(message.dropFirst(label.count + 2))
        }
        return message
    }
}

/// The command that starts a session on a plan: the bare CLI for the login it
/// already uses, else the CLI pointed at that login's config home.
@MainActor
enum LaunchCommand {
    static func text(for row: PlanRow) -> String {
        let cli = CLILoginLauncher.commandName(for: row.service)
        guard let account = row.login.account, !account.isDefault, let dir = account.configDir else { return cli }
        let variable = row.service == .claude ? "CLAUDE_CONFIG_DIR" : "CODEX_HOME"
        let quoted = "'" + dir.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return "\(variable)=\(quoted) \(cli)"
    }

    static func copy(for row: PlanRow) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text(for: row), forType: .string)
    }
}

enum PlanText {
    /// What a plan is called: the user's nickname, else its org or workspace.
    @MainActor
    static func name(_ row: PlanRow) -> String {
        if let account = row.login.account, let alias = AccountRegistry.shared.alias(for: account.id) {
            return alias
        }
        return row.identity?.orgName
            ?? row.login.account?.organizationName
            ?? row.login.account?.shortName
            ?? row.login.name
    }

    /// The account's full email address.
    @MainActor
    static func email(_ row: PlanRow) -> String? {
        row.identity?.email ?? row.login.account?.email
    }

    /// The real org or workspace, when a nickname stands in for it.
    @MainActor
    static func hiddenOrg(_ row: PlanRow) -> String? {
        guard let org = row.identity?.orgName ?? row.login.account?.organizationName,
              name(row) != org else { return nil }
        return org
    }

    /// "Max 20x", "Team 5x", "Business".
    @MainActor
    static func plan(_ row: PlanRow) -> String? {
        row.identity?.planName ?? row.login.account?.planName
    }
}

enum Durations {
    /// "45m", "3h 20m", "2d 4h" — whole units, never a sentence.
    static func compact(_ interval: TimeInterval) -> String {
        let seconds = max(0, interval)
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(max(1, minutes))m" }
        let hours = minutes / 60
        if hours < 24 {
            let rest = minutes % 60
            return rest == 0 ? "\(hours)h" : "\(hours)h \(rest)m"
        }
        let days = hours / 24
        let rest = hours % 24
        return rest == 0 ? "\(days)d" : "\(days)d \(rest)h"
    }
}
