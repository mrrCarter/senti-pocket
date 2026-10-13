#if DEBUG && canImport(SwiftUI)
import Foundation
import PocketContracts
import SwiftUI

private enum SessionSurfacePreviewFixture {
    static let sessionID = "room-1"
    static let referenceDate = Date(timeIntervalSince1970: 1_784_970_300)

    static let sessionPage = decode(SessionListPage.self, """
    {
      "sessions": [{
        "sessionId": "room-1",
        "status": "active",
        "archiveStatus": "active",
        "visibility": "private",
        "membershipRole": "owner",
        "title": "Senti Pocket build room",
        "summaryText": "Session UI consolidation is ready for review.",
        "summaryGeneratedAt": null,
        "summaryModel": null,
        "agentCount": 5,
        "eventCount": 315,
        "totalCostUsd": 1.25,
        "createdAt": "2026-07-18T10:00:00Z",
        "lastActivityAt": "2026-07-25T09:01:00Z",
        "expiresAt": null,
        "killedAt": null,
        "templateName": null,
        "codebasePath": null,
        "s3ArchivePath": null
      }],
      "count": 1,
      "include_archived": false,
      "next_cursor": null,
      "has_more": false
    }
    """)

    static let eventPage = decode(SessionEventForwardPage.self, """
    {
      "events": [{
        "id": "ev-1",
        "event": "session_message",
        "agent": { "displayName": "Atlas" },
        "agentId": "claude-pocket-atlas",
        "agentModel": "claude",
        "payload": {
          "text": "Salvaged session UI is source-green and waiting on the Mac build."
        },
        "ts": "2026-07-25T09:02:36Z",
        "timestamp": "2026-07-25T09:02:36Z",
        "cursor": "c1",
        "sequenceId": 315181,
        "sessionId": "room-1",
        "source": "cli"
      }]
    }
    """)

    static let actionPage = decode(SessionActionPage.self, """
    {
      "sessionId": "room-1",
      "count": 1,
      "projection": {},
      "actions": [{
        "id": "act-1",
        "sessionId": "room-1",
        "targetSequenceId": 315142,
        "targetCursor": null,
        "targetActionId": null,
        "actionType": "ack",
        "actorKind": "human",
        "actorId": "carter",
        "actorUserId": null,
        "actorRole": "owner",
        "note": "reviewed",
        "metadata": {},
        "idempotencyKey": "idem-1",
        "createdAt": "2026-07-25T09:03:00Z"
      }]
    }
    """)

    static let checkpointPage = decode(SessionCheckpointListPage.self, """
    {
      "checkpoints": [{
        "checkpointId": "cp-1",
        "sessionId": "room-1",
        "kind": "manual_checkpoint",
        "title": "Sunday checkpoint",
        "summary": "Bounded room summary",
        "startSequence": 315000,
        "endSequence": 315181,
        "tokenRange": null,
        "createdBy": "carter",
        "createdByAgentId": "human-mrrcarter",
        "eventSequence": 315182,
        "cursor": "c315182",
        "createdAt": "2026-07-25T09:04:00Z",
        "summarySections": {},
        "grade": "A-",
        "gradeScore": 91,
        "gradeVersion": "v1",
        "gradeReasons": []
      }],
      "count": 1
    }
    """)

    private static func decode<Value: Decodable>(
        _ type: Value.Type,
        _ json: String
    ) -> Value? {
        try? JSONDecoder().decode(type, from: Data(json.utf8))
    }
}

private struct SessionSurfacePreviewShell<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("STATIC PREVIEW · NOT LIVE")
                .font(.caption.bold())
                .foregroundStyle(Color.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(Color.yellow)
                .accessibilityIdentifier("pocket.preview.not-live")

            content
        }
    }
}

@available(iOS 17.0, macOS 14.0, *)
#Preview("Sign in — signed out") {
    SessionSurfacePreviewShell {
        NavigationStack {
            PocketSignInView(phase: .signedOut, send: { _ in })
        }
    }
}

@available(iOS 17.0, macOS 14.0, *)
#Preview("Sign in — signed in, accessibility") {
    SessionSurfacePreviewShell {
        NavigationStack {
            PocketSignInView(phase: .signedIn, send: { _ in })
        }
        .dynamicTypeSize(.accessibility3)
    }
}

@available(iOS 17.0, macOS 14.0, *)
#Preview("Sessions — simulated network") {
    SessionSurfacePreviewShell {
        if let page = SessionSurfacePreviewFixture.sessionPage {
            NavigationStack {
                SessionListView(
                    state: SessionListPresentationState(
                        page: page,
                        provenance: .network(lastUpdated: SessionSurfacePreviewFixture.referenceDate)
                    ),
                    send: { _ in }
                )
            }
        } else {
            Text("Session preview fixture could not be decoded.")
        }
    }
}

@available(iOS 17.0, macOS 14.0, *)
#Preview("Sessions — simulated offline, accessibility") {
    SessionSurfacePreviewShell {
        if let page = SessionSurfacePreviewFixture.sessionPage {
            NavigationStack {
                SessionListView(
                    state: SessionListPresentationState(
                        page: page,
                        provenance: .cache(
                            cachedAt: SessionSurfacePreviewFixture.referenceDate,
                            authenticationExpired: false
                        )
                    ),
                    send: { _ in }
                )
            }
            .dynamicTypeSize(.accessibility3)
        } else {
            Text("Session preview fixture could not be decoded.")
        }
    }
}

@available(iOS 17.0, macOS 14.0, *)
#Preview("Activity — simulated offline copy") {
    SessionSurfacePreviewShell {
        if let events = SessionSurfacePreviewFixture.eventPage,
           let actions = SessionSurfacePreviewFixture.actionPage {
            NavigationStack {
                SessionActivityView(
                    state: SessionActivityPresentationState(
                        sessionId: SessionSurfacePreviewFixture.sessionID,
                        eventPage: events,
                        actionPage: actions,
                        provenance: .cache(
                            cachedAt: SessionSurfacePreviewFixture.referenceDate,
                            authenticationExpired: false
                        )
                    ),
                    send: { _ in }
                )
            }
        } else {
            Text("Activity preview fixture could not be decoded.")
        }
    }
}

@available(iOS 17.0, macOS 14.0, *)
#Preview("Room checkpoints — simulated membership authorization") {
    SessionSurfacePreviewShell {
        if let page = SessionSurfacePreviewFixture.checkpointPage {
            NavigationStack {
                SessionCheckpointListView(
                    state: SessionCheckpointListPresentationState(
                        sessionId: SessionSurfacePreviewFixture.sessionID,
                        page: page,
                        provenance: .network(lastUpdated: SessionSurfacePreviewFixture.referenceDate)
                    ),
                    send: { _ in }
                )
            }
        } else {
            Text("Checkpoint preview fixture could not be decoded.")
        }
    }
}
#endif
