# Push relay

Forwards "session needs you" notifications from terminessd to Apple's push
service. It holds the app's APNs key; terminessd only knows device tokens.
Stores nothing, logs no content, rate-limits each device to 20 a minute.

The hosted relay is https://push.terminess.com. You can run your own; see
below.
