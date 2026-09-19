import SwiftUI

/// Observes the panel's single model and rebuilds the content whenever the app layer
/// publishes new display state.
@MainActor
struct PopoverRootView: View {
    @ObservedObject var model: PanelModel
    let content: @MainActor (PanelModel) -> AnyView

    var body: some View { content(model) }
}
