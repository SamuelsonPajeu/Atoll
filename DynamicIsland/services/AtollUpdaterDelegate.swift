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
import Sparkle

/// Custom Sparkle updater delegate that dynamically returns the feed URL
/// based on the user's selected update channel preference.
class AtollUpdaterDelegate: NSObject, SPUUpdaterDelegate {
    func feedURLString(for updater: SPUUpdater) -> String? {
        return Defaults[.updateChannel].feedURL.absoluteString
    }

    /// This build is a fork (AI Usage island). Upstream releases would replace it, so
    /// update checks are refused; rebuild from the fork to update.
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        throw NSError(
            domain: "com.ebullioscopic.Atoll.fork",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Updates are disabled in this fork of Atoll. Rebuild it from the fork's source to update."]
        )
    }
}
