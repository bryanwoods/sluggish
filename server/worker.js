export default {
  async fetch(request, env) {
    const txn = new URL(request.url).searchParams.get("txn") ?? "";
    if (!/^txn_[a-z\d]{26}$/.test(txn)) return page("This link is not complete. Open it again from the page that you saw after you paid.", 400);
    const res = await fetch(`${env.PADDLE_API}/transactions/${txn}`, { headers: { Authorization: `Bearer ${env.PADDLE_API_KEY}` } });
    if (!res.ok && res.status !== 404) {
      console.error("Paddle answered", res.status, await res.text());
      return page("Something went wrong on our side. Reload this page in a minute.", 502);
    }
    const t = res.ok ? (await res.json()).data : null;
    if (!t?.items?.some((i) => i.price?.id === env.PRICE_ID)) return page("We cannot find a Sluggish purchase for this link. If you paid, go to paddle.net to find your order and get help.", 404);
    if (!["paid", "completed"].includes(t.status)) return page("Your payment is not complete yet. This page tries again in 5 seconds.", 202, true);
    const payload = new TextEncoder().encode(JSON.stringify({ t: t.id, d: t.created_at.slice(0, 10) }));
    const key = await crypto.subtle.importKey("pkcs8", Uint8Array.from(atob(env.LICENSE_PRIVATE_KEY), (c) => c.charCodeAt(0)), { name: "Ed25519" }, false, ["sign"]);
    const signature = await crypto.subtle.sign({ name: "Ed25519" }, key, payload);
    return page(
      `<h1>Your Sluggish license key</h1><p><code style="word-break:break-all;user-select:all">SLUG1-${b64url(payload)}.${b64url(signature)}</code></p>` +
        "<p>Copy this key, then click ⋯ in Sluggish, choose Enter license key…, and paste it.</p><p>Keep the key. It works on all your Macs.</p>",
    );
  },
};

const b64url = (bytes) => btoa(String.fromCharCode(...new Uint8Array(bytes))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");

const page = (body, status = 200, retry = false) =>
  new Response(
    `<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width">${retry ? '<meta http-equiv="refresh" content="5">' : ""}` +
      `<title>Sluggish</title><body style="font:17px/1.5 -apple-system,system-ui,sans-serif;max-width:34em;margin:3em auto;padding:0 1em">${body}`,
    { status, headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" } },
  );
