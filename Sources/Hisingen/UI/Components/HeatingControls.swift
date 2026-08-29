import SwiftUI

@MainActor
struct SeatHeatingControl: View {
    let title: String
    @Binding var level: HeatingLevel
    let onChange: @MainActor (HeatingLevel) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)

            Button {
                let nextLevel: HeatingLevel
                switch level {
                case .unspecified, .off: nextLevel = .level1
                case .level1: nextLevel = .level2
                case .level2: nextLevel = .level3
                case .level3: nextLevel = .off
                }
                level = nextLevel
                onChange(nextLevel)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "carseat.left.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(level != .off && level != .unspecified ? Color.orange : Color.secondary)


                    HStack(spacing: 2) {
                        ForEach(1...3, id: \.self) { bar in
                            RoundedRectangle(cornerRadius: 1)
                                .fill(barActive(bar) ? Color.orange : Color.secondary.opacity(0.25))
                                .frame(width: 4, height: 8)
                        }
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 28)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private func barActive(_ bar: Int) -> Bool {
        switch level {
        case .level1: return bar == 1
        case .level2: return bar <= 2
        case .level3: return true
        default: return false
        }
    }
}

@MainActor
struct SteeringHeatingControl: View {
    @Binding var level: HeatingLevel
    let onChange: @MainActor (HeatingLevel) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.text("Steering Wheel"))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)

            Button {
                let next = (level == .level3 || level == .level2 || level == .level1) ? HeatingLevel.off : HeatingLevel.level3
                level = next
                onChange(next)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "steeringwheel")
                        .font(.system(size: 12))
                        .foregroundStyle(isActive ? Color.orange : Color.secondary)
                    Text(L10n.text(isActive ? "ON" : "OFF"))
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(isActive ? Color.orange : Color.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 28)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private var isActive: Bool {
        level == .level3 || level == .level2 || level == .level1
    }
}
