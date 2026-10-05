/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

import AppKit
import Combine
import Defaults
import SwiftUI

/// Drives the AI Usage island: 5-hour and weekly usage, time to reset, activity and
/// Claude Code permission requests for Claude (Code + Desktop) and Codex.
///
/// Plans and quotas are detected from each agent's own login — there is nothing to pick.
@MainActor
final class AIUsageIslandManager: ObservableObject {
    static let shared = AIUsageIslandManager()

    static let claudeDesktopBundleIDs = ["com.anthropic.claudefordesktop", "com.anthropic.claude"]
    static let bloomDuration: TimeInterval = 3.5

    @Published private(set) var state: AIUsageIslandState?
    /// The alert currently "blooming" out of the closed notch.
    @Published private(set) var bloom: AIUsageAlert?
    /// Agent selected in the AI Usage tab; the closed notch shows the same agent.
    @Published var selectedAgent: AIUsageAgent = Defaults[.aiUsageSelectedAgent] {
        didSet {
            guard selectedAgent != oldValue else { return }
            Defaults[.aiUsageSelectedAgent] = selectedAgent
            tick()
        }
    }

    // Detection details for Settings.
    @Published private(set) var claudeConfigFound = false
    @Published private(set) var claudeCodeSessions = 0
    @Published private(set) var claudeDesktopRunning = false
    @Published private(set) var codexDetected = false
    @Published private(set) var hooksInstalled = false
    @Published var hookError: String?

    private let engine = AIUsageStatusEngine()
    private let broker = AIUsagePermissionBroker()
    private let collector = AIUsageCollector()
    private lazy var server = AIUsageHookServer { [weak self] event, responder in
        self?.handle(event, responder: responder)
    }

    private var timer: Timer?
    private var bloomHideWork: DispatchWorkItem?
    private var collecting = false
    /// Agents from the last collection, before pending requests are applied.
    private var collectedAgents: [AIUsageAgentSnapshot] = []
    private var needsAnotherTick = false
    private var forceQuotaRefresh = false
    private var cancellables = Set<AnyCancellable>()

    private init() {
        // Pending requests change the island at once, on top of the last collected data;
        // a full collection (network, log scans) can take seconds.
        broker.onChange = { [weak self] in self?.republish() }
    }

    // MARK: - Lifecycle

    func start() {
        Defaults.publisher(.enableAIUsageIsland)
            .map(\.newValue)
            .removeDuplicates()
            .sink { [weak self] enabled in
                Task { @MainActor in enabled ? self?.resume() : self?.suspend() }
            }
            .store(in: &cancellables)

        Defaults.publisher(
            keys: .aiUsageMonitorClaudeCode, .aiUsageMonitorClaudeDesktop, .aiUsageMonitorCodex, .aiUsageWarnAt,
            .aiUsageAlertActivity, .aiUsageAlertPermission, .aiUsageAlertWarning, .aiUsageAlertLimit, .aiUsageAlertReset,
            options: []
        )
            .sink { [weak self] in Task { @MainActor in self?.tick() } }
            .store(in: &cancellables)
        refreshHookState()
    }

    private func resume() {
        guard timer == nil else { return }
        server.start()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        tick()
    }

    private func suspend() {
        timer?.invalidate()
        timer = nil
        broker.cancelAll()
        server.stop()
        setBloom(nil)
        state = nil
    }

    // MARK: - What the notch shows

    /// The island has something to show in the closed notch.
    var presentsCompact: Bool {
        Defaults[.enableAIUsageIsland] && state != nil
    }

    /// Worth taking the closed notch over music and other live activities.
    var isUrgent: Bool {
        guard let state else { return false }
        if bloom != nil { return true }
        switch state.status {
        case .waiting, .limit, .warning, .reset: return true
        case .active, .idle: return false
        }
    }

    /// Geometry for the current notch, from the design's sizes.
    func geometry(closedNotchSize: CGSize) -> AIUsageIslandGeometry {
        AIUsageIslandGeometry(notch: closedNotchSize)
    }

    /// The notch is about to open on the AI Usage tab for a pending request: show the
    /// agent that is waiting.
    func prepareExpanded() {
        if let waiting = state?.agents.first(where: { $0.pendingPermission != nil })?.agent {
            selectedAgent = waiting
        }
    }

    func answer(_ decision: AIUsagePermissionDecision) {
        guard let request = state?.agents.lazy.compactMap(\.pendingPermission).first(where: \.needsDecision) else { return }
        broker.answer(id: request.id, decision: decision)
    }

    // MARK: - Claude Code hooks

    func refreshHookState() {
        hooksInstalled = AIUsageHookInstaller().isInstalled
    }

    func connectHooks() {
        do {
            try AIUsageHookInstaller().install()
            hookError = nil
        } catch {
            hookError = error.localizedDescription
        }
        refreshHookState()
    }

    func disconnectHooks() {
        do {
            try AIUsageHookInstaller().uninstall()
            hookError = nil
        } catch {
            hookError = error.localizedDescription
        }
        refreshHookState()
    }

