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

import SwiftUI

// MARK: - Closed notch: compact row and blooms

/// The closed-notch island: the compact row, plus the alert or permission "bloom" below it.
struct AIUsageClosedIslandView: View {
    let state: AIUsageIslandState
    let bloom: AIUsageAlert?
    let geometry: AIUsageIslandGeometry
    let answer: (AIUsagePermissionDecision) -> Void

    private var waiting: Bool { state.status == .waiting }
    private var presentation: AIUsageIslandPresentation { bloom == nil ? .compact : .bloom }

    var body: some View {
        let decision = bloom?.kind == .permission && state.focus.pendingPermission?.needsDecision == true
        let surface = geometry.surface(presentation, waiting: waiting && decision)
        VStack(alignment: .leading, spacing: 0) {
            AIUsageCompactRow(state: state, notchWidth: geometry.notch.width)
                .frame(height: geometry.notch.height)
            if let bloom {
                if bloom.kind == .permission, let request = state.focus.pendingPermission, request.needsDecision {
                    AIUsagePermissionBloom(request: request, answer: answer)
                        .padding(EdgeInsets(top: 6, leading: 22, bottom: 16, trailing: 22))
                        .modifier(AIUsageFadeIn(delay: 0.1))
                } else {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(bloom.title)
                            .font(.system(size: 14, weight: .semibold))
                            .tracking(-0.14)
                        Text(bloom.subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .padding(EdgeInsets(top: 4, leading: 22, bottom: 14, trailing: 22))
                    .modifier(AIUsageFadeIn(delay: 0.1))
                }
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, AIUsageIslandGeometry.ear)
        .frame(width: surface.width, height: surface.height, alignment: .top)
        .animation(AIUsageIslandGeometry.spring, value: presentation)
    }
}

/// The 32 pt row on both sides of the camera: state glyph + usage on the left, usage or
/// countdown on the right. The middle stays empty — content only on the sides.
struct AIUsageCompactRow: View {
    let state: AIUsageIslandState
    let notchWidth: CGFloat

    private var focus: AIUsageAgentSnapshot { state.focus }
    private var gauge: Color { state.gaugeColor(for: focus) }

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) { leading }
                .frame(maxWidth: .infinity, alignment: .leading)
            Color.clear.frame(width: notchWidth)
            HStack(spacing: 6) { trailing }
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 13)
    }

    @ViewBuilder
    private var leading: some View {
        switch state.status {
        case .active:
            AIUsageWorkingDots(color: focus.agent.color)
        case .waiting:
            AIUsagePermissionBeacon()
        case .reset:
            Text("✓")
                .font(.system(size: 10, weight: .heavy))
                .foregroundStyle(.black)
                .frame(width: 15, height: 15)
                .background(Circle().fill(AIUsagePalette.reset))
        case .idle, .warning, .limit:
            gaugeWithPercent
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch state.status {
        case .active, .waiting:
            gaugeWithPercent
        case .idle, .warning, .limit, .reset:
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let text = trailingText(now: context.date)
                Text(text.value)
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(text.color)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
    }

    private var gaugeWithPercent: some View {
        HStack(spacing: 6) {
            AIUsageGauge(percent: focus.primaryPercent, color: gauge, diameter: 15, lineWidth: 2.6 * 15 / 16)
            Text("\(Int(min(max(focus.primaryPercent, 0), 100).rounded()))%")
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(gauge)
                .fixedSize()
        }
    }

    private func trailingText(now: Date) -> (value: String, color: Color) {
        switch state.status {
        case .reset:
            return ("Ready", AIUsagePalette.reset)
        case .limit:
            let until = focus.limitingWindow?.window.resetsAt?.timeIntervalSince(now) ?? 0
            return (AIUsageFormat.clock(until), AIUsagePalette.critical)
        case .warning:
            return (remaining(now), AIUsagePalette.warning)
        default:
            return (remaining(now), .white.opacity(0.6))
        }
    }

    private func remaining(_ now: Date) -> String {
        guard let resetsAt = focus.fiveHour?.resetsAt ?? focus.weekly?.resetsAt else { return "5h 00m" }
        return AIUsageFormat.duration(resetsAt.timeIntervalSince(now))
    }
}

/// The permission bloom: what Claude wants to run, with Deny / Allow.
struct AIUsagePermissionBloom: View {
    let request: AIUsagePermissionRequest
    let answer: (AIUsagePermissionDecision) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(request.title)
                    .font(.system(size: 14, weight: .semibold))
                    .tracking(-0.14)
                Spacer(minLength: 0)
                Text("\(request.project) · Claude Code")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .lineLimit(1)
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    Text(request.toolName)
                        .foregroundStyle(AIUsagePalette.permissionText)
                        .fontWeight(.semibold)
                    Text(request.summary)
                        .foregroundStyle(.white.opacity(0.85))
                        .truncationMode(.tail)
                }
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, minHeight: 30, maxHeight: 30, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.white.opacity(0.09)))
                AIUsagePillButton(title: "Deny", style: .neutral, vertical: 7, horizontal: 14) { answer(.deny) }
                AIUsagePillButton(title: "Allow", style: .primary, vertical: 7, horizontal: 14) { answer(.allow) }
            }
        }
    }
}

