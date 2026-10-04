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
import Defaults

// MARK: - Agents

/// Agents the AI Usage island monitors. Claude Code and Claude Desktop share one
/// subscription limit, so they are one agent with two sources.
enum AIUsageAgent: String, CaseIterable, Identifiable, Sendable {
    case claude
    case codex

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        }
    }

    var glyph: String {
        switch self {
        case .claude: return "C"
        case .codex: return "X"
        }
    }

    var color: Color {
        switch self {
        case .claude: return AIUsagePalette.claude
        case .codex: return AIUsagePalette.codex
        }
    }
}

/// State colors from the design.
enum AIUsagePalette {
    static let claude = Color(hex: 0xD97757)
    static let codex = Color(hex: 0x9B8CF0)
    static let warning = Color(hex: 0xFFD60A)
    static let critical = Color(hex: 0xFF453A)
    static let permission = Color(hex: 0x0A84FF)
    static let permissionHover = Color(hex: 0x2C95FF)
    static let permissionText = Color(hex: 0x64B5FF)
    static let reset = Color(hex: 0x30D158)
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

// MARK: - Quota

/// One provider-reported quota window ("5-hour", "weekly").
struct AIUsageWindow: Equatable, Sendable {
    /// Percentage consumed, 0...100 (may exceed 100 when over the limit).
    var usedPercent: Double
    var resetsAt: Date?
    var duration: TimeInterval?

    var displayPercent: Int { Int(min(max(usedPercent, 0), 100).rounded()) }

    /// Once the reset time passed the window is fresh: report 0% until the provider says
    /// otherwise, and move the reset forward by the window length.
    func rolledForward(now: Date) -> AIUsageWindow {
        guard let resetsAt, resetsAt <= now else { return self }
        var next = AIUsageWindow(usedPercent: 0, resetsAt: nil, duration: duration)
        if let duration, duration > 0 {
            var candidate = resetsAt
            while candidate <= now { candidate = candidate.addingTimeInterval(duration) }
            next.resetsAt = candidate
        }
        return next
    }
}

/// Something Claude Code is waiting on the user for, from a `PermissionRequest` hook:
/// a yes/no tool permission (answerable from the notch), or a question / plan review
/// that has to be answered in Claude Code itself.
struct AIUsagePermissionRequest: Equatable, Identifiable, Sendable {
    enum Kind: Equatable, Sendable {
        /// Run this tool? Deny / Allow from the notch.
        case permission
        /// A question with options or free text (`AskUserQuestion`).
        case question
        /// A plan waiting for review (`ExitPlanMode`).
        case plan
    }

    let id: String
    let sessionID: String?
    let project: String
    let toolName: String
    let summary: String
    let createdAt: Date
    var kind: Kind = .permission

    var needsDecision: Bool { kind == .permission }

    /// Bloom / banner title, e.g. "Claude needs permission".
    var title: String {
        switch kind {
        case .permission: return "Claude needs permission"
        case .question: return "Claude has a question"
        case .plan: return "Claude's plan is ready"
        }
    }

    /// Activity line in the expanded view.
    var activityLabel: String {
        switch kind {
        case .permission: return "Waiting for permission"
        case .question: return "Waiting for your answer"
        case .plan: return "Waiting for plan review"
        }
    }
}

enum AIUsageActivity: Equatable, Sendable {
    case idle
    case working(sources: [String])
    case waitingForPermission(AIUsagePermissionRequest)
}

struct AIUsageDay: Equatable, Sendable {
    let day: Date
    let tokens: Int
}

/// Everything the island knows about one agent at a point in time.
struct AIUsageAgentSnapshot: Equatable, Sendable {
    var agent: AIUsageAgent
    var isDetected = false
    var plan: String?
    var fiveHour: AIUsageWindow?
    var weekly: AIUsageWindow?
    var history: [AIUsageDay] = []
    var activity: AIUsageActivity = .idle
    /// e.g. "~/.claude · 2 sessions"
    var detail = ""
    var problem: String?

    var hasQuota: Bool { fiveHour != nil || weekly != nil }
    var primaryPercent: Double { fiveHour?.usedPercent ?? weekly?.usedPercent ?? 0 }
    var isAtLimit: Bool { (fiveHour?.usedPercent ?? 0) >= 100 || (weekly?.usedPercent ?? 0) >= 100 }