    private func handle(_ event: AIUsageHookEvent, responder: AIUsageHookServer.Responder) {
        switch event.name {
        case "PermissionRequest":
            // With the permission alert off the island still turns blue and offers
            // Allow/Deny when expanded; it just does not bloom on its own. Questions and plan
            // reviews are shown too, but answered in Claude Code (see the broker).
            guard Defaults[.enableAIUsageIsland], Defaults[.aiUsageMonitorClaudeCode] else {
                responder.respond()
                return
            }
            broker.add(event, responder: responder)
            return
        case "PostToolUse":
            broker.toolFinished(sessionID: event.sessionID, toolUseID: event.toolUseID, toolName: event.toolName)
        case "Stop", "UserPromptSubmit", "SessionEnd":
            broker.resolvedElsewhere(sessionID: event.sessionID, toolUseID: nil)
            if event.name == "Stop" { forceQuotaRefresh = true }
        default:
            break
        }
        responder.respond()
        tick()
    }

    // MARK: - Refresh loop

    private func tick() {
        guard timer != nil else { return }
        guard !collecting else {
            needsAnotherTick = true
            return
        }
        collecting = true
        let settings = AIUsageSettings.current
        let context = AIUsageCollector.Context(
            settings: settings,
            desktopRunning: Self.isClaudeDesktopRunning(),
            forceQuotaRefresh: forceQuotaRefresh
        )
        forceQuotaRefresh = false

        Task { @MainActor in
            let result = await collector.collect(context)
            claudeConfigFound = result.claudeConfigFound
            claudeCodeSessions = result.claudeCodeSessions
            claudeDesktopRunning = context.desktopRunning
            codexDetected = result.codexDetected

            collectedAgents = result.agents
            publish(settings: settings)

            collecting = false
            if needsAnotherTick {
                needsAnotherTick = false
                tick()
            }
        }
    }

    /// Re-evaluates the island from the last collection with the current pending requests.
    private func republish() {
        guard timer != nil else { return }
        guard !collectedAgents.isEmpty else {
            tick()
            return
        }
        publish(settings: AIUsageSettings.current)
    }

    private func publish(settings: AIUsageSettings) {
        var agents = collectedAgents
        if let request = broker.requests.first, let index = agents.firstIndex(where: { $0.agent == .claude }) {
            agents[index].activity = .waitingForPermission(request)
        }
        var next = engine.evaluate(agents, settings: settings, preferred: bloom?.agent ?? selectedAgent)
        updateBloom(with: next, settings: settings)
        // While an alert blooms, the island shows the agent it is about.
        if let bloom, let current = next {
            next = engine.focusing(current, on: bloom.agent, settings: settings)
        }
        if next != state {
            withAnimation(AIUsageIslandGeometry.spring) { state = next }
        }
    }

    private func updateBloom(with state: AIUsageIslandState?, settings: AIUsageSettings) {
        guard let state else {
            setBloom(nil)
            return
        }
        if let alert = state.alert {
            setBloom(alert)
            if alert.kind != .permission {
                let work = DispatchWorkItem { [weak self] in
                    Task { @MainActor in
                        guard let self, self.bloom == alert else { return }
                        self.setBloom(nil)
                    }
                }
                bloomHideWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.bloomDuration, execute: work)
            }
        } else if bloom?.kind == .permission, state.focus.pendingPermission == nil {
            // Answered in the notch, the terminal, or the session moved on.
            setBloom(nil)
        }
    }

    private func setBloom(_ alert: AIUsageAlert?) {
        bloomHideWork?.cancel()
        bloomHideWork = nil
        guard bloom != alert else { return }
        let ended = bloom != nil && alert == nil
        withAnimation(AIUsageIslandGeometry.spring) {
            bloom = alert
        }
        // The bloom may have shown another agent; go back to the selected one right away.
        if ended {
            DispatchQueue.main.async { [weak self] in self?.republish() }
        }
    }

    static func isClaudeDesktopRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { app in
            guard let id = app.bundleIdentifier else { return false }
            return claudeDesktopBundleIDs.contains(id)
        }
    }
}