// MARK: - Tab

/// The "AI Usage" tab of the open notch: agent tabs and plan, optional permission banner,
/// 5-hour ring, current session, weekly bar and 7-day activity (the design's expanded view,
/// below Atoll's own header).
struct AIUsageTabView: View {
    let state: AIUsageIslandState?
    @Binding var selectedAgent: AIUsageAgent
    let answer: (AIUsagePermissionDecision) -> Void

    /// Fixed parts of the tab, used by Atoll to size the open notch.
    static let agentRowHeight: CGFloat = 32
    static let detailHeight: CGFloat = 18 + 104 + 20
    static let bannerHeight: CGFloat = 10 + 52

    static func contentHeight(waiting: Bool) -> CGFloat {
        agentRowHeight + detailHeight + (waiting ? bannerHeight : 0)
    }

    var body: some View {
        if let state {
            content(state)
        } else {
            VStack(spacing: 6) {
                Image(systemName: "gauge.with.dots.needle.0percent")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                Text("No agents detected")
                    .font(.system(size: 13, weight: .semibold))
                Text("Sign in to Claude Code or Codex, or turn them on in Settings → AI Usage.")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func content(_ state: AIUsageIslandState) -> some View {
        let agent = state.agents.first { $0.agent == selectedAgent } ?? state.focus
        return GeometryReader { proxy in
            VStack(alignment: .leading, spacing: 0) {
                agentRow(state, selected: agent)
                    .frame(height: Self.agentRowHeight)
                    .modifier(AIUsageFadeIn(delay: 0.1))
                if let request = state.focus.pendingPermission {
                    AIUsagePermissionBanner(request: request, answer: answer)
                        .padding(.top, 10)
                        .modifier(AIUsageFadeIn(delay: 0.15))
                }
                AIUsageAgentDetail(agent: agent, state: state, width: proxy.size.width - 28)
                    .padding(EdgeInsets(top: 18, leading: 14, bottom: 20, trailing: 14))
                    .modifier(AIUsageFadeIn(delay: 0.15))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .foregroundStyle(.white)
    }

    private func agentRow(_ state: AIUsageIslandState, selected: AIUsageAgentSnapshot) -> some View {
        HStack(spacing: 2) {
            ForEach(state.agents, id: \.agent) { tab in
                let isSelected = tab.agent == selected.agent
                Button {
                    selectedAgent = tab.agent
                } label: {
                    HStack(spacing: 6) {
                        Circle().fill(tab.agent.color).frame(width: 7, height: 7)
                        Text(tab.agent.displayName)
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isSelected ? .white : .white.opacity(0.55))
                    .padding(.vertical, 4)
                    .padding(.horizontal, 10)
                    .background(Capsule().fill(isSelected ? .white.opacity(0.16) : .clear))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
            if let plan = selected.plan {
                Text(plan)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.vertical, 2)
                    .padding(.horizontal, 8)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.22), lineWidth: 1))
                    .help("Detected from your login")
            }
        }
    }
}

struct AIUsagePermissionBanner: View {
    let request: AIUsagePermissionRequest
    let answer: (AIUsagePermissionDecision) -> Void

    private var heading: String {
        switch request.kind {
        case .permission: return "Permission needed"
        case .question: return "Question"
        case .plan: return "Plan ready"
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            AIUsagePermissionBeacon()
            VStack(alignment: .leading, spacing: 2) {
                Text("\(heading) · \(request.project)")
                    .font(.system(size: 12, weight: .semibold))
                Group {
                    if request.needsDecision {
                        Text("\(request.toolName)  \(request.summary)")
                            .font(.system(size: 11, design: .monospaced))
                    } else {
                        Text(request.summary).font(.system(size: 11))
                    }
                }
                .foregroundStyle(.white.opacity(0.7))
                .truncationMode(.tail)
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            if request.needsDecision {
                AIUsagePillButton(title: "Deny", style: .neutral, vertical: 6, horizontal: 13) { answer(.deny) }
                AIUsagePillButton(title: "Allow", style: .primary, vertical: 6, horizontal: 13) { answer(.allow) }
            } else {
                Text("Answer in Claude Code")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(.trailing, 4)
            }
        }
        .padding(EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 10))
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(AIUsagePalette.permission.opacity(0.16)))
    }
}

/// Ring, current session and weekly column for one agent.
struct AIUsageAgentDetail: View {
    let agent: AIUsageAgentSnapshot
    let state: AIUsageIslandState
    /// Content width; columns follow the design's grid `104px 1fr 1.2fr`, 28 pt gaps.
    let width: CGFloat

    private var flexible: CGFloat { max(width - 104 - 28 * 2, 0) }

    private var percent: Double { agent.fiveHour?.usedPercent ?? agent.weekly?.usedPercent ?? 0 }
    private var ring: Color { state.gaugeColor(for: agent) }

    var body: some View {
        HStack(alignment: .center, spacing: 28) {
            ZStack {
                AIUsageGauge(percent: percent, color: ring, diameter: 104, lineWidth: 10 * 104 / 100, track: .white.opacity(0.14), inset: 8 * 104 / 100)
                VStack(spacing: 1) {
                    Text("\(Int(min(max(percent, 0), 100).rounded()))%")
                        .font(.system(size: 24, weight: .semibold).monospacedDigit())
                        .tracking(-0.48)
                    Text(agent.fiveHour != nil ? "of 5 hours" : agent.weekly != nil ? "of the week" : "no data yet")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
            .frame(width: 104, height: 104)

            TimelineView(.periodic(from: .now, by: 1)) { context in
                session(now: context.date)
            }
            .frame(width: flexible / 2.2, alignment: .leading)

            weeklyColumn
                .frame(width: flexible * 1.2 / 2.2, alignment: .leading)
        }
    }

    private func session(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Current session")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
            Text(headline(now: now))
                .font(.system(size: 20, weight: .semibold).monospacedDigit())
                .tracking(-0.2)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(windowRange)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
            HStack(spacing: 6) {
                activityGlyph
                Text(activityLabel)
                    .lineLimit(1)
            }
            .font(.system(size: 12))
            .foregroundStyle(activityColor)
            .padding(.top, 6)
        }
    }

    private var weeklyColumn: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let weekly = agent.weekly {
                HStack {
                    Text("Weekly")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                    Spacer()
                    Text("\(weekly.displayPercent)%")
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                }
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3).fill(.white.opacity(0.14))
                        RoundedRectangle(cornerRadius: 3)
                            .fill(state.tone(weekly.usedPercent) ?? agent.agent.color)
                            .frame(width: proxy.size.width * CGFloat(weekly.displayPercent) / 100)
                    }
                }
                .frame(height: 5)
            }
            AIUsageWeekChart(days: agent.history, color: agent.agent.color)
                .frame(height: 58)
                .padding(.top, 4)
            Text(weeklyReset)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
        }
    }

    private func headline(now: Date) -> String {
        if let limiting = agent.limitingWindow, let resetsAt = limiting.window.resetsAt {
            return "Available in \(AIUsageFormat.clock(resetsAt.timeIntervalSince(now)))"
        }
        if let resetsAt = agent.fiveHour?.resetsAt {
            return "Resets in \(AIUsageFormat.duration(resetsAt.timeIntervalSince(now)))"
        }
        return "Ready to start"
    }

    private var windowRange: String {
        guard let resetsAt = agent.fiveHour?.resetsAt else { return "Starts with your next message" }
        return "\(AIUsageFormat.time(resetsAt.addingTimeInterval(-5 * 3600))) – \(AIUsageFormat.time(resetsAt))"
    }

    private var weeklyReset: String {
        if let problem = agent.problem, !agent.hasQuota { return problem }
        guard let resetsAt = agent.weekly?.resetsAt else { return "" }
        return "Resets \(AIUsageFormat.dayAndTime(resetsAt))"
    }

    @ViewBuilder
    private var activityGlyph: some View {
        if agent.pendingPermission != nil {
            AIUsagePermissionBeacon()
        } else if agent.isWorking {
            AIUsageWorkingDots(color: agent.agent.color)
        } else {
            Circle()
                .fill(agent.isAtLimit ? AIUsagePalette.critical : .white.opacity(0.35))
                .frame(width: 7, height: 7)
        }
    }

    private var activityLabel: String {
        if let request = agent.pendingPermission { return request.activityLabel }
        if agent.isWorking { return "Working · \(agent.workingSources.joined(separator: ", "))" }
        if agent.isAtLimit { return "Paused until reset" }
        return "Idle"
    }

    private var activityColor: Color {
        if agent.pendingPermission != nil { return AIUsagePalette.permissionText }
        if agent.isWorking { return .white }
        return .white.opacity(0.55)
    }
}

