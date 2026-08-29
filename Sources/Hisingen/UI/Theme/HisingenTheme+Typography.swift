import SwiftUI

@MainActor
extension HisingenTheme {

    static var headingWeight: Font.Weight {
        switch theme {
        case .polestar: return .regular
        case .volvo, .sandDune: return .medium
        case .hisingen, .nordicNight, .aurora, .forest: return .semibold
        case .swedishGold, .cyanRacing: return .bold
        }
    }
    static var valueWeight: Font.Weight {
        switch theme {
        case .polestar: return .regular
        case .volvo, .sandDune: return .medium
        case .hisingen, .nordicNight, .aurora, .forest: return .semibold
        case .swedishGold, .cyanRacing: return .bold
        }
    }
    static var displayWeight: Font.Weight {
        switch theme {
        case .polestar: return .regular
        case .volvo, .cyanRacing: return .black
        case .nordicNight, .swedishGold: return .heavy
        case .hisingen, .aurora, .forest, .sandDune: return .bold
        }
    }
    static var displayTracking: CGFloat {
        switch theme {
        case .polestar: return -1.2
        case .cyanRacing: return -0.8
        case .swedishGold: return -0.6
        case .nordicNight: return -0.5
        case .volvo: return -0.4
        case .sandDune: return -0.3
        case .aurora: return -0.2
        case .hisingen, .forest: return 0
        }
    }
}