/// Gathers quota, plan, activity and history off the main thread. Live quota comes from
/// Atoll's own quota clients (polled conservatively), backed by local data so the island
/// keeps working offline or while a login token is expired.
actor AIUsageCollector {
    struct Context {
        var settings: AIUsageSettings
        var desktopRunning: Bool
        var forceQuotaRefresh: Bool
    }

    struct Result {
        var agents: [AIUsageAgentSnapshot]
        var claudeConfigFound: Bool
        var claudeCodeSessions: Int
        var codexDetected: Bool
    }

    /// Anthropic's usage endpoint rate-limits aggressive polling; never ask more often.
    private let claudeMinimumInterval: TimeInterval = 60
    private let forcedInterval: TimeInterval = 20

    private var claudeQuota: (session: UsageLimit?, week: UsageLimit?)?
    private var claudeQuotaAt: Date?
    private var claudeAttemptAt: Date?
    private var claudePlan: String?
    private var codexQuota: (session: UsageLimit?, week: UsageLimit?, at: Date)?
    private var codexAttemptAt: Date?

    private let claudeHistory = AIUsageClaudeHistory()
    private let codexLogs = AIUsageCodexLogs()
    private var claudeDays: [AIUsageDay] = []
    private var codexSummary: AIUsageCodexLogs.Summary?
    private var historyAt: Date?

    func collect(_ context: Context) async -> Result {
        let now = Date()
        let settings = context.settings
        if historyAt.map({ now.timeIntervalSince($0) >= 10 }) ?? true {
            claudeDays = claudeHistory.days(now: now)
            codexSummary = codexLogs.summary(now: now)
            historyAt = now
        }

        let configFound = FileManager.default.fileExists(atPath: AIUsagePaths.claudeConfig.path)
        let sessions = AIUsageClaudeSessionRegistry.liveSessions()
        var agents: [AIUsageAgentSnapshot] = []

        if settings.monitorsClaude {
            await refreshClaude(force: context.forceQuotaRefresh, interval: TimeInterval(settings.refreshInterval), now: now)
            var claude = AIUsageAgentSnapshot(agent: .claude, isDetected: configFound || context.desktopRunning)
            claude.plan = claudePlan
            claude.history = claudeDays
            if let quota = claudeQuota {
                claude.fiveHour = quota.session.map { Self.window($0, duration: 5 * 3600) }?.rolledForward(now: now, restartsOnUse: true)
                claude.weekly = quota.week.map { Self.window($0, duration: 7 * 86400) }?.rolledForward(now: now)
            } else if claudeAttemptAt != nil {
                claude.problem = "Open Claude Code once to see your limits"
            }

            let monitored = sessions.filter { $0.surface == .code ? settings.monitorClaudeCode : settings.monitorClaudeDesktop }
            // Pending requests are applied by the manager on top of this.
            let busy = monitored.filter(\.isBusy)
            let surfaces = [AIUsageClaudeSurface.code, .desktop].filter { surface in busy.contains { $0.surface == surface } }
            if !surfaces.isEmpty { claude.activity = .working(sources: surfaces.map(\.rawValue)) }
            agents.append(claude)
        }

        if settings.monitorCodex {
            await refreshCodex(interval: TimeInterval(settings.refreshInterval), now: now)
            var codex = AIUsageAgentSnapshot(agent: .codex, isDetected: codexLogs.isInstalled)
            codex.history = codexSummary?.days ?? []
            let log = codexSummary?.latestQuota
            // Whichever observation is newer: the live endpoint or the CLI's own log.
            if let live = codexQuota, live.at >= (log?.observedAt ?? .distantPast) {
                codex.fiveHour = live.session.map { Self.window($0, duration: 5 * 3600) }?.rolledForward(now: now, restartsOnUse: true)
                codex.weekly = live.week.map { Self.window($0, duration: 7 * 86400) }?.rolledForward(now: now)
            } else if let log {
                codex.fiveHour = log.fiveHour?.rolledForward(now: now, restartsOnUse: true)
                codex.weekly = log.weekly?.rolledForward(now: now)
            }
            codex.plan = log?.plan ?? AIUsageCodexLogs.planFromAuth()
            if let lastWrite = codexSummary?.lastWrite, now.timeIntervalSince(lastWrite) < 20 {
                codex.activity = .working(sources: ["CLI"])
            }
            agents.append(codex)
        }

        return Result(
            agents: agents,
            claudeConfigFound: configFound,
            claudeCodeSessions: sessions.filter { $0.surface == .code }.count,
            codexDetected: codexLogs.isInstalled
        )
    }

    private func refreshClaude(force: Bool, interval: TimeInterval, now: Date) async {
        let minimum = force ? forcedInterval : max(interval, claudeMinimumInterval)
        if let last = claudeAttemptAt, now.timeIntervalSince(last) < minimum { return }
        claudeAttemptAt = now
        if claudePlan == nil { claudePlan = ClaudeUsageProvider.readPlanLabel() }
        let limits = await ClaudeQuotaClient().fetchLimits()
        if limits.session != nil || limits.week != nil {
            claudeQuota = limits
            claudeQuotaAt = now
        }
    }

    private func refreshCodex(interval: TimeInterval, now: Date) async {
        if let last = codexAttemptAt, now.timeIntervalSince(last) < max(interval, 30) { return }
        codexAttemptAt = now
        guard codexLogs.isInstalled else { return }
        let limits = await CodexQuotaClient().fetchLimits()
        if limits.session != nil || limits.week != nil {
            codexQuota = (limits.session, limits.week, now)
        }
    }

    private static func window(_ limit: UsageLimit, duration: TimeInterval) -> AIUsageWindow {
        let percent = limit.limit > 0 ? limit.used / limit.limit * 100 : limit.used
        return AIUsageWindow(usedPercent: percent, resetsAt: limit.resetsAt, duration: duration)
    }
}
