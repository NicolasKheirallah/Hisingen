import Foundation

/// The Polestar Android app build that Hisingen presents to Polestar's app-backend endpoint
/// (vehicle discovery through VDMS).
///
/// That endpoint is gated on app version: below its current floor it answers
/// `426 Upgrade Required`, and so does a version that matches no released build. Hisingen is not
/// Polestar's app, and sending these values is how it passes that gate. When discovery starts
/// failing with 426, `version` and `userAgent` are the two values to bump, together, to a build
/// that is currently released. The same pair appears in kildahldev/unofficial-polestar-api, which
/// hit the same 426 (see THIRD_PARTY_NOTICES.md).
enum PolestarAppIdentity {
    static let version = "5.11.0"
    static let userAgent = "PolestarApp/5.11.0b1111 Android/14"

    /// The GraphQL client library the app reports in its request extensions.
    static let graphQLClientLibrary = (name: "apollo-kotlin", version: "4.4.1")
}
