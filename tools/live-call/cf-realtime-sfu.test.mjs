import test from 'node:test';
import assert from 'node:assert/strict';
import { createCfRealtimeSfu, remoteTracksForListener } from './cf-realtime-sfu.mjs';

function stub({ ok = true, status = 200, json = { sessionId: 's1' }, capture } = {}) {
  return async (url, opts) => {
    if (capture) { capture.url = url; capture.opts = opts; capture.body = opts.body ? JSON.parse(opts.body) : undefined; }
    return { ok, status, json: async () => json };
  };
}

test('newSession: correct endpoint, Bearer auth, body passthrough', async () => {
  const cap = {};
  const sfu = createCfRealtimeSfu({ appId: 'app1', appSecret: 'sek', fetchImpl: stub({ json: { sessionId: 's1' }, capture: cap }) });
  const r = await sfu.newSession({ sessionDescription: { type: 'offer', sdp: 'x' } });
  assert.equal(r.sessionId, 's1');
  assert.equal(cap.url, 'https://rtc.live.cloudflare.com/v1/apps/app1/sessions/new');
  assert.equal(cap.opts.method, 'POST');
  assert.equal(cap.opts.headers.authorization, 'Bearer sek');
  assert.deepEqual(cap.body.sessionDescription, { type: 'offer', sdp: 'x' });
});

test('addRemoteTracks: subscribe endpoint + body passthrough', async () => {
  const cap = {};
  const sfu = createCfRealtimeSfu({ appId: 'app1', appSecret: 'sek', fetchImpl: stub({ capture: cap }) });
  await sfu.addRemoteTracks('sessA', { tracks: [{ location: 'remote', sessionId: 'pub', trackName: 'mic' }] });
  assert.equal(cap.url, 'https://rtc.live.cloudflare.com/v1/apps/app1/sessions/sessA/tracks/new');
  assert.equal(cap.body.tracks[0].location, 'remote');
});

test('getSession uses GET + no body', async () => {
  const cap = {};
  const sfu = createCfRealtimeSfu({ appId: 'app1', appSecret: 'sek', fetchImpl: stub({ json: { tracks: [] }, capture: cap }) });
  await sfu.getSession('sX');
  assert.equal(cap.opts.method, 'GET');
  assert.equal(cap.opts.body, undefined);
});

test('fail-closed: missing app secret -> throws (secret stays server-side)', async () => {
  const sfu = createCfRealtimeSfu({ appId: 'app1', appSecret: '', fetchImpl: stub() });
  await assert.rejects(() => sfu.newSession({}), /missing-cf-app-secret/);
});

test('HTTP error -> throws cf-realtime-<status>', async () => {
  const sfu = createCfRealtimeSfu({ appId: 'app1', appSecret: 'sek', fetchImpl: stub({ ok: false, status: 503 }) });
  await assert.rejects(() => sfu.getSession('x'), /cf-realtime-503/);
});

test('construction guard: appId required', () => {
  assert.throws(() => createCfRealtimeSfu({ appId: '', appSecret: 'x', fetchImpl: () => {} }));
});

test('remoteTracksForListener maps who-hears-whom -> CF remote-track subscribe body', () => {
  const subs = { a: ['b', 'c'], b: ['a'] };
  const trackOf = (id) => ({ b: { sessionId: 'sB', trackName: 'mic' }, c: { sessionId: 'sC', trackName: 'mic' } }[id] || null);
  assert.deepEqual(remoteTracksForListener(subs, 'a', trackOf).tracks, [
    { location: 'remote', sessionId: 'sB', trackName: 'mic' },
    { location: 'remote', sessionId: 'sC', trackName: 'mic' },
  ]);
  // a publisher with no known track is skipped, not fabricated
  assert.deepEqual(remoteTracksForListener({ a: ['ghost'] }, 'a', () => null).tracks, []);
});
