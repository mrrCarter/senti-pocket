import type { VoiceRole } from "./contracts";
import type { RuntimeEnv } from "./env";
import {
  addParticipant,
  createMeeting,
  deactivateMeeting,
  refreshParticipant,
  updateParticipantRoleAndRefresh,
} from "./realtimekit-client";

export interface ProviderRoom {
  id: string;
}

export interface ProviderParticipantCredential {
  id: string;
  token: string;
}

export interface MediaRoomProvider {
  readonly kind: "cloudflare-realtimekit";
  createRoom(title: string): Promise<ProviderRoom>;
  deactivateRoom(roomId: string): Promise<void>;
  addParticipant(
    roomId: string,
    participantKey: string,
    displayName: string,
    role: VoiceRole,
  ): Promise<ProviderParticipantCredential>;
  refreshParticipant(
    roomId: string,
    participantId: string,
  ): Promise<ProviderParticipantCredential>;
  updateParticipantRoleAndRefresh(
    roomId: string,
    participantId: string,
    displayName: string,
    role: VoiceRole,
  ): Promise<ProviderParticipantCredential>;
}

export function realtimeKitMediaRoomProvider(env: RuntimeEnv): MediaRoomProvider {
  return {
    kind: "cloudflare-realtimekit",
    createRoom: (title) => createMeeting(env, title),
    deactivateRoom: (roomId) => deactivateMeeting(env, roomId),
    addParticipant: (roomId, participantKey, displayName, role) =>
      addParticipant(env, roomId, participantKey, displayName, role),
    refreshParticipant: (roomId, participantId) =>
      refreshParticipant(env, roomId, participantId),
    updateParticipantRoleAndRefresh: (
      roomId,
      participantId,
      displayName,
      role,
    ) =>
      updateParticipantRoleAndRefresh(
        env,
        roomId,
        participantId,
        displayName,
        role,
      ),
  };
}
