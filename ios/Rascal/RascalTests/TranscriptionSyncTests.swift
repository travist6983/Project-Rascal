import Foundation
import SwiftData
import Testing

@testable import Rascal

/// How a transcript survives sync.
///
/// **Against the real `SyncEngine` and the real `EntryCache`, never a stub of either.** The rule
/// under test is a conflict rule inside those two files, and a stub that implemented the rule
/// correctly would prove only that the stub was correct. Every pull here goes through
/// `SyncEngine.pull()` with a real response body.
///
/// The failure mode these guard against is the worst one this feature has: a transcript exists in
/// exactly one place until it is pushed, so a pull that overwrites it destroys the only copy of
/// words that cost a battery to produce — silently, with no error and nothing on screen to
/// suggest anything happened.
@MainActor
@Suite("Transcription and sync")
struct TranscriptionSyncTests {

    private func engine(
        childId: UUID,
        performer: StubPerformer,
        context: ModelContext,
        pullEnabled: Bool = true
    ) -> SyncEngine {
        SyncEngine(
            childId: childId,
            api: testClient(performer),
            context: context,
            state: InMemorySyncStateStore(pullEnabled: pullEnabled)
        )
    }

    /// A cached audio row the server already knows about, carrying words this phone wrote.
    private func localTranscribedMedia(
        entryId: UUID,
        in context: ModelContext,
        transcript: String,
        state: TranscriptSync
    ) -> Media {
        let media = completeMedia(entryId: entryId, kind: "audio", duration: 42)
        media.transcript = transcript
        media.transcriptSync = state
        media.updatedAt = Date(timeIntervalSince1970: 1_700_000_000)
        context.insert(media)
        try? context.save()
        return media
    }

    private func cachedAudioEntry(childId: UUID, in context: ModelContext) throws -> Entry {
        let entry = try cachedEntry(childId: childId, type: "audio", body: nil)
        context.insert(entry)
        try context.save()
        return entry
    }

    // MARK: 14 — The pull must not clobber

    @Test("a pull carrying an older media row leaves a locally written, unpushed transcript alone")
    func pullDoesNotClobberAnUnpushedTranscript() async throws {
        let context = try inMemoryContext()
        let child = UUID()
        let entry = try cachedAudioEntry(childId: child, in: context)
        let media = localTranscribedMedia(
            entryId: entry.id, in: context,
            transcript: "and then the brachiosaurus ate the whole entire tree",
            state: .pending
        )

        // The server's row is real, complete, and **older** — it carries a transcript from before
        // this phone rewrote it, which is the case a nil-coalescing guard would sail straight
        // through.
        let mediaId = media.id
        let entryId = entry.id
        let performer = StubPerformer()
        let newest = Date(timeIntervalSince1970: 1_700_000_900)
        performer.on("/sync") { _ in
            (syncJSON(
                media: [syncMediaJSON(
                    id: mediaId, entryId: entryId, kind: "audio",
                    transcript: "an older transcript from the server",
                    updatedAt: newest
                )],
                cursor: laggedCursor(newest: newest)
            ), 200)
        }

        let outcome = await engine(childId: child, performer: performer, context: context).pull()

        #expect(media.transcript == "and then the brachiosaurus ate the whole entire tree")
        #expect(media.transcriptSync == .pending)

        // And the engine says so out loud rather than merely doing the right thing quietly: the
        // dry-run report and the Settings summary both read this.
        let plan = try #require(outcome.plan)
        #expect(plan.count(.skippedLocalPending) == 1)
        #expect(plan.count(.update) == 0)
        let conflict = try #require(plan.conflicts.first)
        #expect(conflict.winner == .local)
        #expect(conflict.reason.contains("transcribed here and not yet pushed"))
    }

    @Test("a transcript past its push cap is still protected — it exists nowhere else")
    func aFailedPushStillWinsAgainstThePull() async throws {
        let context = try inMemoryContext()
        let child = UUID()
        let entry = try cachedAudioEntry(childId: child, in: context)
        // `failed` here means "the network gave up", not "the words are wrong". The upload path
        // treats `failed` as no longer pending because the bytes are safe in storage; a
        // transcript has no such second copy, and `Media.hasUnpushedTranscript` says why.
        let media = localTranscribedMedia(
            entryId: entry.id, in: context, transcript: "he said hangaburger", state: .failed
        )

        let mediaId = media.id
        let entryId = entry.id
        let performer = StubPerformer()
        let newest = Date(timeIntervalSince1970: 1_700_000_900)
        performer.on("/sync") { _ in
            (syncJSON(
                media: [syncMediaJSON(
                    id: mediaId, entryId: entryId, kind: "audio",
                    transcript: nil, updatedAt: newest
                )],
                cursor: laggedCursor(newest: newest)
            ), 200)
        }

        await engine(childId: child, performer: performer, context: context).pull()

        #expect(media.transcript == "he said hangaburger")
        #expect(media.transcriptSync == .failed)
    }

