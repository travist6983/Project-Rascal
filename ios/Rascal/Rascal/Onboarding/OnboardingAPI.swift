import Foundation

/// The one endpoint onboarding adds to the client.
extension APIClient {
    /// `POST /v1/children` — create the child and make the caller its parent.
    ///
    /// Returns `ChildWithRole`, the same shape `GET /v1/children` lists, which is why this
    /// decodes into `ChildResponse` rather than the narrower `ChildUpdateResponse` that
    /// `PATCH /children/{id}` answers with.
    ///
    /// **There is no `Idempotency-Key` on this route** — unlike `POST /entries`, which has one.
    /// A create whose response is lost in transit has still created a child, so the client
    /// cannot make a blind retry safe. `OnboardingSession.createChild` closes that by asking
    /// `GET /children` before it retries; see the comment there, which is where the actual
    /// protection lives.
    func createChild(
        name: String,
        birthdate: String,
        familyTimezone: String
    ) async throws -> ChildResponse {
        try await send(
            .post, "v1/children",
            body: ChildCreateRequest(
                name: name,
                birthdate: birthdate,
                familyTimezone: familyTimezone
            )
        )
    }
}

private nonisolated struct ChildCreateRequest: Encodable {
    let name: String
    /// `yyyy-MM-dd`. A **calendar day, not an instant** — a string for the same reason
    /// `ChildUpdateRequest.birthdate` is one: the client's encoder writes ISO 8601 with a time
    /// and a zone, and a birthday has neither. Encoding it as a timestamp is how a birthdate
    /// lands a day early west of Greenwich.
    let birthdate: String
    /// An IANA identifier — `America/Detroit`. Never an abbreviation, never an offset. This is
    /// the scheduler's entire definition of "today", so a wrong value here hands someone
    /// tomorrow's prompt at 9pm.
    let familyTimezone: String
}
