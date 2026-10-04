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

enum AIUsageIslandPresentation: Equatable {
    case compact
    case bloom
}

/// Island sizes from the design, anchored to the real camera housing. The design's
/// 185 × 32 notch becomes `notch`; everything else keeps the design's widths and the same
/// height below the notch row:
///
/// - Compact 345 × 32, radius 12 (80 pt on each side of the notch)
/// - Alert 460 × 92, radius 26
/// - Permission 520 × 124, radius 30
/// - Spring 0.5 s, cubic-bezier(.32, .72, 0, 1)
struct AIUsageIslandGeometry: Equatable {
    static let designNotch = CGSize(width: 185, height: 32)
    static let wing: CGFloat = 80
    /// The design's 10 pt concave "ears" where the island meets the screen edge. Atoll's
    /// `NotchShape` draws them inside its rect, so surfaces are laid out this much wider.
    static let ear: CGFloat = 10
    static let spring = Animation.timingCurve(0.32, 0.72, 0, 1, duration: 0.5)

    let notch: CGSize

    init(notch: CGSize) {
        self.notch = CGSize(
            width: notch.width > 0 ? notch.width : Self.designNotch.width,
            height: notch.height > 0 ? notch.height : Self.designNotch.height
        )
    }

    private var extraHeight: CGFloat { notch.height - Self.designNotch.height }

    /// Visible island size (without the ears) and bottom corner radius.
    func shape(_ presentation: AIUsageIslandPresentation, waiting: Bool) -> (size: CGSize, radius: CGFloat) {
        switch presentation {
        case .compact:
            return (CGSize(width: notch.width + Self.wing * 2, height: notch.height), 12)
        case .bloom:
            return waiting
                ? (CGSize(width: max(520, notch.width + 160), height: 124 + extraHeight), 30)
                : (CGSize(width: max(460, notch.width + 160), height: 92 + extraHeight), 26)
        }
    }

    /// Size of the surface Atoll clips with `NotchShape` (visible island plus ears).
    func surface(_ presentation: AIUsageIslandPresentation, waiting: Bool) -> CGSize {
        let size = shape(presentation, waiting: waiting).size
        return CGSize(width: size.width + Self.ear * 2, height: size.height)
    }

    /// Open-notch height the AI Usage tab needs: Atoll's header row, the gaps Atoll puts
    /// around tab content, and the tab itself.
    static func openNotchHeight(notchHeight: CGFloat, waiting: Bool) -> CGFloat {
        max(24, notchHeight) + 20 + AIUsageTabView.contentHeight(waiting: waiting)
    }
}
