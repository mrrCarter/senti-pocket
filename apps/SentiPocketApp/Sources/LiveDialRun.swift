// LiveDialRun — the production `DialRun` (spec B): the coordinator's per-call episode handle. Composes the stoppable
// LiveDialVoice, the governed PhoneWriteViewModel (+ its DialWriter adapter), and the DialOrchestrator into ONE
// generation-scoped, stoppable governed-dial run.
//
//   • run()      drives the orchestrator under an OWNED Task, so a teardown can cancel it.
//   • cancel()   cancels that Task — a hangup makes the orchestrator decline at its next checkpoint; PRE-submit this
//                posts/queues nothing. It does NOT cancel an already-authorized governed write (that Task is detached).
//   • teardown() stops synth + mic immediately AND cancels ONLY a PRE-SUBMIT writer draft. An authorized in-flight
//                write is RETAINED — an accepted server write cannot be retracted; its detached write Task + the durable
//                outbox own reconciliation (never erased by a hangup).
//
// This is the SINGLE teardown owner's run handle: the coordinator's endEpisode calls cancel()+teardown(); the
// orchestrator only reacts to cooperative Task cancellation. No two owners race a stop.

import Foundation
import PocketCall
import PocketContracts
import PocketDialVoice

@MainActor
final class LiveDialRun: DialRun {
    private let voice: LiveDialVoice
    private let writeModel: PhoneWriteViewModel
    private let orchestrator: DialOrchestrator
    private let request: DialRequest
    private var task: Task<DialOutcome, Never>?
    private var torn = false

    init(voice: LiveDialVoice,
         writeModel: PhoneWriteViewModel,
         request: DialRequest,
         maxConfirmRetries: Int = 2,
         maxConversingTurns: Int = 6) {
        self.voice = voice
        self.writeModel = writeModel
        self.request = request
        self.orchestrator = DialOrchestrator(voice: voice,
                                             writer: PhoneWriteAdapter(writeModel),
                                             maxConfirmRetries: maxConfirmRetries,
                                             maxConversingTurns: maxConversingTurns)
    }

    func run() async -> DialOutcome {
        if torn { return .declined("torn down before run") }   // cancel() landed before run() started
        let t = Task { [orchestrator, request] in await orchestrator.run(request) }
        task = t
        return await t.value
    }

    func cancel() {
        torn = true
        task?.cancel()   // orchestrator bails at its next Task.isCancelled → decline; nothing posted/queued pre-submit
    }

    func teardown() async {
        await voice.stop()                 // stop synth + mic immediately (any in-flight speak/listen bails)
        writeModel.cancelIfUnsubmitted()   // cancel ONLY a pre-submit draft; RETAIN an authorized in-flight write
    }
}
