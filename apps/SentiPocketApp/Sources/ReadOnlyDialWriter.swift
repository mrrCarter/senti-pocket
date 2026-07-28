// DialEpisodeWriter + ReadOnlyDialWriter — the writer half of a governed-dial episode (Pulse review, read-only-by-
// construction). `DialEpisodeWriter` refines PocketCall.DialWriter with the app-seam HANGUP teardown seam
// (`cancelIfUnsubmitted`). LiveDialRun holds one:
//   • real path  = PhoneWriteAdapter (the governed PhoneWriteViewModel/PocketWriteClient write)
//   • DEMO path  = ReadOnlyDialWriter (below) — a NON-WRITING writer, so a foreground demo can NEVER post.

import Foundation
import PocketCall

/// A DialWriter that also exposes the app-seam HANGUP teardown: cancel ONLY a PRE-SUBMIT draft; RETAIN an authorized
/// in-flight write. LiveDialRun's teardown calls this so a hangup stops call audio without erasing an authorized write.
@MainActor
protocol DialEpisodeWriter: DialWriter {
    func cancelIfUnsubmitted() async
}

/// A NON-WRITING DialWriter for the FOREGROUND DEMO (spec A, read-only-by-CONSTRUCTION): draft / cancel /
/// cancelIfUnsubmitted are no-ops and confirmAndPost NEVER posts — it returns `.refused`, so a demo "confirm" produces
/// ZERO write requests and ZERO OutboxStore interaction REGARDLESS of any SessionTokenStore token. The demo composed
/// with this writer reaches the pickup VOICE only; it can never author a governed write.
@MainActor
final class ReadOnlyDialWriter: DialEpisodeWriter {
    private(set) var confirmAttempts = 0
    func draft(_ message: String) async {}
    func cancel() async {}
    func cancelIfUnsubmitted() async {}
    func confirmAndPost() async -> DialWriteResult {
        confirmAttempts += 1
        return .refused("read-only demo — nothing is written")
    }
}