    @Test("a media row still uploading is protected exactly as it was before transcripts existed")
    func theUploadRuleIsUnchanged() async throws {
        let context = try inMemoryContext()
        let child = UUID()
        let entry = try cachedAudioEntry(childId: child, in: context)
        let media = completeMedia(entryId: entry.id, kind: "audio")
        media.state = .uploaded
        context.insert(media)
        try context.save()

        let mediaId = media.id
        let entryId = entry.id
        let performer = StubPerformer()
        let newest = Date(timeIntervalSince1970: 1_700_000_900)
        performer.on("/sync") { _ in
            (syncJSON(
                media: [syncMediaJSON(id: mediaId, entryId: entryId, kind: "audio", updatedAt: newest)],
                cursor: laggedCursor(newest: newest)
            ), 200)
        }

        let outcome = await engine(childId: child, performer: performer, context: context).pull()
        let conflict = try #require(outcome.plan?.conflicts.first)
        #expect(conflict.reason.contains("still uploading from here"))
    }

    // MARK: 15 — And afterwards, it reconciles

    @Test("once the push has landed, the next pull reconciles the transcript rather than reverting it")
    func afterPushThePullReconciles() async throws {
        let context = try inMemoryContext()
        let child = UUID()
        let entry = try cachedAudioEntry(childId: child, in: context)
        let media = localTranscribedMedia(
            entryId: entry.id, in: context, transcript: "he said hangaburger", state: .pending
        )
        let mediaId = media.id
        let entryId = entry.id

        // The push lands. This is the real writeback path, not a hand-set flag.
        let performer = StubPerformer()
        performer.on("/derived") { _ in
            (derivedJSON(mediaId: mediaId, entryId: entryId, transcript: "he said hangaburger"), 200)
        }
        let newest = Date(timeIntervalSince1970: 1_700_000_900)
        performer.on("/sync") { _ in
            (syncJSON(
                media: [syncMediaJSON(
                    id: mediaId, entryId: entryId, kind: "audio",
                    transcript: "he said hangaburger", updatedAt: newest
                )],
                cursor: laggedCursor(newest: newest)
            ), 200)
        }

        let queue = TranscriptionQueue(
            api: testClient(performer), context: context,
            transcriber: StubTranscriber(), store: temporaryStagingStore()
        )
        await queue.push()
        #expect(media.transcriptSync == .synced)

        // Now the server owns it, and the row stops claiming to be newer than the server. The
        // pull is free to fold it in — which is reconciliation, not reversion: the words are the
        // same words, they simply have two homes now.
        let outcome = await engine(childId: child, performer: performer, context: context).pull()

        #expect(media.transcript == "he said hangaburger")
        #expect(media.transcriptSync == .synced)
        #expect(outcome.plan?.count(.skippedLocalPending) == 0)
        #expect(media.updatedAt == newest)
    }

    @Test("a synced row does take the server's newer transcript — the protection is not a lock")
    func aSyncedTranscriptIsStillTheServersToChange() async throws {
        let context = try inMemoryContext()
        let child = UUID()
        let entry = try cachedAudioEntry(childId: child, in: context)
        let media = localTranscribedMedia(
            entryId: entry.id, in: context, transcript: "the old words", state: .synced
        )

        let mediaId = media.id
        let entryId = entry.id
        let performer = StubPerformer()
        let newest = Date(timeIntervalSince1970: 1_700_000_900)
        performer.on("/sync") { _ in
            (syncJSON(
                media: [syncMediaJSON(
                    id: mediaId, entryId: entryId, kind: "audio",
                    transcript: "corrected on another device", updatedAt: newest
                )],
                cursor: laggedCursor(newest: newest)
            ), 200)
        }

        await engine(childId: child, performer: performer, context: context).pull()

        // Server-is-truth, restored the moment there is nothing local left to protect. A rule
        // that never let go would be a client that stopped syncing.
        #expect(media.transcript == "corrected on another device")
    }

