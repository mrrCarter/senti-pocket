public enum PocketAccessibilityID {
    public static let inboxScreen = "pocket.inbox.screen"
    public static let inboxEmpty = "pocket.inbox.empty"
    public static let inboxError = "pocket.inbox.error"
    public static let inboxErrorEnd = "pocket.inbox.error.end"

    /// Session-bound and delimiter-safe so rows from different rooms cannot collapse into one accessibility node.
    public static func inboxItem(sessionId: String, checkpointId: String) -> String {
        "pocket.inbox.item.s\(sessionId.utf8.count):\(sessionId)c\(checkpointId.utf8.count):\(checkpointId)"
    }

    public static let incomingScreen = "pocket.incoming.screen"
    public static let answer = "pocket.incoming.answer"
    public static let listenLater = "pocket.incoming.listenLater"
    public static let snooze = "pocket.incoming.snooze"

    public static let conversationScreen = "pocket.conversation.screen"
    public static let conversationIntegrityBlocked = "pocket.conversation.integrityBlocked"
    public static let conversationIntegrityBlockedEnd = "pocket.conversation.integrityBlocked.end"
    public static let conversationTranscript = "pocket.conversation.transcript"
    public static let interrupt = "pocket.conversation.interrupt"
    public static let pushToTalk = "pocket.conversation.pushToTalk"
    public static let stop = "pocket.conversation.stop"
    public static let replay = "pocket.conversation.replay"
    public static let end = "pocket.conversation.end"

    public static let offlineBanner = "pocket.offline.banner"
    public static let reconnectingBanner = "pocket.reconnecting.banner"

    public static let proposalScreen = "pocket.proposal.screen"
    public static let proposalKind = "pocket.proposal.kind"
    public static let proposalTargetSession = "pocket.proposal.targetSession"
    public static let proposalTargetSequence = "pocket.proposal.targetSequence"
    public static let proposalMessage = "pocket.proposal.message"
    public static let proposalReadBack = "pocket.proposal.readBack"
    public static let proposalConfirm = "pocket.proposal.confirm"
    public static let proposalCancel = "pocket.proposal.cancel"
    public static let proposalValidationError = "pocket.proposal.validationError"

    public static let receiptStatus = "pocket.receipt.status"
    public static let receiptScreen = "pocket.receipt.screen"
    public static let receiptDone = "pocket.receipt.done"
    public static let receiptResultKind = "pocket.receipt.result.kind"
    public static let receiptActionId = "pocket.receipt.result.actionId"
    public static let receiptTargetSequence = "pocket.receipt.result.targetSequence"
    public static let receiptTargetCursor = "pocket.receipt.result.targetCursor"
    public static let receiptResultingSequence = "pocket.receipt.resultingSequence"

    public static let evidenceScreen = "pocket.evidence.screen"
    public static let evidenceDone = "pocket.evidence.done"

    public static func evidenceCard(_ id: String) -> String {
        "pocket.evidence.card.\(id)"
    }
}
