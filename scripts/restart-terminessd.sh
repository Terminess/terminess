#!/bin/sh
set -u
bin="$HOME/.local/bin/terminessd"
sock="${XDG_STATE_HOME:-$HOME/.local/state}/terminess/terminessd.sock"
log="$HOME/.local/state/terminessd-restart.log"
mkdir -p "$(dirname "$log")"
say() { echo "$(date -u +%FT%TZ) $*" >> "$log"; }

stop_all() {
    systemctl --user stop terminessd.service
    pkill -TERM -x -f "$bin serve( .*)?" 2>/dev/null
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        pgrep -x -f "$bin serve( .*)?" >/dev/null || return 0
        sleep 0.5
    done
    pkill -KILL -x -f "$bin serve( .*)?" 2>/dev/null
    sleep 0.5
}

healthy() {
    systemctl --user is-active --quiet terminessd.service || return 1
    main=$(systemctl --user show -p MainPID --value terminessd.service)
    [ "$(pgrep -x -f "$bin serve( .*)?")" = "$main" ] && [ -S "$sock" ]
}

say "restart begins"
backup=""
if [ $# -ge 1 ]; then
    backup="$bin.prev-$(date -u +%Y%m%d-%H%M%S)"
    cp "$bin" "$backup" || { say "could not back up $bin"; exit 1; }
    cp "$1" "$bin.new" && chmod 755 "$bin.new" && mv "$bin.new" "$bin" || { say "could not install $1"; exit 1; }
    say "installed $1, old binary at $backup"
fi

stop_all
systemctl --user reset-failed terminessd.service 2>/dev/null
systemctl --user start terminessd.service
sleep 8
if healthy; then
    say "up: MainPID $(systemctl --user show -p MainPID --value terminessd.service)"
    exit 0
fi

say "not healthy: $(systemctl --user is-active terminessd.service), servers: $(pgrep -x -f "$bin serve( .*)?" | tr '\n' ' ')"
[ -n "$backup" ] || exit 1
say "rolling back to $backup"
cp "$backup" "$bin.new" && mv "$bin.new" "$bin"
stop_all
systemctl --user reset-failed terminessd.service 2>/dev/null
systemctl --user start terminessd.service
sleep 5
if healthy; then say "rolled back and up"; else say "rollback not healthy either"; exit 1; fi
