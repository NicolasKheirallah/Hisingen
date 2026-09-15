import SwiftUI

/// The shared presentation for an empty data surface.
///
/// `ContentUnavailableView` supplies the platform's spacing, text hierarchy and accessibility
/// semantics. Callers still own the symbol and copy because an empty search, an unread vehicle
/// reading and a date range with no samples need different explanations and recovery paths.
struct HisingenEmptyState<Actions: View>: View {
    let symbol: String
    let title: String
    let message: String?
    @ViewBuilder let actions: Actions

    init(
        symbol: String,
        title: String,
        message: String? = nil,
        @ViewBuilder actions: () -> Actions
    ) {
        self.symbol = symbol
        self.title = title
        self.message = message
        self.actions = actions()
    }

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            if let message {
                Text(message)
            }
        } actions: {
            actions
        }
        .symbolRenderingMode(.hierarchical)
        .frame(maxWidth: .infinity)
    }
}

extension HisingenEmptyState where Actions == EmptyView {
    init(symbol: String, title: String, message: String? = nil) {
        self.init(symbol: symbol, title: title, message: message) { EmptyView() }
    }
}