/// Seven bars, today highlighted in the agent color.
struct AIUsageWeekChart: View {
    let days: [AIUsageDay]
    let color: Color

    var body: some View {
        let peak = max(days.map(\.tokens).max() ?? 0, 1)
        let calendar = Calendar.current
        let symbols: [String] = {
            var english = Calendar(identifier: .gregorian)
            english.locale = AIUsageFormat.locale
            return english.veryShortWeekdaySymbols
        }()
        HStack(alignment: .bottom, spacing: 6) {
            ForEach(Array(days.enumerated()), id: \.offset) { index, day in
                let isToday = index == days.count - 1
                VStack(spacing: 4) {
                    Spacer(minLength: 0)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(isToday ? color : .white.opacity(0.22))
                        .frame(height: max(3, 58 * CGFloat(day.tokens) / CGFloat(peak) * 0.78))
                    Text(symbols[calendar.component(.weekday, from: day.day) - 1])
                        .font(.system(size: 10))
                        .foregroundStyle(isToday ? .white : .white.opacity(0.45))
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

// MARK: - Building blocks

/// The design's SVG ring: track + rounded progress arc starting at 12 o'clock.
struct AIUsageGauge: View {
    let percent: Double
    let color: Color
    let diameter: CGFloat
    let lineWidth: CGFloat
    var track: Color = .white.opacity(0.2)
    /// Distance from the frame edge to the stroke center (the SVG's r = 6 of 16, 42 of 100).
    var inset: CGFloat? = nil

    var body: some View {
        let fraction = CGFloat(min(max(percent / 100, 0), 1))
        let padding = inset ?? diameter * 2 / 16
        ZStack {
            Circle().stroke(track, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.6), value: fraction)
        }
        .padding(padding)
        .frame(width: diameter, height: diameter)
    }
}

/// Three 5 pt dots pulsing 0.15 s apart over 1.1 s (`ciPulse`).
struct AIUsageWorkingDots: View {
    let color: Color

    var body: some View {
        TimelineView(.animation) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { index in
                    let level = Self.pulse(time: time - Double(index) * 0.15)
                    Circle()
                        .fill(color)
                        .frame(width: 5, height: 5)
                        .opacity(0.25 + 0.75 * level)
                        .scaleEffect(0.75 + 0.25 * level)
                }
            }
        }
    }

    /// 0 → 1 → 0 between 0%, 40% and 80% of the period, ease-in-out like the CSS keyframes.
    static func pulse(time: TimeInterval) -> Double {
        let period = 1.1
        var phase = time.truncatingRemainder(dividingBy: period) / period
        if phase < 0 { phase += 1 }
        func ease(_ t: Double) -> Double { t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2 }
        if phase < 0.4 { return ease(phase / 0.4) }
        if phase < 0.8 { return 1 - ease((phase - 0.4) / 0.4) }
        return 0
    }
}

/// 8 pt blue dot with a ring expanding 7 pt and fading over 1.4 s (`ciRing`).
struct AIUsagePermissionBeacon: View {
    var body: some View {
        TimelineView(.animation) { context in
            let progress = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4
            let eased = 1 - pow(1 - progress, 3)
            ZStack {
                Circle()
                    .fill(AIUsagePalette.permission.opacity(0.7 * (1 - eased)))
                    .frame(width: 8 + 14 * eased, height: 8 + 14 * eased)
                Circle()
                    .fill(AIUsagePalette.permission)
                    .frame(width: 8, height: 8)
            }
            .frame(width: 8, height: 8)
        }
    }
}

struct AIUsagePillButton: View {
    enum Style { case neutral, primary }

    let title: String
    let style: Style
    let vertical: CGFloat
    let horizontal: CGFloat
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.vertical, vertical)
                .padding(.horizontal, horizontal)
                .background(Capsule().fill(fill))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var fill: Color {
        switch style {
        case .neutral: return .white.opacity(hovering ? 0.22 : 0.14)
        case .primary: return hovering ? AIUsagePalette.permissionHover : AIUsagePalette.permission
        }
    }
}

/// `ciFade`: content fades in and drops 4 pt into place after the island has started growing.
struct AIUsageFadeIn: ViewModifier {
    let delay: Double
    @State private var visible = false

    func body(content: Content) -> some View {
        content
            .opacity(visible ? 1 : 0)
            .offset(y: visible ? 0 : -4)
            .onAppear {
                withAnimation(.easeOut(duration: 0.4).delay(delay)) { visible = true }
            }
    }
}
