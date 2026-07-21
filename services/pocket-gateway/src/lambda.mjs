// lambda.mjs — AWS Lambda / API Gateway (HTTP API v2) adapter for the gateway (Echo P1: no adapter existed).
// Pure request/response mapping — NO AWS SDK dependency. `export const handler = lambdaHandler(createGateway(deps))`.
// IaC (function + HTTP API + IAM + DynamoDB table + secrets) is deploy-time and lives outside this zero-dep package.

const lowerHeaders = (h) => {
  const o = {};
  for (const k of Object.keys(h || {})) o[k.toLowerCase()] = h[k];
  return o;
};
const stripStage = (p) => p || '/';

function fullUrl(event, headers, path) {
  const proto = headers['x-forwarded-proto'] || 'https';
  const host = event?.requestContext?.domainName || headers.host || 'localhost';
  return `${proto}://${host}${path}`;
}

/** Map the gateway's {status,headers,body,isBase64Encoded} response to an API Gateway HTTP API result. */
function toApiGw(res) {
  if (Buffer.isBuffer(res.body)) {
    return { statusCode: res.status, headers: res.headers || {}, body: res.body.toString('base64'), isBase64Encoded: true };
  }
  const isString = typeof res.body === 'string';
  return {
    statusCode: res.status,
    headers: { 'content-type': 'application/json', ...(res.headers || {}) },
    body: isString ? res.body : JSON.stringify(res.body ?? {}),
    isBase64Encoded: false,
  };
}

/**
 * Build an async Lambda handler(event) from a gateway. Supports API Gateway HTTP API v2 (and v1-ish fallbacks).
 * @param {{ canonicalBaseUrl?: string }} opts  canonicalBaseUrl = the deploy-canonical origin (e.g.
 *   https://pocket-api.sentinelayer.com) the DPoP `htu` must match. STRONGLY recommended in prod so the URL the
 *   proof is bound to is not derived from an attacker-spoofable Host header.
 */
export function lambdaHandler(gateway, opts = {}) {
  const canonicalBaseUrl = opts.canonicalBaseUrl ? opts.canonicalBaseUrl.replace(/\/+$/, '') : null;
  return async function handler(event) {
    const method = event?.requestContext?.http?.method || event?.httpMethod || 'GET';
    const path = stripStage(event?.requestContext?.http?.path || event?.rawPath || event?.path || '/');
    const headers = lowerHeaders(event?.headers || {});
    // SECURITY (Echo P0): x-http-method / x-http-url drive DPoP binding, so they MUST come from the trusted request
    // context, never the caller. Drop any forwarded variants and OVERWRITE with the actual method + the canonical
    // deployed URL (a spoofed value would let a stolen proof for one method/route authorize another).
    delete headers['x-http-method'];
    delete headers['x-http-url'];
    headers['x-http-method'] = method;
    headers['x-http-url'] = canonicalBaseUrl ? canonicalBaseUrl + path : fullUrl(event, headers, path);
    const query = event?.queryStringParameters || {};
    let body = event?.body;
    if (typeof body === 'string' && event?.isBase64Encoded) body = Buffer.from(body, 'base64').toString('utf8');
    const res = await gateway.handle({ method, path, query, headers, body });
    return toApiGw(res);
  };
}
