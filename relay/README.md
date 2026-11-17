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

Housekeeping: rate-limit counters last one minute and rejected tokens one day,
in memory only, swept every minute; `revoked.json` keeps entries for one year
(`CREDENTIAL_SECONDS`), pruned on load and on every write. Logs carry the
request path and status only. `python3 relay/test_relay.py` checks all of it
without Apple keys.

## Run your own relay

Notifications can go through a relay you run instead of push.terminess.com.
On the iPhone: Settings, Notifications, "My own relay", then its address. Each
machine then sends that phone's notifications to your relay; nothing reaches
ours. Choosing "Off" means no relay at all, and the phone sees updates only
while the app is open.

Apple only delivers to an app signed by the team that owns the push key, so a
relay of your own needs your own build of the app:

1. An Apple Developer account. Build the iPhone app from `ios/` with your own
   team and bundle id (`ios/project.yml`), with Push Notifications enabled.
2. An APNs key (Certificates, Identifiers & Profiles, Keys, Apple Push
   Notifications service). Note its key id and your team id.
3. A host with Python 3.11+ reachable over https (any reverse proxy or tunnel
   that terminates TLS in front of port 8099):

   ```sh
   python3 -m venv venv && venv/bin/pip install "httpx[http2]" pyjwt cryptography
   APNS_KEY_PATH=/path/AuthKey_XXXX.p8 APNS_KEY_ID=XXXX APNS_TEAM_ID=YYYY \
   APNS_TOPIC=your.bundle.id RELAY_SECRET=$(openssl rand -hex 32) \
   STATE_DIRECTORY=/var/lib/terminess-relay venv/bin/python relay.py
   ```

4. On the phone, enter `https://your-relay.example.com/v1`. Machines must run a
   terminessd that knows custom relays (it stores the address per phone).
