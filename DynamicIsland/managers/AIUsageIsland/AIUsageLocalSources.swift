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

/// Local, credential-free signals for the AI Usage island: live Claude sessions, daily
/// token activity, and the rate limits the Codex CLI writes into its own logs.
enum AIUsagePaths {
    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// Honors `CLAUDE_CONFIG_DIR` like Claude Code does.
    static var claudeConfig: URL {
        if let custom = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
        }
        return home.appendingPathComponent(".claude")
    }

    static var claudeProjects: URL { claudeConfig.appendingPathComponent("projects") }
    static var claudeSessions: URL { claudeConfig.appendingPathComponent("sessions") }
    static var claudeSettings: URL { claudeConfig.appendingPathComponent("settings.json") }

    /// Honors `CODEX_HOME` like the Codex CLI does.
    static var codexHome: URL {
        if let custom = ProcessInfo.processInfo.environment["CODEX_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
        }
        return home.appendingPathComponent(".codex")
    }

    static var codexSessions: URL { codexHome.appendingPathComponent("sessions") }
}

enum AIUsageJSON {
    static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func double(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber: return number.doubleValue
        case let string as String: return Double(string)
        default: return nil
        }
    }

    /// ISO-8601 with or without fractional seconds, or Unix epoch seconds/milliseconds.
    static func date(_ value: Any?) -> Date? {
        if let string = value as? String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: string) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: string) { return date }
        }
        guard let raw = double(value), raw > 0 else { return nil }
        return Date(timeIntervalSince1970: raw > 100_000_000_000 ? raw / 1000 : raw)
    }
}

// MARK: - Claude sessions

enum AIUsageClaudeSurface: String, Sendable {
    case code = "Code"
    case desktop = "Desktop"
}

struct AIUsageClaudeSession: Equatable, Sendable {
    let sessionID: String
    let cwd: String?
    let surface: AIUsageClaudeSurface
    let isBusy: Bool
}

/// Claude Code keeps one `<pid>.json` per running session in `~/.claude/sessions`,
/// including whether it is busy. Reading it gives live activity without any setup; files
/// left behind by crashed processes are skipped by checking the pid.
enum AIUsageClaudeSessionRegistry {
    static func liveSessions(in directory: URL = AIUsagePaths.claudeSessions) -> [AIUsageClaudeSession] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
        return files.filter { $0.pathExtension == "json" }.compactMap { url in
            guard let data = try? Data(contentsOf: url),
                  let object = AIUsageJSON.object(data),
                  let pid = AIUsageJSON.double(object["pid"]).map({ Int32($0) }),
                  isAlive(pid)
            else { return nil }
            let status = (object["status"] as? String ?? "").lowercased()
            let entrypoint = (object["entrypoint"] as? String ?? "").lowercased()
            return AIUsageClaudeSession(
                sessionID: object["sessionId"] as? String ?? url.deletingPathExtension().lastPathComponent,
                cwd: object["cwd"] as? String,
                surface: entrypoint.contains("desktop") ? .desktop : .code,
                isBusy: status == "busy" || status == "running" || status == "working"
            )
        }
    }

    static func isAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }
}

// MARK: - Claude daily activity

/// Token activity per day from Claude Code transcripts for the 7-day chart. Only token
/// counts and timestamps are read; prompts and responses are ignored.
final class AIUsageClaudeHistory {
    private struct Entry {
        let day: Date
        let tokens: Int
    }

    private struct CachedFile {
        let modified: Date
        let size: Int
        let entries: [String: Entry]
    }

    private var cache: [String: CachedFile] = [:]
    private static let usageMarker = Data("\"usage\"".utf8)

    func days(now: Date = Date(), calendar: Calendar = .current, count: Int = 7) -> [AIUsageDay] {
        let firstDay = calendar.date(byAdding: .day, value: -(count - 1), to: calendar.startOfDay(for: now))!
        var seen = Set<String>()
        var totals: [Date: Int] = [:]
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]