    /// The window keeping the agent blocked; weekly wins because it lasts longest.
    var limitingWindow: (window: AIUsageWindow, isWeekly: Bool)? {
        if let weekly, weekly.usedPercent >= 100 { return (weekly, true) }
        if let fiveHour, fiveHour.usedPercent >= 100 { return (fiveHour, false) }
        return nil
    }

    var isWorking: Bool {
        if case .working = activity { return true }
        return false
    }

    var workingSources: [String] {
        if case .working(let sources) = activity { return sources }
        return []
    }

    var pendingPermission: AIUsagePermissionRequest? {
        if case .waitingForPermission(let request) = activity { return request }
        return nil
    }
}

// MARK: - Settings

enum AIUsageAlertKind: String, CaseIterable, Sendable {
    case activity
    case permission
    case warning
    case limit
    case reset
}

/// Value snapshot of the AI Usage preferences, read from `Defaults`. There is no plan
/// picker: plans are read from each agent's login and percentages come from the provider.
extension AIUsageAgent: Defaults.Serializable {}

struct AIUsageSettings: Equatable, Sendable {
    var monitorClaudeCode = true
    var monitorClaudeDesktop = true
    var monitorCodex = true
    var warnAt = 80
    var refreshInterval = 30
    var alerts = Set(AIUsageAlertKind.allCases)

    static let criticalAt = 95
    static let warnRange = 50...90
    static let refreshChoices = [15, 30, 60]

    var monitorsClaude: Bool { monitorClaudeCode || monitorClaudeDesktop }

    func isEnabled(_ agent: AIUsageAgent) -> Bool {
        agent == .claude ? monitorsClaude : monitorCodex
    }

    func alertEnabled(_ kind: AIUsageAlertKind) -> Bool { alerts.contains(kind) }

    static var current: AIUsageSettings {
        var settings = AIUsageSettings()
        settings.monitorClaudeCode = Defaults[.aiUsageMonitorClaudeCode]
        settings.monitorClaudeDesktop = Defaults[.aiUsageMonitorClaudeDesktop]
        settings.monitorCodex = Defaults[.aiUsageMonitorCodex]
        settings.warnAt = min(max(Defaults[.aiUsageWarnAt], warnRange.lowerBound), warnRange.upperBound)
        settings.refreshInterval = refreshChoices.contains(Defaults[.aiUsageRefreshInterval]) ? Defaults[.aiUsageRefreshInterval] : 30
        var alerts = Set<AIUsageAlertKind>()
        if Defaults[.aiUsageAlertActivity] { alerts.insert(.activity) }
        if Defaults[.aiUsageAlertPermission] { alerts.insert(.permission) }
        if Defaults[.aiUsageAlertWarning] { alerts.insert(.warning) }
        if Defaults[.aiUsageAlertLimit] { alerts.insert(.limit) }
        if Defaults[.aiUsageAlertReset] { alerts.insert(.reset) }
        settings.alerts = alerts
        return settings
    }
}

// MARK: - Formatting

/// Text formats from the design ("1h 57m", "0:47:12", "3:15 PM", "Mon 9:00 AM").
/// The island copy is English, so dates are too.
enum AIUsageFormat {
    static let locale = Locale(identifier: "en_US")

    /// The design's `dur`: "1h 57m" / "42m".
    static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let hours = total / 3600, minutes = total % 3600 / 60
        if hours >= 24 { return "\(hours / 24)d \(hours % 24)h" }
        return hours > 0 ? "\(hours)h \(String(format: "%02d", minutes))m" : "\(minutes)m"
    }

    /// The design's `clk`: "1:02:03" / "4:05".
    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let hours = total / 3600, minutes = total % 3600 / 60, secs = total % 60
        return hours > 0
            ? "\(hours):\(String(format: "%02d", minutes)):\(String(format: "%02d", secs))"
            : "\(minutes):\(String(format: "%02d", secs))"
    }

    /// The design's `at`: "3:15 PM".
    static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: date)
    }

    /// "Mon 9:00 AM".
    static func dayAndTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateFormat = "EEE h:mm a"
        return formatter.string(from: date)
    }

    static func percent(_ value: Double) -> String {
        "\(Int(min(max(value, 0), 100).rounded()))%"
    }
}
