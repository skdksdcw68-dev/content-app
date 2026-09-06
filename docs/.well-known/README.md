# Why this directory exists

`apple-app-site-association` is how iOS learns that netrocast.com belongs to the
Autocast app. Once the app declares `applinks:netrocast.com` in its Associated
Domains entitlement, iOS fetches this file and, from then on, opens the matching
paths in the app rather than in Safari.

That is the whole mechanism behind app-to-app OAuth: TikTok's SDK needs the
redirect URI to be a Universal Link, not a custom scheme, so this file is what
makes `https://netrocast.com/oauth/tiktok/callback/` route into Autocast.

Two things to know if it stops working:

- The file has **no extension** and must be served as `application/json`.
  Apple's CDN fetches it, not the device, so a wrong content type fails silently
  and the link just opens in Safari as if nothing was configured.
- Apple caches it. Changes can take up to 24 hours to reach devices, and the
  entitlement must already be in the signed build before any of it takes effect.
