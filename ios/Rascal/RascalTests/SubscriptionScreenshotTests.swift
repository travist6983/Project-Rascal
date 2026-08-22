import Foundation
import SwiftUI
import Testing
import UIKit

@testable import Rascal

/// Renders the membership surfaces at accessibility text sizes and writes PNGs.
///
/// **Phase 61 shipped without these and its row says so; 37b was the phase not repeating that, and
/// 108 extends the same harness to the three surfaces it added.** The predicted defect in 37b was
/// truncation in the price comparison — which is why `PlanRow` stacks its strings vertically. The
/// predicted defects here are a glyph tile that stops scaling into a dot, and a locked board that
/// becomes taller than the viewport before anyone looks at it.
///
/// `ImageRenderer` rather than a simulator screenshot, and that is what makes it possible at all:
/// these views render from values rather than from StoreKit `Product`s or a live board, so they can
/// be built at any text size with no store, no session and no taps.
///
/// **Two things this harness cannot do, stated so nobody reads a green run as more than it is.**
/// There is no golden-image diff — the PNGs are written and must be *looked at*; a run that changes
/// every pixel passes. And `ImageRenderer` will not rasterize a `ScrollView` or a `List`, which is
/// why every view here is either scroll-free or exposes a scroll-free `content`/`renderable`.
///
/// Output goes to `$RASCAL_SCREENSHOT_DIR`, or a temporary directory whose path is printed.
@MainActor
@Suite("Dynamic Type — the membership surfaces")
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
            .appendingPathComponent("rascal-phase-108", isDirectory: true)
    }

    /// The child the approved design draws, so a render can be compared with the artboards.
    private static let milo = PromptSubject(name: "Milo", pronouns: .heHim)

    @Test("the membership sheet renders at every accessibility size, in both of its states")
    func membershipSheetRenders() throws {
        let ready = SubscriptionModel(previewing: .ready(.preview, familyID: UUID()))
        // **The state every device is actually in.** No subscription product exists in App Store
        // Connect, so this is the ordinary render and not the error one.
        let unavailable = SubscriptionModel(previewing: .unavailable(.products))

        for (label, size) in Self.sizes {
            try render(
                PaywallSheet(model: ready) {}.renderable,
                named: "membership-sheet-\(label)",
                at: size
            )
            try render(
                PaywallSheet(model: unavailable) {}.renderable,
                named: "membership-unavailable-\(label)",
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

    /// **The card, alone.** `TodayBoardView` is a `List` and `ImageRenderer` renders a list's ground
    /// and stops, so a board screenshot would be a cream rectangle that passes every check.
    ///
    /// The two things to look at: the 34pt glyph tile must still be a tile rather than a dot, and
    /// the footer must not wrap past two lines.
    @Test("the locked card renders at every accessibility size, for every slot")
    func lockedCardRenders() throws {
        let slots = [
            ("photo", LockedSlot(slot: "mission", kindHint: "photo")),
            ("second", LockedSlot(slot: "mission_b", kindHint: "mission")),
            ("letter", LockedSlot(slot: "letter", kindHint: "letter")),
            ("unknown", LockedSlot(slot: "seasonal", kindHint: "seasonal")),
        ]

        for (name, slot) in slots {
            try render(
                LockedPromptCard(locked: slot) {}
                    .promptSubject(Self.milo)
                    .padding(Layout.screenMargin),
                named: "locked-\(name)-default",
                at: .large
            )
        }

        for (label, size) in Self.sizes {
            try render(
                LockedPromptCard(locked: slots[0].1) {}
                    .promptSubject(Self.milo)
                    .padding(Layout.screenMargin),
                named: "locked-photo-\(label)",
                at: size
            )
        }
    }

    /// **The four-lock Saturday**, which no artboard draws and which is the state most likely to
    /// look bad and least likely to be looked at: a Saturday that is also the 15th serves both daily
    /// missions, the weekly and the letter against a single live question.
    ///
    /// The design's own note warns one card is ~270pt at AX1. This is that, four times — rendered
    /// so the height is a number somebody can read rather than a thing to be surprised by.
    @Test("four locked cards, the worst case the scheduler can produce")
    func fourLockedCardsRender() throws {
        let saturday = [
            LockedSlot(slot: "mission", kindHint: "photo"),
            LockedSlot(slot: "mission_b", kindHint: "mission"),
            LockedSlot(slot: "weekly", kindHint: "weekly"),
            LockedSlot(slot: "letter", kindHint: "letter"),
        ]

        let stack = VStack(spacing: Layout.cardSpacing) {
            ForEach(saturday) { locked in
                LockedPromptCard(locked: locked) {}
            }
        }
        .promptSubject(Self.milo)
        .padding(Layout.screenMargin)

        try render(stack, named: "locked-saturday-default", at: .large)
        try render(stack, named: "locked-saturday-xxLarge", at: .xxLarge)
        try render(stack, named: "locked-saturday-accessibility1", at: .accessibility1)
    }

    /// **The pronoun rule, rendered rather than argued about.** The `he/him` column must read
    /// exactly as the owner's copy file does; the other two must read correctly rather than wrongly.
    @Test("the locked card renders each pronoun set correctly")
    func lockedCardPronounsRender() throws {
        let sets: [(String, PronounSet?)] = [
            ("heHim", .heHim), ("sheHer", .sheHer), ("theyThem", .theyThem), ("unanswered", nil),
        ]

        for (name, set) in sets {
            let pair = VStack(spacing: Layout.cardSpacing) {
                LockedPromptCard(locked: LockedSlot(slot: "mission", kindHint: "photo")) {}
                LockedPromptCard(locked: LockedSlot(slot: "letter", kindHint: "letter")) {}
            }
            .promptSubject(PromptSubject(name: "Sam", pronouns: set))
            .padding(Layout.screenMargin)

            try render(pair, named: "locked-pronouns-\(name)", at: .large)
        }
    }

    @Test("the trial welcome renders at every accessibility size")
    func trialWelcomeRenders() throws {
        try render(TrialWelcomeScreen {}.content, named: "trial-welcome-default", at: .large)
        for (label, size) in Self.sizes {
            try render(TrialWelcomeScreen {}.content, named: "trial-welcome-\(label)", at: size)
        }
    }

    /// The notice in both shapes — one action and two — because the two-action layout is the one the
    /// design stacks, and stacking is the thing that has to hold at accessibility sizes.
    @Test("the notice renders in both of its shapes")
    func noticeRenders() throws {
        let postTrial = Notice(
            text: MembershipCopy.postTrialNotice,
            primaryLabel: MembershipCopy.postTrialOpen,
            onPrimary: {},
            onDismiss: {},
            dismissLabel: MembershipCopy.postTrialDismiss
        )
        .padding(Layout.screenMargin)

        let statement = Notice(text: MembershipCopy.productsUnavailable)
            .padding(Layout.screenMargin)

        try render(postTrial, named: "notice-post-trial-default", at: .large, minimumHeight: 60)
        try render(statement, named: "notice-unavailable-default", at: .large, minimumHeight: 60)
        for (label, size) in Self.sizes {
            try render(postTrial, named: "notice-post-trial-\(label)", at: size, minimumHeight: 60)
        }
    }

    /// One render, at one size, written as a PNG.
    ///
    /// The width is an iPhone's; the height is whatever the content needs, so nothing is cropped and
    /// a truncation shows up as truncation rather than as a short image.
    private func render(
        _ view: some View,
        named name: String,
        at size: DynamicTypeSize,
        // **A floor, not a constant.** 100 is right for a screen and wrong for a component: a
        // `Notice` at default type is legitimately about 92pt tall, and asserting a screen's height
        // against a row is how a correct render reads as a failure. The check that actually matters
        // is `inkFraction` — "did anything draw" — and that is unchanged for every caller.
        minimumHeight: CGFloat = 100
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
        // content, which produced a full-height sheet of blank cream that passed a height check. So
        // the assertion is that something was actually drawn on it.
        #expect(image.size.height > minimumHeight, "\(name) rendered \(image.size.height)pt tall")
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