        if let enumerator = FileManager.default.enumerator(at: AIUsagePaths.claudeProjects, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) {
            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                      let modified = values.contentModificationDate, modified >= firstDay else { continue }
                // Resumed sessions copy earlier messages into a new transcript; count each once.
                for (key, entry) in entries(for: url, modified: modified, size: values.fileSize ?? 0, calendar: calendar)
                where entry.day >= firstDay && seen.insert(key).inserted {
                    totals[entry.day, default: 0] += entry.tokens
                }
            }
        }
        cache = cache.filter { $0.value.modified >= firstDay }
        return (0..<count).map { offset in
            let day = calendar.date(byAdding: .day, value: offset, to: firstDay)!
            return AIUsageDay(day: day, tokens: totals[day] ?? 0)
        }
    }

    private func entries(for url: URL, modified: Date, size: Int, calendar: Calendar) -> [String: Entry] {
        if let cached = cache[url.path], cached.modified == modified, cached.size == size { return cached.entries }
        var entries: [String: Entry] = [:]
        if let data = try? Data(contentsOf: url, options: .mappedIfSafe) {
            for line in data.split(separator: UInt8(ascii: "\n")) where line.range(of: Self.usageMarker) != nil {
                guard let object = AIUsageJSON.object(Data(line)),
                      object["type"] as? String == "assistant",
                      let message = object["message"] as? [String: Any],
                      let usage = message["usage"] as? [String: Any],
                      let timestamp = AIUsageJSON.date(object["timestamp"])
                else { continue }
                let tokens = Int(AIUsageJSON.double(usage["input_tokens"]) ?? 0)
                    + Int(AIUsageJSON.double(usage["output_tokens"]) ?? 0)
                    + Int(AIUsageJSON.double(usage["cache_creation_input_tokens"]) ?? 0)
                let key = "\(message["id"] as? String ?? object["uuid"] as? String ?? UUID().uuidString):\(object["requestId"] as? String ?? "")"
                entries[key] = Entry(day: calendar.startOfDay(for: timestamp), tokens: tokens)
            }
        }
        cache[url.path] = CachedFile(modified: modified, size: size, entries: entries)
        return entries
    }
}

// MARK: - Codex logs

/// Reads what the Codex CLI writes to `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`: each
/// `token_count` event carries cumulative token totals and the account's current rate
/// limits and plan. Works offline, without touching credentials.
final class AIUsageCodexLogs {
    struct Quota: Equatable {
        var fiveHour: AIUsageWindow?
        var weekly: AIUsageWindow?
        var plan: String?
        var observedAt: Date
    }

    struct Summary {
        var latestQuota: Quota?
        var days: [AIUsageDay]
        var lastWrite: Date?
    }

    private struct ParsedFile {
        let modified: Date
        let size: Int
        let deltas: [(day: Date, tokens: Int)]
        let quota: Quota?
    }

    private var cache: [String: ParsedFile] = [:]
    private static let marker = Data("\"token_count\"".utf8)

    var isInstalled: Bool { FileManager.default.fileExists(atPath: AIUsagePaths.codexHome.path) }

    func summary(now: Date = Date(), calendar: Calendar = .current, count: Int = 7) -> Summary {
        let firstDay = calendar.date(byAdding: .day, value: -(count - 1), to: calendar.startOfDay(for: now))!
        var totals: [Date: Int] = [:]
        var latest: Quota?
        var lastWrite: Date?

        for file in rolloutFiles(since: firstDay, now: now, calendar: calendar) {
            let parsed = parse(file.url, modified: file.modified, size: file.size, calendar: calendar)
            for delta in parsed.deltas where delta.day >= firstDay { totals[delta.day, default: 0] += delta.tokens }
            if let quota = parsed.quota, quota.observedAt > (latest?.observedAt ?? .distantPast) { latest = quota }
            if file.modified > (lastWrite ?? .distantPast) { lastWrite = file.modified }
        }
        cache = cache.filter { $0.value.modified >= firstDay }
        if latest == nil { latest = newestQuotaAnywhere(calendar: calendar) }

        let days = (0..<count).map { offset -> AIUsageDay in
            let day = calendar.date(byAdding: .day, value: offset, to: firstDay)!
            return AIUsageDay(day: day, tokens: totals[day] ?? 0)
        }
        return Summary(latestQuota: latest, days: days, lastWrite: lastWrite)
    }

    /// Plan claim from the `id_token` the Codex CLI stored (not a credential check).
    static func planFromAuth() -> String? {
        guard let data = try? Data(contentsOf: AIUsagePaths.codexHome.appendingPathComponent("auth.json")),
              let tokens = AIUsageJSON.object(data)?["tokens"] as? [String: Any],
              let idToken = tokens["id_token"] as? String else { return nil }
        let parts = idToken.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var segment = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while segment.count % 4 != 0 { segment += "=" }
        guard let payload = Data(base64Encoded: segment).flatMap(AIUsageJSON.object),
              let auth = payload["https://api.openai.com/auth"] as? [String: Any] else { return nil }
        return planLabel(auth["chatgpt_plan_type"] as? String)
    }

