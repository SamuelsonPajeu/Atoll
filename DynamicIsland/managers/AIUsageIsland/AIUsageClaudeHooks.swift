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

/// The subset of a Claude Code hook payload the island uses.
struct AIUsageHookEvent {
    let name: String
    let sessionID: String?
    let cwd: String?
    let toolName: String?
    let toolUseID: String?
    let toolSummary: String?

    init?(json data: Data) {
        guard let object = AIUsageJSON.object(data), let name = object["hook_event_name"] as? String else { return nil }
        self.name = name
        sessionID = object["session_id"] as? String
        cwd = object["cwd"] as? String
        toolName = object["tool_name"] as? String
        toolUseID = object["tool_use_id"] as? String
        let input = object["tool_input"] as? [String: Any]
        switch toolName {
        case "AskUserQuestion":
            // The first question's text; the options are answered in Claude Code.
            let first = (input?["questions"] as? [[String: Any]])?.first
            toolSummary = Self.clip((first?["question"] as? String) ?? (first?["header"] as? String) ?? "Answer in Claude Code")
        case "ExitPlanMode":
            toolSummary = "Review it in Claude Code"
        default:
            toolSummary = Self.summarize(input)
        }
    }

    /// Questions and plan reviews are forms, not yes/no permissions.
    var requestKind: AIUsagePermissionRequest.Kind {
        switch toolName {
        case "AskUserQuestion": return .question
        case "ExitPlanMode": return .plan
        default: return .permission
        }
    }

    static func clip(_ text: String) -> String {
        let line = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return line.count > 140 ? String(line.prefix(139)) + "…" : line
    }

    var project: String {
        guard let cwd, !cwd.isEmpty else { return "Claude Code" }
        return URL(fileURLWithPath: cwd).lastPathComponent
    }

    /// One line describing what the tool wants to do, e.g. "npm test -- --watch=false".
    static func summarize(_ input: [String: Any]?) -> String? {
        guard let input else { return nil }
        let preferred = ["command", "file_path", "path", "url", "pattern", "query", "notebook_path", "description", "prompt"]
        guard let key = preferred.first(where: { input[$0] is String }) ?? input.first(where: { $0.value is String })?.key,
              var text = (input[key] as? String)?.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces),
              !text.isEmpty else { return nil }
        if key == "file_path" || key == "notebook_path" { text = (text as NSString).lastPathComponent }
        return text.count > 140 ? String(text.prefix(139)) + "…" : text
    }
}

enum AIUsagePermissionDecision: String {
    case allow
    case deny

    /// Hook stdout understood by Claude Code's `PermissionRequest` decision control.
    var hookOutput: Data {
        var decision: [String: Any] = ["behavior": rawValue]
        if self == .deny { decision["message"] = "Denied from the notch (Atoll)." }
        let output: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]]
        return (try? JSONSerialization.data(withJSONObject: output)) ?? Data()
    }
}

/// Files the hook command needs, readable only by the current user:
/// `claude-hook.sh` and the curl config holding the server's port and per-launch secret.
enum AIUsageHookFiles {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Atoll/AIUsage", isDirectory: true)
    }

    static var script: URL { directory.appendingPathComponent("claude-hook.sh") }
    static var curlConfig: URL { directory.appendingPathComponent("hook.curlrc") }

    /// Forwards the hook payload (stdin) to Atoll and prints Atoll's answer. Exits 0 with no
    /// output when Atoll is not running, so Claude Code then behaves as if there were no hook.
    static let scriptContents = """
    #!/bin/sh
    # Atoll AI Usage: forwards Claude Code hook events to Atoll's notch.
    CONFIG="$(dirname "$0")/hook.curlrc"
    [ -r "$CONFIG" ] || exit 0
    /usr/bin/curl --silent --fail --noproxy '*' --max-time 590 -K "$CONFIG" \\
      -H 'Content-Type: application/json' --data-binary @- 2>/dev/null
    exit 0
    """

    static func writeScript() throws {
        try prepareDirectory()
        try scriptContents.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    }

    static func writeConfig(port: UInt16, token: String) throws {
        try prepareDirectory()
        let contents = "url = \"http://127.0.0.1:\(port)/hook\"\nheader = \"X-Atoll-AIUsage-Token: \(token)\"\n"
        let path = curlConfig.path
        // Create with 0600 before the secret is written so it is never world-readable.
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        try Data(contents.utf8).write(to: curlConfig)
    }

    static func removeConfig() {
        try? FileManager.default.removeItem(at: curlConfig)
    }

    private static func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
}

