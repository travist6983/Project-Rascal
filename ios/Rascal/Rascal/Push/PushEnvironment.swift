import Foundation

/// Which APNs host the server should send this phone's token to.
///
/// **This is the field that makes push work in development and silently fail in TestFlight.**
/// A token minted under a development provisioning profile is only addressable on Apple's
/// sandbox host; one minted under a distribution profile is only addressable on production.
/// Send the wrong value and APNs accepts the request and delivers nothing — there is no error
/// to read, on either side.
///
/// `POST /v1/devices` requires it and gives it no default, deliberately: the server cannot know
/// how this build was signed and refuses to guess.
nonisolated enum PushEnvironment: String, Codable, Equatable, Sendable, CaseIterable {
    case sandbox
    case production

    /// Derived from the build configuration, never hardcoded and never read from config.
    ///
    /// **Debug is the only sandbox case.** A Debug build is installed by Xcode with a
    /// development profile, whose `aps-environment` entitlement is `development`. Every other
    /// build — TestFlight and the App Store alike — is signed with a distribution profile whose
    /// entitlement is `production`, and TestFlight is not a separate APNs environment: it ships
    /// through App Store infrastructure and addresses the production host.
    ///
    /// `docs/api-contract.md` describes TestFlight as `sandbox`. That description is wrong, and
    /// treating it as correct is exactly the defect above — see `docs/phases/DECISIONS.md`
    /// D-003. The enum values themselves agree across both sides; only the prose differs.
    static var current: PushEnvironment {
        #if DEBUG
        .sandbox
        #else
        .production
        #endif
    }
}
