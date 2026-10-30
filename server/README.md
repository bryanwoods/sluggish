# Sluggish license service

This Cloudflare Worker changes a Paddle purchase into a Sluggish license key.
It has one URL: `GET /license?txn=<Paddle transaction ID>`.

The Worker gets the transaction from the Paddle Billing API. It makes sure that
the status is `paid` or `completed`, and that the transaction contains the
Sluggish price (`PRICE_ID`). Then it signs the license with the Ed25519 private
key (`LICENSE_PRIVATE_KEY`) and shows a small HTML page with the key. Paddle
sends the receipt, so the Worker sends no email.

The key has the same format as the keys from `Scripts/license.swift issue`:
`SLUG1-` + base64url(`{"t":"<transaction ID>","d":"YYYY-MM-DD"}`) + `.` +
base64url(signature of the payload). `d` is the UTC date of `created_at` on the
transaction. The same link always gives the same key. If Paddle sends an
error, the page tells the buyer to reload, and `npx wrangler tail` shows the
status and the body from Paddle.

## Deploy steps

CAUTION: KEEP A COPY OF `~/.config/sluggish/license-signing.key` IN YOUR
PASSWORD MANAGER. IF YOU LOSE THE FILE, NEW KEYS DO NOT WORK IN THE APPS THAT
YOU SOLD. Do not put the file in the repo. The repo `.gitignore` ignores `*.key`.

1. In Paddle, make the Sluggish product with a one-time price of $12.
2. Copy the price ID (`pri_…`) into `PRICE_ID` in `wrangler.toml`.
3. In Paddle > Developer tools > Authentication, make an API key. Give it only
   the `transaction.read` permission.
4. In `server/`, deploy the Worker:

   ```sh
   npx wrangler login
   npx wrangler deploy
   ```

5. Add the two secrets. Each command deploys a new version of the Worker.

   ```sh
   npx wrangler secret put PADDLE_API_KEY
   npx wrangler secret put LICENSE_PRIVATE_KEY < ~/.config/sluggish/license-signing.key
   ```

6. Give the Worker a domain. If `sluggishapp.com` is a Cloudflare zone, add this
   line to `wrangler.toml` and deploy again:

   ```toml
   routes = [{ pattern = "license.sluggishapp.com", custom_domain = true }]
   ```

   If not, use the `workers.dev` URL that `wrangler deploy` shows.
7. In Paddle > Checkout > Checkout settings, set the default payment link to
   `https://sluggishapp.com/buy`. Paddle must also approve the domain
   `sluggishapp.com` before live checkouts work.
8. Put the Paddle.js code below on `https://sluggishapp.com/buy`. The app opens
   this page when a person clicks Buy Sluggish.

## The buy page

Paddle documents `successUrl` only as a redirect target. It does not say that
Paddle adds the transaction ID to that URL. The `checkout.completed` event has
`data.transaction_id`, so the page sends the buyer to the Worker from that
event.

```html
<button id="buy">Buy Sluggish for $12</button>
<script src="https://cdn.paddle.com/paddle/v2/paddle.js"></script>
<script>
  Paddle.Initialize({
    token: "live_REPLACE", // Paddle > Developer tools > Authentication > Client-side tokens
    eventCallback(event) {
      if (event.name === "checkout.completed") location.href = "https://license.sluggishapp.com/license?txn=" + event.data.transaction_id;
    },
  });
  document.getElementById("buy").onclick = () => Paddle.Checkout.open({ items: [{ priceId: "pri_REPLACE", quantity: 1 }] });
</script>
```

## Test with the Paddle sandbox

1. In `wrangler.toml`, set `PADDLE_API` to `https://sandbox-api.paddle.com` and
   `PRICE_ID` to the sandbox price. Deploy.
2. Put a sandbox API key in `PADDLE_API_KEY`.
3. On a test copy of the buy page, add `Paddle.Environment.set("sandbox");`
   before `Paddle.Initialize`. Use the sandbox client-side token.
4. Pay with a Paddle test card. Paste the key from the page into Sluggish.

CAUTION: SET `PADDLE_API`, `PRICE_ID` AND `PADDLE_API_KEY` BACK TO LIVE VALUES
BEFORE LAUNCH. WHILE THE WORKER READS THE SANDBOX, A TEST CARD GETS A KEY THAT
WORKS IN THE REAL APP.

## Keys by hand

To give a free license to a reviewer, run this command from the repo root:

```sh
Scripts/license.swift issue review-macstories
```

The ID can contain only letters, digits, `_` and `-`.

If a customer loses the key, find the transaction in Paddle > Transactions.
Send the customer `https://license.sluggishapp.com/license?txn=<transaction ID>`.
The link gives the same key again.

## Sources

- Get a transaction, statuses, `items[].price.id`, `created_at`, and the
  `transaction.read` permission:
  https://developer.paddle.com/api-reference/transactions/get-transaction
- API keys, the `Authorization: Bearer` header, and permissions:
  https://developer.paddle.com/api-reference/about/authentication
- Live (`api.paddle.com`) and sandbox (`sandbox-api.paddle.com`) hosts:
  https://developer.paddle.com/api-reference/about
- `checkout.completed` and `data.transaction_id`:
  https://developer.paddle.com/paddlejs/general/checkout-completed
- `Paddle.Checkout.open`, `items`, and `successUrl`:
  https://developer.paddle.com/paddlejs/methods/paddle-checkout-open
- The success page options:
  https://developer.paddle.com/build/checkout/handle-success-post-checkout
- Ed25519 in Workers WebCrypto (Workers cannot import a raw private key, so the
  secret is PKCS#8): https://developers.cloudflare.com/workers/runtime-apis/web-crypto/