/// Adds/removes Atoll's hooks in Claude Code's user settings. Runs only when the user
/// clicks "Connect" in Settings; other settings and hooks are preserved and a one-time
/// backup is written next to the file.
struct AIUsageHookInstaller {
    static let marker = "Atoll/AIUsage/claude-hook.sh"

    static let events: [(name: String, matcher: String?, timeout: Int?)] = [
        ("PermissionRequest", "*", 600),
        ("PostToolUse", "*", 10),
        ("UserPromptSubmit", nil, 10),
        ("Stop", nil, 10),
        ("SessionEnd", nil, 10)
    ]

    var settingsURL = AIUsagePaths.claudeSettings

    var command: String {
        "'\(AIUsageHookFiles.script.path.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    var isInstalled: Bool {
        guard let hooks = (try? readSettings())?["hooks"] as? [String: Any] else { return false }
        let installed = Set(hooks.compactMap { name, value -> String? in
            guard let groups = value as? [[String: Any]] else { return nil }
            let ours = groups.contains { ($0["hooks"] as? [[String: Any]])?.contains { ($0["command"] as? String) == command } ?? false }
            return ours ? name : nil
        })
        return Set(Self.events.map(\.name)).isSubset(of: installed)
    }

    func install() throws {
        var settings = try readSettings()
        try AIUsageHookFiles.writeScript()
        try backupOnce()
        var hooks = Self.removingOurs(from: settings["hooks"] as? [String: Any] ?? [:])
        for event in Self.events {
            var hook: [String: Any] = ["type": "command", "command": command]
            if let timeout = event.timeout { hook["timeout"] = timeout }
            var group: [String: Any] = ["hooks": [hook]]
            if let matcher = event.matcher { group["matcher"] = matcher }
            hooks[event.name] = (hooks[event.name] as? [[String: Any]] ?? []) + [group]
        }
        settings["hooks"] = hooks
        try write(settings)
    }

    func uninstall() throws {
        var settings = try readSettings()
        guard let hooks = settings["hooks"] as? [String: Any] else { return }
        let cleaned = Self.removingOurs(from: hooks)
        if cleaned.isEmpty { settings.removeValue(forKey: "hooks") } else { settings["hooks"] = cleaned }
        try write(settings)
    }

    static func removingOurs(from hooks: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [:]
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else {
                result[event] = value
                continue
            }
            let kept = groups.compactMap { group -> [String: Any]? in
                guard let entries = group["hooks"] as? [[String: Any]] else { return group }
                let filtered = entries.filter { !(($0["command"] as? String)?.contains(marker) ?? false) }
                if filtered.isEmpty { return nil }
                var copy = group
                copy["hooks"] = filtered
                return copy
            }
            if !kept.isEmpty { result[event] = kept }
        }
        return result
    }

    enum InstallError: LocalizedError {
        case unreadableSettings
        var errorDescription: String? { "~/.claude/settings.json is not valid JSON, so it was left untouched." }
    }

    private func readSettings() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return [:] }
        let data = try Data(contentsOf: settingsURL)
        if String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [:] }
        guard let object = AIUsageJSON.object(data) else { throw InstallError.unreadableSettings }
        return object
    }

    private func backupOnce() throws {
        let backup = settingsURL.appendingPathExtension("atoll-backup")
        guard FileManager.default.fileExists(atPath: settingsURL.path),
              !FileManager.default.fileExists(atPath: backup.path) else { return }
        try FileManager.default.copyItem(at: settingsURL, to: backup)
    }

    private func write(_ settings: [String: Any]) throws {
        try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: settingsURL, options: .atomic)
    }
}
