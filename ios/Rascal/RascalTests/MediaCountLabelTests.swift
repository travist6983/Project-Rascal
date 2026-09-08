import Foundation
import Testing

@testable import Rascal

/// The composer's attachment heading.
///
/// **The bug this suite exists for is a heading that read "1 photo" above a voice note.** It was
/// visible on the one flow the product is sold on — answer a voice mission, look at what you are
/// about to save — and it survived because the label counted rows without asking what was in
/// them. Every case here is a shape the composer can actually hold: it accepts photos, video and
/// voice notes in one entry, and has since the media model was written.
@Suite("Media count label")
struct MediaCountLabelTests {

    @Test("One of each kind is named, not counted as a photo")
    func singleOfEachKind() {
        #expect(MediaCountLabel.label(kinds: ["photo"]) == "1 photo")
        #expect(MediaCountLabel.label(kinds: ["video"]) == "1 video")
        #expect(MediaCountLabel.label(kinds: ["audio"]) == "1 voice note")
    }

    @Test("Several of one kind pluralise on their own noun")
    func pluralOfEachKind() {
        #expect(MediaCountLabel.label(kinds: ["photo", "photo", "photo"]) == "3 photos")
        #expect(MediaCountLabel.label(kinds: ["video", "video"]) == "2 videos")
        #expect(MediaCountLabel.label(kinds: ["audio", "audio"]) == "2 voice notes")
    }

    @Test("Two kinds join with 'and', in capture-choice order")
    func twoKinds() {
        #expect(MediaCountLabel.label(kinds: ["photo", "photo", "audio"]) == "2 photos and 1 voice note")
        // Order is the label's, not the caller's: a voice note recorded before the photos was
        // still met second on the sheet.
        #expect(MediaCountLabel.label(kinds: ["audio", "photo"]) == "1 photo and 1 voice note")
        #expect(MediaCountLabel.label(kinds: ["video", "photo"]) == "1 photo and 1 video")
    }

    @Test("Three kinds take a comma and a final 'and'")
    func threeKinds() {
        #expect(
            MediaCountLabel.label(kinds: ["audio", "video", "photo", "photo"])
                == "2 photos, 1 video and 1 voice note"
        )
    }

    /// A kind this build does not know must not be counted as a photograph. The server's
    /// `ck_media_kind` allows three values today; a fourth one arriving later degrades to a
    /// vague heading rather than a wrong one.
    @Test("An unrecognised kind degrades rather than lying")
    func unknownKind() {
        #expect(MediaCountLabel.label(kinds: ["hologram"]) == "1 attachment")
        #expect(MediaCountLabel.label(kinds: ["hologram", "hologram"]) == "2 attachments")
        #expect(MediaCountLabel.label(kinds: ["photo", "hologram"]) == "1 photo and 1 attachment")
    }

    /// Neither call site renders the row when nothing is attached, so this is a guard rather
    /// than a screen anyone sees — but an empty string would collapse the stack spacing above
    /// the tiles instead of removing the heading, which looks like a layout bug.
    @Test("Nothing attached still produces a heading")
    func empty() {
        #expect(MediaCountLabel.label(kinds: []) == "Attached")
    }
}
