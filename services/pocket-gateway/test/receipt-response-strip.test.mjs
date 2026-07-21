// receipt-response-strip.test.mjs — the internal __emitted reconcile marker (set in actions.mjs for the EMITTED-RETRY
// path) must never cross into the /actions/execute response body. receiptResponse strips it.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { receiptResponse } from '../src/handlers.mjs';

const parse = (res) => (typeof res.body === 'string' ? JSON.parse(res.body) : res.body);

test('strips __emitted from a posted receipt, keeps the real fields', () => {
  const res = receiptResponse({
    status: 'posted', confirmedProposalHash: 'h1', signature: 'sig', signingKeyId: 'k',
    __emitted: { parsed: { messageId: 'm', sequenceId: 9 }, executedAt: '2026-07-21T00:00:00Z' },
  });
  assert.equal(res.status, 200);
  const body = parse(res);
  assert.equal(body.__emitted, undefined, 'internal marker must NOT leak to the client');
  assert.ok(!JSON.stringify(body).includes('__emitted'), 'no __emitted anywhere in the body');
  assert.equal(body.status, 'posted');            // the real receipt survives
  assert.equal(body.confirmedProposalHash, 'h1');
  assert.equal(body.signature, 'sig');
});

test('a post-confirmation-failed receipt (non-null hash) with __emitted -> 200 clean', () => {
  const res = receiptResponse({ status: 'failed', confirmedProposalHash: 'h2', failureReason: 'no seq', __emitted: { parsed: null } });
  assert.equal(res.status, 200); // non-null hash = a valid (failed) receipt, returned
  assert.equal(parse(res).__emitted, undefined);
});

test('a null-hash failed receipt -> 422 typed error (unchanged)', () => {
  const res = receiptResponse({ status: 'failed', confirmedProposalHash: null, failureReason: 'rejected' });
  assert.equal(res.status, 422);
  assert.equal(parse(res).error, 'proposal_rejected');
});

test('a receipt WITHOUT __emitted is returned unchanged', () => {
  const res = receiptResponse({ status: 'posted', confirmedProposalHash: 'h3' });
  assert.equal(res.status, 200);
  assert.equal(parse(res).status, 'posted');
});
