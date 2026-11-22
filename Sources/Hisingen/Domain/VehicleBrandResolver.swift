import Foundation

/// Which account a VIN belongs to.
///
/// The shell, the Shortcuts hand-off and the command-line surface all resolve a VIN through this
/// one rule, so no entry point can disagree with the shell about which brand's session a command
/// belongs to. It was a method on the session controller, which is the shell's private state; the
/// command line needed the same answer without a shell.
enum VehicleBrandResolver {
    /// `snapshotBrand` is the brand the vehicle's own stored reading reported, when the caller has
    /// one: a VIN can belong to the dormant account, and its snapshot knows that even when the
    /// manufacturer prefix and the two configured VINs do not settle it.
    ///
    /// Main-actor because the two configured VINs and the active brand are preference reads, and
    /// every caller (the session controller, the command line) already is.
    @MainActor
    static func brand(
        for vin: String,
        snapshotBrand: VehicleBrand?,
        preferences: PreferencesStore
    ) -> VehicleBrand {
        let upper = vin.normalizedVIN
        if let snapshotBrand { return snapshotBrand }
        if !preferences.vin(for: .volvo).isEmpty, upper == preferences.vin(for: .volvo).uppercased() {
            return .volvo
        }
        if !preferences.vin(for: .polestar).isEmpty, upper == preferences.vin(for: .polestar).uppercased() {
            return .polestar
        }
        if VehicleBrand.isVolvoVIN(upper) { return .volvo }
        if upper.hasPrefix("YS") || upper.hasPrefix("LP") { return .polestar }
        return preferences.activeBrand
    }
}
