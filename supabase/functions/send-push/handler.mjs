const json = (status, value) => new Response(JSON.stringify(value), {
  status, headers: { 'content-type': 'application/json', 'cache-control': 'no-store' },
});
const base64url = bytes => btoa(String.fromCharCode(...bytes)).replace(/=/g, '').replace(/\+/g, '-').replace(/\//g, '_');
const encode = value => base64url(new TextEncoder().encode(JSON.stringify(value)));
export function equalSecret(a, b) {
  if (typeof a !== 'string' || typeof b !== 'string') return false;
  let difference = a.length ^ b.length;
  for (let i = 0; i < Math.max(a.length, b.length); i++) difference |= (a.charCodeAt(i) || 0) ^ (b.charCodeAt(i) || 0);
  return difference === 0;
}
export async function signAPNs(config, now = Date.now) {
  const pem = config.APNS_KEY.replace(/\\n/g, '\n').replace(/-----[^-]+-----/g, '').replace(/\s/g, '');
  const key = await crypto.subtle.importKey('pkcs8', Uint8Array.from(atob(pem), c => c.charCodeAt(0)),
    { name: 'ECDSA', namedCurve: 'P-256' }, false, ['sign']);
  const unsigned = encode({ alg: 'ES256', kid: config.APNS_KEY_ID }) + '.' +
    encode({ iss: config.APPLE_TEAM_ID, iat: Math.floor(now() / 1000) });
  const signature = await crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, key, new TextEncoder().encode(unsigned));
  return unsigned + '.' + base64url(new Uint8Array(signature));
}
export function createPushHandler({ env, fetcher = fetch, signer = signAPNs, now = Date.now }) {
  let cachedJWT, jwtAt = 0;
  return async request => {
    if (request.method !== 'POST') return json(405, { error: 'POST required' });
    const secret = env('PUSH_DISPATCH_SECRET');
    if (!secret || secret.length < 32) return json(503, { error: 'Push service not configured' });
    if (!equalSecret(request.headers.get('x-piti-push-secret'), secret)) return json(401, { error: 'Unauthorized' });
    const keys = ['SUPABASE_URL','SUPABASE_SERVICE_ROLE_KEY','APNS_KEY','APNS_KEY_ID','APPLE_TEAM_ID','APNS_BUNDLE_ID'];
    const config = Object.fromEntries(keys.map(key => [key, env(key)]));
    if (keys.some(key => !config[key])) return json(503, { error: 'Push service not configured' });
    let base;
    try { base = new URL(config.SUPABASE_URL); if (base.protocol !== 'https:') throw Error(); }
    catch { return json(503, { error: 'Invalid service configuration' }); }
    const rpc = async (name, body) => {
      const response = await fetcher(new URL('/rest/v1/rpc/' + name, base), {
        method: 'POST', headers: { apikey: config.SUPABASE_SERVICE_ROLE_KEY,
          Authorization: 'Bearer ' + config.SUPABASE_SERVICE_ROLE_KEY, 'content-type': 'application/json' },
        body: JSON.stringify(body), signal: AbortSignal.timeout(10000),
      });
      if (!response.ok) throw Error('Database operation failed');
      const text = await response.text();
      return text ? JSON.parse(text) : null;
    };
    try {
      // Validate signing configuration before taking leases.
      if (!cachedJWT || now() - jwtAt > 45 * 60000) {
        cachedJWT = await signer(config, now); jwtAt = now();
      }
      const deliveries = await rpc('push_claim', {});
      if (!Array.isArray(deliveries)) throw Error('Invalid queue response');
      let accepted = 0, failed = 0;
      await Promise.all(deliveries.map(async delivery => {
        let ok = false, permanent = false, reason = '';
        try {
          if (delivery.topic !== config.APNS_BUNDLE_ID ||
              !['sandbox', 'production'].includes(delivery.environment) ||
              !/^[a-f0-9]{64,512}$/.test(delivery.token)) throw Error('Invalid delivery');
          const host = delivery.environment === 'sandbox' ? 'api.sandbox.push.apple.com' : 'api.push.apple.com';
          const response = await fetcher('https://' + host + '/3/device/' + delivery.token, {
            method: 'POST',
            headers: { authorization: 'bearer ' + cachedJWT, 'apns-topic': delivery.topic,
              'apns-push-type': 'alert', 'apns-priority': '10', 'apns-collapse-id': delivery.id,
              'apns-expiration': String(Math.floor(now()/1000) + 3600) },
            body: JSON.stringify({ aps: { alert: { title: 'PiTi', body: delivery.body }, sound: 'default' },
              page: delivery.page, entity_id: delivery.entity_id, client_id: delivery.client_id, recipient_id: delivery.recipient_id }),
            signal: AbortSignal.timeout(10000),
          });
          ok = response.ok;
          if (!ok) {
            const data = await response.json().catch(() => ({}));
            reason = typeof data.reason === 'string' ? data.reason.slice(0, 80) : 'APNs error';
            permanent = response.status === 410 || ['BadDeviceToken','Unregistered'].includes(reason);
            if (reason === 'ExpiredProviderToken') cachedJWT = null;
          }
        } catch { reason = 'Delivery unavailable'; }
        await rpc('push_finish', { p_id: delivery.id, p_lease: delivery.lease, p_ok: ok, p_permanent: permanent, p_error: reason || null });
        if (ok) accepted++; else failed++;
      }));
      return json(failed ? 503 : 200, { accepted_by_apns: accepted, failed });
    } catch {
      // Do not expose tokens, credentials, raw APNs responses or database errors.
      return json(503, { error: 'Push delivery temporarily unavailable' });
    }
  };
}
