# Push relay

Forwards "session needs you" notifications from terminessd to Apple's push
service. It holds the app's APNs key; terminessd only knows device tokens.
Stores nothing, logs no content. Sends only fixed generic text, checks requests strictly, and limits per device (20 a minute), per sender (60), overall (1200) and concurrency (32). Tokens Apple rejects are refused for a day.

The hosted relay is https://push.terminess.com. You can run your own; see
below.

Registration: `RELAY_SECRET` in `relay.env` (generated on
the server, never copied off it) signs challenges and credentials. Phones get
a credential by receiving a challenge through APNs and sending it back, then
hand it to their machines over SSH. Set `REQUIRE_CREDENTIAL=1` in `relay.env`
once every machine runs a terminessd that sends one; until then requests
without a credential are still accepted (a wrong one is always refused).
Changing `RELAY_SECRET` invalidates every credential; phones fetch new ones
on their next launch.

Revocation: removing a phone on a Mac cancels its
credential through `POST /v1/revoke`. The relay keeps the cancelled tokens in
`/var/lib/terminess-relay/revoked.json`, from the drop-in
`/etc/systemd/system/terminess-relay.service.d/state.conf`
(`StateDirectory=terminess-relay`). Credentials issued before a phone was
removed are refused; pairing it again issues a new one that works.
