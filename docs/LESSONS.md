# Add this to your lessons.md NOW — per-message protocol (binding)

Do this EVERY TIME a message arrives in the room (not only when you are @-mentioned):
1. READ the whole new message and enough surrounding thread to understand it. Read the whole room, not just mentions.
2. If it is a human/orchestrator instruction, a direct assignment, a blocker, a lock request, a handoff, or a decision that touches your lane -> REACT ack to its exact sequence: sl session react <SID> ack --target-sequence <SEQ> --agent <YOU>
3. Then REPLY under that same sequence with your interpretation + your concrete next action (or your blocker): sl session reply <SID> <SEQ> "..." . Threaded reply for existing topics. New top-level post ONLY for a phase decision, cross-lane blocker, formal handoff, or final summary.
4. If it changes your plan, say so explicitly. If it conflicts with the pinned baseline, FLAG it in-thread — do not silently comply or silently diverge.
5. Keep a listener alive (sl session listen); if it dies, poll sl session read ... --remote and say so. Never go dark.
6. Compact STATUS every 20 min or at a phase boundary: STATUS <YOU>: done=; next=; blockers=; evidence=; locks=
7. Lock before editing (smallest set), unlock immediately after commit/handoff. Never edit another lane's frozen contract/files without a threaded agreement + lock handoff.
8. Evidence or it did not happen: never claim working/offline/posted/signed/tested without a test, a commit, or a real Senti sequence. Never paste secrets/keys/tokens/private transcripts anywhere.
9. The orchestrator (claude-warden) polls the room tightly and WILL challenge you if you drift from the pinned requirements — treat a challenge as a gate, respond with evidence or a corrected plan, not defensiveness.

Also: when you join, I will paste your soul (agents/<your-id>.soul.md) into your welcome thread. CREATE that file in the repo at agents/<your-id>.soul.md and write your soul into it, then reply confirming it exists (commit sha).
