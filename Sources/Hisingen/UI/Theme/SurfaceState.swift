import SwiftUI
import AppKit

/// Distinct interaction states for surfaces and interactive controls across the app.
///
/// Replaces arbitrary call-site `.opacity()` modifiers with a unified, measurable state vocabulary.
enum SurfaceState: String, CaseIterable, Sendable {
    /// A faint neutral resting state for subtle buttons, chips, and unselected rows.
    case ghost
    /// A recessed/sunken surface (e.g. text input fields, inset wells).
    case inset
    /// An element currently selected by the user.
    case selected
    /// A pointer hovering over an interactive element.
    case hovered
    /// A pressed or active state during interaction.
    case active
}

@MainActor
extension HisingenTheme {
    /// Fill colour for a surface in a given interaction state.
    static func fill(_ state: SurfaceState) -> Color {
        palette.fill(state)
    }

    /// Boundary stroke colour for a surface in a given interaction state.
    static func stroke(_ state: SurfaceState) -> Color {
        palette.stroke(state)
    }
}