    // MARK: 16 — Both sides of the flag

    @Test("transcription works with the pull switched off, which is how the app ships")
    func worksWithPullDisabled() async throws {
        let context = try inMemoryContext()
        let child = UUID()
        let store = temporaryStagingStore()
        let entry = try cachedAudioEntry(childId: child, in: context)
        let media = stagedVoiceNote(entryId: entry.id, in: context, store: store)
        let mediaId = media.id
        let entryId = entry.id

        let performer = StubPerformer()
        performer.on("/derived") { _ in
            (derivedJSON(mediaId: mediaId, entryId: entryId, transcript: "words"), 200)
        }
        performer.on("/sync") { _ in (Data("{}".utf8), 500) }

        let queue = TranscriptionQueue(
            api: testClient(performer), context: context,
            transcriber: {
                let stub = StubTranscriber()
                stub.set(text: "words")
                return stub
            }(),
            store: store
        )

        let subject = engine(childId: child, performer: performer, context: context, pullEnabled: false)
        let outcome = await subject.pull()
        await queue.enqueue(mediaId: media.id)
        await queue.sweep()

        if case .disabled = outcome {} else { Issue.record("the pull ran with the flag off") }
        // `/sync` was never called — and the transcript still got produced and delivered.
        #expect(performer.count(for: "/sync") == 0)
        #expect(media.transcript == "words")
        #expect(media.transcriptSync == .synced)
    }

    @Test("with the pull switched on, a transcript written between a pull and a push survives both")
    func worksWithPullEnabled() async throws {
        let context = try inMemoryContext()
        let child = UUID()
        let store = temporaryStagingStore()
        let entry = try cachedAudioEntry(childId: child, in: context)
        let media = stagedVoiceNote(entryId: entry.id, in: context, store: store)

        let mediaId = media.id
        let entryId = entry.id
        let performer = StubPerformer()
        let newest = Date(timeIntervalSince1970: 1_700_000_900)
        // The server has never heard of this transcript, and keeps saying so on every pull.
        performer.on("/sync") { _ in
            (syncJSON(
                media: [syncMediaJSON(
                    id: mediaId, entryId: entryId, kind: "audio",
                    transcript: nil, updatedAt: newest
                )],
                cursor: laggedCursor(newest: newest)
            ), 200)
        }
        performer.on("/derived") { _ in
            (derivedJSON(mediaId: mediaId, entryId: entryId, transcript: "words"), 200)
        }

        let stub = StubTranscriber()
        stub.set(text: "words")
        let queue = TranscriptionQueue(
            api: testClient(performer), context: context, transcriber: stub, store: store
        )
        let subject = engine(childId: child, performer: performer, context: context, pullEnabled: true)

        // The exact interleaving the brief names: pull, then transcribe, then pull again before
        // the push has had a chance to run.
        await subject.pull()
        await queue.enqueue(mediaId: media.id)
        stub.set(failure: TranscriptionFailure.engine("stop here"))
        // Write the transcript by hand at this point so the push has not run — the row is now in
        // the window between a local write and its delivery, which is the risky one.
        media.recordTranscript("words", locale: TranscriptionLocale(locale: .current, isFallback: false))
        try context.save()

        await subject.pull()
        #expect(media.transcript == "words")
        #expect(media.transcriptSync == .pending)

        // And it still reaches the server afterwards.
        stub.set(text: "words")
        await queue.push()
        #expect(media.transcriptSync == .synced)
        #expect(performer.count(for: "/derived") == 1)
    }

    // MARK: The other pull path

    @Test("a timeline refetch does not blank a transcript either — that path runs with the flag off")
    func theEntriesPathIsProtectedToo() async throws {
        let context = try inMemoryContext()
        let child = UUID()
        let entryId = UUID()
        let media = localTranscribedMedia(
            entryId: entryId, in: context, transcript: "he said hangaburger", state: .pending
        )

        // `GET /entries` inlines `MediaSummary`, which carries **no transcript at all**. This is
        // the path that actually runs today, because `syncPullEnabled` ships false — so the
        // protection lives in `applyServerSummary`, where all three pull paths funnel through.
        let response = try decodeEntry(entryJSON(
            id: entryId, childId: child, occurredAt: Date(), type: "audio",
            media: [mediaJSON(id: media.id, kind: "audio", transcript: nil)]
        ))
        EntryCache.upsert([response], into: context)

        #expect(media.transcript == "he said hangaburger")
    }
}
