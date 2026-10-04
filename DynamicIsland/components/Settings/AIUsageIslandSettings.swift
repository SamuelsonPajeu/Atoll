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

import Defaults
import SwiftUI

/// Settings → AI Usage, following the design: Agents, Notch and Alerts. Plans are detected
/// from each agent's login, so there is nothing to choose.
struct AIUsageIslandSettingsView: View {
    @ObservedObject private var manager = AIUsageIslandManager.shared

    @Default(.enableAIUsageIsland) private var enabled
    @Default(.aiUsageMonitorClaudeCode) private var monitorClaudeCode
    @Default(.aiUsageMonitorClaudeDesktop) private var monitorClaudeDesktop
    @Default(.aiUsageMonitorCodex) private var monitorCodex
    @Default(.aiUsageWarnAt) private var warnAt
    @Default(.aiUsageRefreshInterval) private var refreshInterval
    @Default(.aiUsageAlertActivity) private var alertActivity
    @Default(.aiUsageAlertPermission) private var alertPermission
    @Default(.aiUsageAlertWarning) private var alertWarning
    @Default(.aiUsageAlertLimit) private var alertLimit
    @Default(.aiUsageAlertReset) private var alertReset

    private let secondary = Color(red: 235 / 255, green: 235 / 255, blue: 245 / 255)

    var body: some View {
        Form {
            sections
        }
        .navigationTitle("AI Usage")
        .onAppear { manager.refreshHookState() }
    }

    @ViewBuilder
    private var sections: some View {
        Section {
            Toggle("Show AI Usage in the notch", isOn: $enabled)
        } header: {
            Text("General")
        } footer: {
            Text("5-hour usage, weekly limit, time until reset, activity and permission requests from Claude Code, Claude Desktop and Codex. Adds an AI Usage tab to the open notch.")
                .foregroundStyle(.secondary)
                .font(.caption)
        }

        Section("Agents") {
            HStack(spacing: 12) {
                badge(.claude)
                titled("Claude", claudeProblem ?? "Claude Code and Claude Desktop share this limit")
                Spacer()
                planPill(plan(for: .claude))
            }
            Toggle(isOn: $monitorClaudeCode) {
                titled("Claude Code", monitorClaudeCode
                       ? (manager.claudeConfigFound ? "~/.claude · \(sessions(manager.claudeCodeSessions))" : "~/.claude not found")
                       : "not monitored", monospaced: true, dimmed: !monitorClaudeCode)
            }
            .padding(.leading, 38)
            Toggle(isOn: $monitorClaudeDesktop) {
                titled("Claude Desktop", monitorClaudeDesktop
                       ? "Claude.app · \(manager.claudeDesktopRunning ? "running" : "not running")"
                       : "not monitored", monospaced: true, dimmed: !monitorClaudeDesktop)
            }
            .padding(.leading, 38)
            HStack(spacing: 12) {
                badge(.codex)
                titled("Codex", manager.codexDetected ? "~/.codex · detected" : "~/.codex · not found", monospaced: true)
                Spacer()
                if monitorCodex { planPill(plan(for: .codex)) }
                Toggle("", isOn: $monitorCodex).labelsHidden()
            }
        }
        .disabled(!enabled)

        Section("Notch") {
            HStack(spacing: 12) {
                titled("Warning threshold", "Turns yellow and alerts. Critical stays at 95%.")
                Spacer()
                // Snaps to 5% steps in the binding so the slider stays smooth, without ticks.
                Slider(
                    value: Binding(get: { Double(warnAt) }, set: { warnAt = Int(($0 / 5).rounded()) * 5 }),
                    in: Double(AIUsageSettings.warnRange.lowerBound)...Double(AIUsageSettings.warnRange.upperBound)
                )
                .frame(width: 140)
                Text("\(warnAt)%")
                    .monospacedDigit()
                    .frame(width: 38, alignment: .trailing)
            }
            Picker("Refresh every", selection: $refreshInterval) {
                ForEach(AIUsageSettings.refreshChoices, id: \.self) { Text("\($0)s").tag($0) }
            }
            .pickerStyle(.segmented)
        }
        .disabled(!enabled)

        Section("Alerts") {
            alertRow("Activity started", "When an agent starts working", AIUsagePalette.claude, $alertActivity)
            alertRow("Permission requests", "Stays open until you answer", AIUsagePalette.permission, $alertPermission)
            alertRow("Usage warning", "At \(warnAt)% and 95% of the 5-hour limit", AIUsagePalette.warning, $alertWarning)
            alertRow("Limit reached", "With time until it becomes available", AIUsagePalette.critical, $alertLimit)
            alertRow("Limit reset", "When a new 5-hour window starts", AIUsagePalette.reset, $alertReset)
        }
        .disabled(!enabled)

        Section {
            HStack(spacing: 12) {
                titled("Answer from the notch",
                       manager.hookError ?? (manager.hooksInstalled
                            ? "Allow or Deny Claude Code tools from the notch or the terminal"
                            : "Adds a hook to ~/.claude/settings.json (your settings are kept, a backup is saved)"))
                Spacer()
                if manager.hooksInstalled {
                    Button("Disconnect") { manager.disconnectHooks() }
                } else {
                    Button("Connect") { manager.connectHooks() }
                }
            }
        } header: {
            Text("Claude Code permission requests")
        }
        .disabled(!enabled)
    }

    // MARK: - Building blocks

    private var claudeProblem: String? {
        manager.state?.agents.first { $0.agent == .claude }?.problem
    }

    private func plan(for agent: AIUsageAgent) -> String? {
        manager.state?.agents.first { $0.agent == agent }?.plan
    }

    private func sessions(_ count: Int) -> String {
        "\(count) session\(count == 1 ? "" : "s")"
    }

    private func titled(_ title: String, _ subtitle: String, monospaced: Bool = false, dimmed: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 13))
            Text(subtitle)
                .font(monospaced ? .system(size: 11, design: .monospaced) : .system(size: 11))
                .foregroundStyle(secondary.opacity(dimmed ? 0.35 : 0.55))
                .lineLimit(2)
        }
    }

    private func badge(_ agent: AIUsageAgent) -> some View {
        Text(agent.glyph)
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(.black)
            .frame(width: 26, height: 26)
            .background(RoundedRectangle(cornerRadius: 7).fill(agent.color))
    }

    @ViewBuilder
    private func planPill(_ plan: String?) -> some View {
        if let plan {
            Text(plan)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.22)))
                .help("Detected from your login")
        }
    }

    private func alertRow(_ title: String, _ subtitle: String, _ color: Color, _ isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            HStack(spacing: 12) {
                Circle().fill(color).frame(width: 8, height: 8)
                titled(title, subtitle)
            }
        }
    }
}
