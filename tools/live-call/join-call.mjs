#!/usr/bin/env node
// tools/live-call/join-call.mjs
//
// Demo / exercise harness for the live-call transport. Runs an in-process multi-party call (CallRoom + the
// signaling handler) and prints the roster + who-hears-whom at each step — no network/infra, so you can SEE
// the floor routing the deployed SFU will apply. Usage: node join-call.mjs demo [--floor open|round-robin|moderated]

import { createCallRoom } from './call-room.mjs';
import { handleSignal } from './signaling.mjs';

export function main(argv) {
  if (argv[0] !== 'demo') {
    console.error('Usage: join-call demo [--floor open|round-robin|moderated]');
    return 2;
  }
  const fi = argv.indexOf('--floor');
  const floor = fi >= 0 ? argv[fi + 1] : 'open';
  const SID = 'demo-session';
  const room = createCallRoom({ roomId: 'demo-room', sessionId: SID, floor, isMember: () => true });

  const show = (label) => {
    const subs = room.subscriptions();
    const st = room.state();
    console.log(`\n[${label}] floor=${st.floor} holder=${st.holder || '-'} size=${st.size}`);
    for (const p of room.roster()) console.log(`  ${p.id} hears: ${(subs[p.id] || []).join(', ') || '(no one)'}`);
  };

  console.log(`=== live-call demo (floor=${floor}) ===`);
  for (const id of ['alice', 'bob', 'carol']) {
    handleSignal(room, { type: 'join', participantId: id, sessionId: SID, trackId: `t-${id}` });
  }
  show('3 joined');
  if (floor !== 'open') {
    handleSignal(room, { type: 'advance-floor' });
    show('advance-floor');
  }
  if (floor === 'moderated') {
    handleSignal(room, { type: 'grant-floor', participantId: 'carol' });
    show('grant floor to carol');
  }
  handleSignal(room, { type: 'leave', participantId: 'bob' });
  show('bob left');
  return 0;
}

const invokedDirectly = process.argv[1] && process.argv[1].endsWith('join-call.mjs');
if (invokedDirectly) process.exit(main(process.argv.slice(2)));
