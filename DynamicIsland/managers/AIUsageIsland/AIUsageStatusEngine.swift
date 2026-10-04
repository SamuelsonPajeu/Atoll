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

import Foundation
import SwiftUI

/// The island states from the design.
enum AIUsageStatus: String, Sendable {
    case idle
    case active
    case waiting
    case warning
    case limit
    case reset
}

/// A "bloom": the island grows for 3.5 s with a title and subtitle. Permission blooms stay
/// open until the request is answered. Copy follows the design word for word.
struct AIUsageAlert: Equatable, Sendable {
    let kind: AIUsageAlertKind
    let agent: AIUsageAgent
    let title: String
    let subtitle: String
}

struct AIUsageIslandState: Equatable, Sendable {
    var status: AIUsageStatus
    /// The agent the compact island shows: the one waiting on the user, otherwise the one
    /// selected in the AI Usage tab.
    var focus: AIUsageAgentSnapshot
    /// Monitored agents in tab order.
    var agents: [AIUsageAgentSnapshot]
    var alert: AIUsageAlert?
    var warnAt: Int

    /// The design's `tone`: yellow from the warning threshold, red from 95%.
    func tone(_ percent: Double) -> Color? {
        if percent >= Double(AIUsageSettings.criticalAt) { return AIUsagePalette.critical }
        if percent >= Double(warnAt) { return AIUsagePalette.warning }
        return nil
    }

    /// The design's `g`: gauge color of an agent (green right after its reset).
    func gaugeColor(for agent: AIUsageAgentSnapshot) -> Color {
        if status == .reset, agent.agent == focus.agent { return AIUsagePalette.reset }
        return tone(agent.primaryPercent) ?? agent.agent.color
    }
}

/// Turns agent snapshots into the island state and decides which alerts to raise. It
/// remembers the previous observation per agent so alerts fire on transitions only.
final class AIUsageStatusEngine {
    private struct Memory {
        var fiveHour: AIUsageWindow?
        var warningLevel = 0
        var wasLimited = false
        var wasWorking = false
        var idleSince: Date?
        var permissionID: String?
        var resetUntil: Date?
    }

    /// How long the compact island keeps the green "Ready" state after a reset.
    var resetDisplayDuration: TimeInterval = 10 * 60
    /// An agent must have been idle this long before "is working" alerts again.
    var activityDebounce: TimeInterval = 60

    private var memory: [AIUsageAgent: Memory] = [:]
    private var hasBaseline = false

    func evaluate(_ snapshots: [AIUsageAgentSnapshot], settings: AIUsageSettings, preferred: AIUsageAgent? = nil, now: Date = Date()) -> AIUsageIslandState? {
        let agents = AIUsageAgent.allCases.compactMap { kind in
            snapshots.first { $0.agent == kind && settings.isEnabled(kind) && ($0.isDetected || $0.hasQuota) }
        }
        guard !agents.isEmpty else { return nil }

        var alerts: [AIUsageAlert] = []
        for agent in agents {
            alerts += transitions(for: agent, settings: settings, now: now)
        }
        hasBaseline = true

        let focus = Self.focus(in: agents, preferred: preferred)
        let priority: [AIUsageAlertKind] = [.permission, .limit, .reset, .warning, .activity]
        let alert = alerts
            .filter { settings.alertEnabled($0.kind) }
            .min { priority.firstIndex(of: $0.kind)! < priority.firstIndex(of: $1.kind)! }

        return AIUsageIslandState(
            status: status(of: focus, settings: settings, now: now),
            focus: focus,
            agents: agents,
            alert: alert,
            warnAt: settings.warnAt
        )
    }

    /// Same state, shown for `agent` (e.g. while that agent's alert is blooming).
    func focusing(_ state: AIUsageIslandState, on agent: AIUsageAgent, settings: AIUsageSettings, now: Date = Date()) -> AIUsageIslandState {
        guard state.focus.pendingPermission == nil,
              let snapshot = state.agents.first(where: { $0.agent == agent }),
              snapshot.agent != state.focus.agent else { return state }
        var next = state
        next.focus = snapshot
        next.status = status(of: snapshot, settings: settings, now: now)
        return next
    }

    static func focus(in agents: [AIUsageAgentSnapshot], preferred: AIUsageAgent? = nil) -> AIUsageAgentSnapshot {
        if let waiting = agents.first(where: { $0.pendingPermission != nil }) { return waiting }
        if let preferred, let selected = agents.first(where: { $0.agent == preferred }) { return selected }
        return agents.max { lhs, rhs in
            if lhs.isAtLimit != rhs.isAtLimit { return !lhs.isAtLimit }
            if lhs.primaryPercent != rhs.primaryPercent { return lhs.primaryPercent < rhs.primaryPercent }
            if lhs.isWorking != rhs.isWorking { return !lhs.isWorking }
            // Stable order: Claude before Codex when everything else ties.
            return AIUsageAgent.allCases.firstIndex(of: lhs.agent)! > AIUsageAgent.allCases.firstIndex(of: rhs.agent)!
        }!
    }

