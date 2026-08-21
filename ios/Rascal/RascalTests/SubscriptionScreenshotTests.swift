import Foundation
import SwiftUI
import Testing
import UIKit

@testable import Rascal

/// Renders the paywall and the Settings row at accessibility text sizes and writes PNGs.
///
/// **Phase 61 shipped without these and its row says so; this is the phase not repeating that.**
/// The predicted defect was truncation in the price comparison, where a computed saving string
/// sits beside two prices — which is why `PlanRow` stacks its three strings vertically instead of
/// putting them on one line, and why these renders exist to show it holds.
///
/// `ImageRenderer` rather than a simulator screenshot, and that is what makes it possible at all:
/// the paywall renders from `OfferedPlan` values rather than from StoreKit `Product`s, so it can
/// be built at any text size with no store, no session and no taps. A simulator screenshot of this
/// screen would need a working `SKTestSession`, which this machine does not have — see
/// `SubscriptionStoreKitTests`.
///
/// Output goes to `$RASCAL_SCREENSHOT_DIR`, or a temporary directory whose path is printed.
@MainActor
@Suite("Dynamic Type — the paywall and the membership row")
struct SubscriptionScreenshotTests {

    private static let sizes: [(name: String, size: DynamicTypeSize)] = [
        ("xxLarge", .xxLarge),
        ("accessibility3", .accessibility3),
        ("accessibility5", .accessibility5),
    ]

    private static var outputDirectory: URL {
        if let raw = ProcessInfo.processInfo.environment["RASCAL_SCREENSHOT_DIR"], !raw.isEmpty {
            return URL(fileURLWithPath: raw, isDirectory: true)
        }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("rascal-phase-37b", isDirectory: true)
    }

    @Test("the paywall renders at every accessibility size, in both of its states")
    func paywallRenders() throws {
        // Ready, with a trial and a computed saving — the state carrying the three strings that
        // could collide.
        let ready = SubscriptionModel(previewing: .ready(.double, familyID: UUID()))
        // And the retry, which is what an empty product load must look like rather than a blank.
        let unavailable = SubscriptionModel(
            previewing: .unavailable(SubscriptionStoreError.productsUnavailable.userMessage)
        )

        for (label, size) in Self.sizes {
            try render(
                PaywallSheet(model: ready, context: .secondParent) {}.content,
                named: "paywall-secondParent-\(label)",
                at: size
            )
            try render(
                PaywallSheet(model: ready, context: .settings) {}.content,
                named: "paywall-settings-\(label)",
                at: size
            )
            try render(
                PaywallSheet(model: unavailable, context: .settings) {}.content,
                named: "paywall-unavailable-\(label)",
                at: size
            )
        }
    }

    @Test("the membership row renders at every accessibility size, subscribed and free")
    func membershipRowRenders() throws {
        let subscribed = SubscriptionModel(
            previewing: .loading, household: .sample(tier: "subscribed")
        )
        let free = SubscriptionModel(previewing: .loading, household: .sample(tier: "free"))

        for (label, size) in Self.sizes {
            try render(
                SubscriptionSection(model: subscribed).padding(Layout.screenMargin),
                named: "membership-subscribed-\(label)",
                at: size
            )
            try render(
                SubscriptionSection(model: free).padding(Layout.screenMargin),
                named: "membership-free-\(label)",
                at: size
            )
        }
    }

    /// One render, at one size, written as a PNG.
    ///
    /// The width is an iPhone's; the height is whatever the content needs, so nothing is cropped
    /// and a truncation shows up as truncation rather than as a short image.
    private func render(
        _ view: some View,
        named name: String,
        at size: DynamicTypeSize
    ) throws {
        let renderer = ImageRenderer(
            content:
                view
                .environment(\.dynamicTypeSize, size)
                .frame(width: 393)
                .background(Color.canvas)
        )
        renderer.scale = 2
        renderer.proposedSize = ProposedViewSize(width: 393, height: nil)

        guard let image = renderer.uiImage, let data = image.pngData() else {
            Issue.record("\(name) produced no image")
            return
        }
        // **Height alone is not evidence.** A `ScrollView` renders its ground and none of its
        // content, which produced a full-height sheet of blank cream that passed a height check.
        // So the assertion is that something was actually drawn on it.
        #expect(image.size.height > 100, "\(name) rendered \(image.size.height)pt tall")
        #expect(inkFraction(of: image) > 0.01, "\(name) rendered blank")

        let directory = Self.outputDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(name).png")
        try data.write(to: url)
        print("RASCAL_SCREENSHOT \(url.path) \(Int(image.size.width))x\(Int(image.size.height))")
    }
}

/// Roughly what fraction of the image is not the cream canvas.
///
/// Cheap and deliberately crude — it is answering "did anything draw", not "does it look right".
@MainActor
private func inkFraction(of image: UIImage) -> Double {
    guard let cg = image.cgImage else { return 0 }
    let width = 60
    let height = 60
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    guard
        let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    else { return 0 }
    context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))

    // The canvas is #FDFAF4. Anything meaningfully darker is content.
    var inked = 0
    for index in stride(from: 0, to: pixels.count, by: 4) {
        let r = Int(pixels[index]), g = Int(pixels[index + 1]), b = Int(pixels[index + 2])
        if r < 230 || g < 225 || b < 215 { inked += 1 }
    }
    return Double(inked) / Double(width * height)
}

extension FamilySummary {
    /// A household for a render. Not a fixture with opinions — the row only reads `tier`.
    static func sample(tier: String) -> FamilySummary {
        FamilySummary(
            familyId: UUID(),
            tier: tier,
            guardians: [
                GuardianSummary(
                    userId: UUID(), displayName: "Travis", role: "parent",
                    grantedAt: .now, isYou: true
                )
            ],
            pendingInvites: []
        )
    }
}