    static func planLabel(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !raw.isEmpty else { return nil }
        let known = ["free": "Free", "go": "Go", "plus": "Plus", "pro": "Pro", "team": "Team",
                     "business": "Business", "enterprise": "Enterprise", "edu": "Edu"]
        return known[raw] ?? raw.prefix(1).uppercased() + raw.dropFirst()
    }

    /// Codex reports positional windows; their meaning comes from the duration.
    static func assign(_ windows: [AIUsageWindow], to quota: inout Quota) {
        for window in windows {
            let duration = window.duration ?? 0
            if duration > 0, duration <= 6 * 3600 {
                quota.fiveHour = quota.fiveHour ?? window
            } else if duration >= 6 * 86400 {
                quota.weekly = quota.weekly ?? window
            } else if quota.fiveHour == nil {
                quota.fiveHour = window
            } else if quota.weekly == nil {
                quota.weekly = window
            }
        }
    }

    /// Rollouts live in per-day folders named after the session's start; long sessions keep
    /// writing to the folder of the day they started, hence the extra lookback.
    private func rolloutFiles(since firstDay: Date, now: Date, calendar: Calendar) -> [(url: URL, modified: Date, size: Int)] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        var files: [(URL, Date, Int)] = []
        var day = calendar.date(byAdding: .day, value: -30, to: firstDay)!
        while day <= now {
            let parts = calendar.dateComponents([.year, .month, .day], from: day)
            let folder = AIUsagePaths.codexSessions.appendingPathComponent(String(format: "%04d/%02d/%02d", parts.year!, parts.month!, parts.day!))
            day = calendar.date(byAdding: .day, value: 1, to: day)!
            guard let contents = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys) else { continue }
            for url in contents where url.pathExtension == "jsonl" {
                guard let values = try? url.resourceValues(forKeys: Set(keys)),
                      let modified = values.contentModificationDate, modified >= firstDay else { continue }
                files.append((url, modified, values.fileSize ?? 0))
            }
        }
        return files
    }

    private func newestQuotaAnywhere(calendar: Calendar) -> Quota? {
        guard let enumerator = FileManager.default.enumerator(at: AIUsagePaths.codexSessions, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        var newest: (URL, Date)?
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if modified > (newest?.1 ?? .distantPast) { newest = (url, modified) }
        }
        guard let (url, modified) = newest else { return nil }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        return parse(url, modified: modified, size: size, calendar: calendar).quota
    }

    private func parse(_ url: URL, modified: Date, size: Int, calendar: Calendar) -> ParsedFile {
        if let cached = cache[url.path], cached.modified == modified, cached.size == size { return cached }
        var deltas: [(Date, Int)] = []
        var quota: Quota?
        var previousTotal = 0
        if let data = try? Data(contentsOf: url, options: .mappedIfSafe) {
            for line in data.split(separator: UInt8(ascii: "\n")) where line.range(of: Self.marker) != nil {
                guard let object = AIUsageJSON.object(Data(line)),
                      let payload = object["payload"] as? [String: Any], payload["type"] as? String == "token_count",
                      let timestamp = AIUsageJSON.date(object["timestamp"]) else { continue }
                let info = payload["info"] as? [String: Any]
                if let total = AIUsageJSON.double((info?["total_token_usage"] as? [String: Any])?["total_tokens"]).map({ Int($0) }) {
                    // Totals are cumulative per session; attribute the growth to the event's day.
                    if total > previousTotal { deltas.append((calendar.startOfDay(for: timestamp), total - previousTotal)) }
                    previousTotal = max(previousTotal, total)
                }
                guard let limits = payload["rate_limits"] as? [String: Any] else { continue }
                var parsed = Quota(plan: Self.planLabel(limits["plan_type"] as? String), observedAt: timestamp)
                let windows = ["primary", "secondary"].compactMap { key -> AIUsageWindow? in
                    guard let raw = limits[key] as? [String: Any], let used = AIUsageJSON.double(raw["used_percent"]) else { return nil }
                    let resetsAt = AIUsageJSON.date(raw["resets_at"])
                        ?? AIUsageJSON.double(raw["resets_in_seconds"]).map { timestamp.addingTimeInterval($0) }
                    return AIUsageWindow(usedPercent: used, resetsAt: resetsAt, duration: AIUsageJSON.double(raw["window_minutes"]).map { $0 * 60 })
                }
                Self.assign(windows, to: &parsed)
                if parsed.fiveHour != nil || parsed.weekly != nil || parsed.plan != nil { quota = parsed }
            }
        }
        let parsed = ParsedFile(modified: modified, size: size, deltas: deltas, quota: quota)
        cache[url.path] = parsed
        return parsed
    }
}