    private func status(of agent: AIUsageAgentSnapshot, settings: AIUsageSettings, now: Date) -> AIUsageStatus {
        if agent.pendingPermission != nil { return .waiting }
        if agent.isAtLimit { return .limit }
        if agent.isWorking { return .active }
        if let until = memory[agent.agent]?.resetUntil, until > now { return .reset }
        if agent.primaryPercent >= Double(settings.warnAt) { return .warning }
        return .idle
    }

    private func transitions(for agent: AIUsageAgentSnapshot, settings: AIUsageSettings, now: Date) -> [AIUsageAlert] {
        var state = memory[agent.agent] ?? Memory()
        defer { memory[agent.agent] = state }
        var alerts: [AIUsageAlert] = []
        let name = agent.agent.displayName

        // Permission requests.
        let request = agent.pendingPermission
        if let request, request.id != state.permissionID {
            alerts.append(AIUsageAlert(kind: .permission, agent: agent.agent,
                                       title: request.title,
                                       subtitle: "\(request.project) · \(request.summary.isEmpty ? request.toolName : request.summary)"))
        }
        state.permissionID = request?.id

        // A new 5-hour window.
        if let previous = state.fiveHour, let current = agent.fiveHour,
           Self.isReset(previous: previous, current: current, now: now) {
            state.resetUntil = now.addingTimeInterval(resetDisplayDuration)
            if previous.usedPercent >= 50 || state.wasLimited {
                alerts.append(AIUsageAlert(kind: .reset, agent: agent.agent,
                                           title: "Limit reset",
                                           subtitle: "A new 5-hour window is available"))
            }
        }
        if agent.fiveHour != nil { state.fiveHour = agent.fiveHour }

        // Limit reached.
        if agent.isAtLimit, !state.wasLimited, let limiting = agent.limitingWindow {
            var parts: [String] = []
            if let resetsAt = limiting.window.resetsAt {
                parts.append(limiting.isWeekly
                             ? "Available again \(AIUsageFormat.dayAndTime(resetsAt))"
                             : "Available again at \(AIUsageFormat.time(resetsAt))")
            }
            if !limiting.isWeekly, let weekly = agent.weekly {
                parts.append("weekly at \(AIUsageFormat.percent(weekly.usedPercent))")
            }
            alerts.append(AIUsageAlert(kind: .limit, agent: agent.agent,
                                       title: limiting.isWeekly ? "Weekly limit reached" : "5-hour limit reached",
                                       subtitle: parts.isEmpty ? name : parts.joined(separator: " · ")))
        }
        state.wasLimited = agent.isAtLimit
        if agent.isAtLimit { state.resetUntil = nil }

        // Usage warnings at the threshold and at 95%.
        let percent = agent.fiveHour?.usedPercent ?? 0
        let level = percent >= Double(AIUsageSettings.criticalAt) ? 2 : percent >= Double(settings.warnAt) ? 1 : 0
        if level > state.warningLevel, !agent.isAtLimit, let window = agent.fiveHour {
            let subtitle = window.resetsAt.map {
                "Resets in \(AIUsageFormat.duration($0.timeIntervalSince(now))) · \(AIUsageFormat.time($0))"
            } ?? name
            alerts.append(AIUsageAlert(kind: .warning, agent: agent.agent,
                                       title: "\(AIUsageFormat.percent(percent)) of 5-hour limit used",
                                       subtitle: subtitle))
        }
        state.warningLevel = level

        // Activity started.
        if agent.isWorking {
            let idleLongEnough = state.idleSince.map { now.timeIntervalSince($0) >= activityDebounce } ?? false
            if !state.wasWorking, idleLongEnough, hasBaseline {
                alerts.append(AIUsageAlert(kind: .activity, agent: agent.agent,
                                           title: "\(name) is working",
                                           subtitle: "\(Self.sourceLabel(agent.agent, agent.workingSources)) · \(AIUsageFormat.percent(percent)) of 5-hour limit"))
            }
            state.idleSince = nil
            state.resetUntil = nil
        } else if state.wasWorking || state.idleSince == nil {
            state.idleSince = now
        }
        state.wasWorking = agent.isWorking

        // The first observation only sets the baseline for resets.
        return hasBaseline ? alerts : alerts.filter { $0.kind != .reset }
    }

    /// "Claude Code", "Claude Desktop", "Claude Code & Desktop", "Codex CLI".
    static func sourceLabel(_ agent: AIUsageAgent, _ sources: [String]) -> String {
        switch agent {
        case .claude:
            if sources.count > 1 { return "Claude Code & Desktop" }
            return "Claude " + (sources.first ?? "Code")
        case .codex:
            return "Codex " + (sources.first ?? "CLI")
        }
    }

    static func isReset(previous: AIUsageWindow, current: AIUsageWindow, now: Date) -> Bool {
        guard current.usedPercent < previous.usedPercent, previous.usedPercent >= 1 else { return false }
        if let previousReset = previous.resetsAt, previousReset <= now { return true }
        if let previousReset = previous.resetsAt, let currentReset = current.resetsAt,
           currentReset.timeIntervalSince(previousReset) > 30 * 60 { return true }
        return false
    }
}
