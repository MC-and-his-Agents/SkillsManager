import Testing

@testable import SkillsManager

@Suite("Library runtime diagnostic presentation")
@MainActor
struct LibraryRuntimeDiagnosticPresentationTests {
    @Test("presents stable actions without leaking diagnostic subjects")
    func stableBlockingMessages() {
        let cases: [(LibraryDiagnosticCode, String)] = [
            (.databaseBusy, "Close other Skills Manager instances"),
            (.permissionDenied, "Check permissions for ~/.SkillsManager"),
            (.schemaMismatch, "managed database is incompatible"),
            (.journalNeedsRepair, "operation needs repair"),
            (.unrecoverable, "Keep its data unchanged"),
        ]

        for (code, expected) in cases {
            let state = LibraryRuntimeState()
            state.apply(LibraryStartupResult(
                phase: .openingDatabase,
                readiness: .blocked,
                diagnostics: [.make(
                    code,
                    subjectKind: .database,
                    subjectID: "/Users/private/manager.sqlite: raw SQLite error"
                )],
                outcome: nil,
                session: nil
            ))

            #expect(state.blockingMessage.localizedCaseInsensitiveContains(expected))
            #expect(!state.blockingMessage.contains("/Users/private"))
            #expect(!state.blockingMessage.contains("SQLite error"))
        }
    }

    @Test("blocked diagnostic changes produce a new propagation observation")
    func blockedDiagnosticChangeUpdatesObservation() {
        let state = LibraryRuntimeState()
        let initialObservation = state.blockingObservation
        let concreteMessage = LibraryRuntimeDiagnostic.make(
            .databaseMissing,
            subjectKind: .database,
            subjectID: "manager.sqlite"
        ).userFacingMessage

        state.apply(LibraryStartupResult(
            phase: .openingDatabase,
            readiness: .blocked,
            diagnostics: [.make(
                .databaseMissing,
                subjectKind: .database,
                subjectID: "manager.sqlite"
            )],
            outcome: nil,
            session: nil
        ))

        #expect(state.readiness == .blocked)
        #expect(state.blockingObservation != initialObservation)
        #expect(state.blockingMessage == concreteMessage)
    }
}
