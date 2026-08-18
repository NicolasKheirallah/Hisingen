import Foundation


enum VehicleBrand: String, Codable, Sendable, CaseIterable {
    case polestar
    case volvo

    var displayName: String {
        switch self {
        case .polestar: return "Polestar"
        case .volvo: return "Volvo"
        }
    }
}


enum PowertrainType: String, Codable, Sendable {
    case bev
    case phev
    case ice
    case mildHybrid
    case unknown

    var displayName: String {
        switch self {
        case .bev: return L10n.text("Electric")
        case .phev: return L10n.text("Plug-in hybrid")
        case .ice: return L10n.text("Combustion")
        case .mildHybrid: return L10n.text("Mild hybrid")
        case .unknown: return L10n.text("Unknown")
        }
    }

    var hasElectricRange: Bool { self == .bev || self == .phev || self == .mildHybrid }
    var hasFuelRange: Bool { self == .ice || self == .phev || self == .mildHybrid }
    var hasCombustionEngine: Bool { self == .ice || self == .phev || self == .mildHybrid }
    var isHybrid: Bool { self == .phev || self == .mildHybrid }
    var isCombustionOnly: Bool { self == .ice }
    var isElectricOnly: Bool { self == .bev }
}


