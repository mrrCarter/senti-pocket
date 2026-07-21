// http-timeout.mjs — a timeout AbortSignal that works on ANY runtime (Warden hardening note 2).
//
// AbortSignal.timeout(ms) is Node 18.17+/20+. On our runtimes (live-demo Node 20, prod Node 22) it's present, so the
// primary path uses it. The fallback (AbortController + an unref'd setTimeout) bounds the /auth/me + /human-message
// fetches on ANY runtime — without it, a missing AbortSignal.timeout left `signal` undefined => an UNBOUNDED fetch that
// a try/catch cannot rescue from a hang. Drop-in: returns a bare AbortSignal (or undefined only if the runtime has
// neither primitive, documented), the same shape the callers already spread as `{ signal }`.
export function timeoutSignal(ms) {
  if (typeof AbortSignal !== 'undefined' && typeof AbortSignal.timeout === 'function') {
    return AbortSignal.timeout(ms);                               // native, self-cleaning
  }
  if (typeof AbortController === 'function') {
    const controller = new AbortController();
    const t = setTimeout(() => controller.abort(new Error(`timeout after ${ms}ms`)), ms);
    if (t && typeof t.unref === 'function') t.unref();           // never keep the event loop alive for a pending timeout
    return controller.signal;
  }
  return undefined;                                              // no abort primitive at all — caller runs unbounded (documented)
}
