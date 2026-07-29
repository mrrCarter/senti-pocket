import type { RuntimeEnv } from "./env";
import { UnavailableVoiceControlExecutor } from "./control-executor";
import { parseVoiceControlQueueEnvelope } from "./validation";

const MAX_RETRY_DELAY_SECONDS = 60;
const VOICE_CONTROL_QUEUE = "senti-pocket-voice-control-v1";
const VOICE_CONTROL_DLQ = "senti-pocket-voice-control-v1-dlq";

export async function handleVoiceControlQueue(
  batch: MessageBatch<unknown>,
  env: RuntimeEnv,
): Promise<void> {
  if (batch.queue === VOICE_CONTROL_DLQ) {
    await handleVoiceControlDeadLetters(batch, env);
    return;
  }
  if (batch.queue !== VOICE_CONTROL_QUEUE) {
    for (const message of batch.messages) {
      logQueueDecision("voice_control_unknown_queue_acknowledged", message);
      message.ack();
    }
    return;
  }

  for (const message of batch.messages) {
    let envelope;
    try {
      envelope = parseVoiceControlQueueEnvelope(message.body);
    } catch {
      logQueueDecision("voice_control_queue_poison_acknowledged", message);
      message.ack();
      continue;
    }

    try {
      const governor = env.ROOMS.getByName(envelope.roomId);
      const reservation = await governor.reserveModerationExecution(
        envelope,
        new Date().toISOString(),
      );
      if (
        reservation.disposition === "invalid" ||
        reservation.disposition === "terminal"
      ) {
        logQueueDecision(
          reservation.disposition === "invalid"
            ? "voice_control_queue_unknown_command_acknowledged"
            : "voice_control_queue_duplicate_acknowledged",
          message,
        );
        message.ack();
        continue;
      }
      if (
        reservation.disposition === "busy" ||
        reservation.disposition === "not_authorized" ||
        reservation.disposition === "target_not_found"
      ) {
        retryMessage(message, reservation.disposition);
        continue;
      }

      const execution = await new UnavailableVoiceControlExecutor().execute({
        room: reservation.room,
        commandId: reservation.command.commandId,
        controlRevision: reservation.command.controlRevision,
        action: reservation.command.action,
        targetProviderParticipantId:
          reservation.targetProviderParticipantId,
      });
      if (
        execution.disposition !== "unsupported" ||
        execution.providerMutationApplied !== false
      ) {
        throw new Error("Voice-control executor violated the safe-atom contract.");
      }
      const finalized = await governor.finalizeModerationUnsupported(
        reservation.command.commandId,
        reservation.fence,
        new Date().toISOString(),
      );
      if (!finalized) {
        retryMessage(message, "finalize_conflict");
        continue;
      }
      message.ack();
    } catch {
      retryMessage(message, "worker_failure");
    }
  }
}

async function handleVoiceControlDeadLetters(
  batch: MessageBatch<unknown>,
  env: RuntimeEnv,
): Promise<void> {
  for (const message of batch.messages) {
    let envelope;
    try {
      envelope = parseVoiceControlQueueEnvelope(message.body);
    } catch {
      logQueueDecision("voice_control_dlq_poison_acknowledged", message);
      message.ack();
      continue;
    }

    try {
      const terminal = await env.ROOMS.getByName(
        envelope.roomId,
      ).finalizeModerationUndelivered(
        envelope,
        new Date().toISOString(),
      );
      if (!terminal || terminal.status === "pending") {
        retryMessage(message, "dlq_finalize_deferred");
        continue;
      }
      logQueueDecision("voice_control_dlq_terminal_acknowledged", message);
      message.ack();
    } catch {
      retryMessage(message, "dlq_worker_failure");
    }
  }
}

function retryMessage(message: Message<unknown>, reason: string): void {
  logQueueDecision("voice_control_queue_retry", message, reason);
  message.retry({
    delaySeconds: Math.min(
      MAX_RETRY_DELAY_SECONDS,
      2 ** Math.min(message.attempts, 5),
    ),
  });
}

function logQueueDecision(
  event: string,
  message: Message<unknown>,
  reason?: string,
): void {
  console.log(
    JSON.stringify({
      event,
      attempts: message.attempts,
      ...(reason ? { reason } : {}),
    }),
  );
}
