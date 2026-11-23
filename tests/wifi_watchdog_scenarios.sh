#!/usr/bin/env bash
# Scenario tests for wifi-watchdog's poll loop against a fake nmcli, busctl
# and clock. WATCHDOG is the script to test: test_wifi_recovery.py extracts
# it from setup.sh and runs this file.
#   WATCHDOG=/path/to/wifi-watchdog bash tests/wifi_watchdog_scenarios.sh
set -uo pipefail
: "${WATCHDOG:?set WATCHDOG to the wifi-watchdog script to test}"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# shellcheck source=/dev/null
. "$WATCHDOG"

# Fake nmcli. STATE is GENERAL.STATE (100 connected, 50 mid-attempt, 30 idle
# and disconnected), RADIO is what `nmcli radio wifi` prints, PERM is the
# enable-disable-wifi value (empty drops the row, as if the query failed),
# NM is the general state. Any attempt to toggle the radio directly is
# recorded, since the watchdog must only do that through fix-wifi.
STATE=50 RADIO=enabled PERM=yes NM=connecting SLEEPING=false BUSCTL_FAILS=false
nmcli() {
    case "$*" in
        "-t -f STATE general") printf '%s\n' "$NM" ;;
        "-t -f DEVICE,TYPE device status") printf 'lo:loopback\nwlp3s0:wifi\n' ;;
        "-t -f GENERAL.STATE device show wlp3s0") printf 'GENERAL.STATE:%s (state)\n' "$STATE" ;;
        "radio wifi") printf '%s\n' "$RADIO" ;;
        "-t -f PERMISSION,VALUE general permissions")
            printf 'org.freedesktop.NetworkManager.enable-disable-network:yes\n'
            [ -n "$PERM" ] && printf 'org.freedesktop.NetworkManager.enable-disable-wifi:%s\n' "$PERM"
            printf 'org.freedesktop.NetworkManager.enable-disable-wifi-extra:yes\n'
            ;;
        "radio wifi "*) echo "$*" >> "$tmp/direct-radio" ;;
        *) echo "unexpected nmcli $*" >&2; return 1 ;;
    esac
}
notify() { echo "$1" >> "$tmp/notify"; }
# Fake logind: only the PreparingForSleep query is expected. BUSCTL_FAILS
# makes every query fail, as on a broken bus.
# shellcheck disable=SC2317  # called by the sourced watchdog
busctl() {
    "$BUSCTL_FAILS" && return 1
    case "$*" in
        "get-property org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager PreparingForSleep")
            printf 'b %s\n' "$SLEEPING" ;;
        *) echo "unexpected busctl $*" >&2; return 1 ;;
    esac
}
# Fake clock: each poll is POLL_INTERVAL_SECONDS after the last, as in the
# real loop; a sleep is a jump forward.
CLOCK=1000000
now_seconds() { echo "$CLOCK"; }

# Fake fix-wifi: records each call, exits with FIX_RC.
FIX_RC=0
cat > "$tmp/fix-wifi" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >> "$(dirname "$0")/fix-calls"
exit "${FIX_RC:-0}"
FAKE
chmod +x "$tmp/fix-wifi"
export FIX_WIFI="$tmp/fix-wifi" FIX_RC

# The watchdog's own state, which it reads after being sourced.
# shellcheck disable=SC2034
reset() {
    fail_count=0 idle_count=0 last_trigger=0 last_poll=0 deferred=false
    STATE=50 RADIO=enabled PERM=yes NM=connecting SLEEPING=false BUSCTL_FAILS=false FIX_RC=0
    rm -f "$tmp/fix-calls" "$tmp/notify" "$tmp/direct-radio" "$tmp/out"
}
polls() {
    local i
    for ((i = 0; i < $1; i++)); do
        CLOCK=$((CLOCK + POLL_INTERVAL_SECONDS))
        poll_once >> "$tmp/out" 2>&1
    done
}
count() { if [ -f "$1" ]; then grep -c -- "${2:-}" "$1"; else echo 0; fi; }

fails=0
check() {
    local want=$1 got=$2 desc=$3
    if [ "$want" = "$got" ]; then
        printf 'ok    %s\n' "$desc"
    else
        printf 'FAIL  %s: want %q, got %q\n' "$desc" "$want" "$got"
        fails=$((fails + 1))
    fi
}

reset; STATE=100; polls 20
check 0 "$(count "$tmp/fix-calls")" "connected: never resets"

reset; polls 5
check 0 "$(count "$tmp/fix-calls")" "below threshold: no reset yet"
polls 1
check 1 "$(count "$tmp/fix-calls" --radio)" "threshold reached while authorized: one fix-wifi --radio"
check 1 "$(count "$tmp/notify" "ran a radio reset")" "success is notified as success"

reset; STATE=120; polls 6
check 1 "$(count "$tmp/fix-calls")" "activation failed (120) counts as failing"

reset; FIX_RC=1; export FIX_RC; polls 6
check 1 "$(count "$tmp/notify" "FAILED")" "a failed fix-wifi is notified as a failure"
FIX_RC=0; export FIX_RC

reset; polls 6; polls 29
check 1 "$(count "$tmp/fix-calls")" "cooldown: still failing within 300s, no second reset"
polls 1
check 2 "$(count "$tmp/fix-calls")" "cooldown over and still failing: one more reset"

# Idle and disconnected is not a lockup: nothing saved in range, or wifi
# left on next to a cable. It must never cycle the radio.
reset; STATE=30; polls 200
check 0 "$(count "$tmp/fix-calls")" "idle and disconnected for half an hour: never resets"
reset; STATE=20; polls 60
check 0 "$(count "$tmp/fix-calls")" "device unavailable: never resets"
# NetworkManager rests a few seconds between failed attempts; a poll landing
# in that gap must not hide a lockup.
reset
for _ in 1 2 3 4; do STATE=50; polls 2; STATE=30; polls 1; done
check 1 "$(count "$tmp/fix-calls")" "failed attempts with short idle gaps between: resets"
# A minute of idle means NetworkManager stopped trying: start the count again.
reset; polls 5; STATE=30; polls 6; STATE=50; polls 5
check 0 "$(count "$tmp/fix-calls")" "a minute idle between failures restarts the count"
polls 1
check 1 "$(count "$tmp/fix-calls")" "then a full threshold of failing: resets"

reset; PERM=no; polls 40
check 0 "$(count "$tmp/fix-calls")" "locked session (permission no): never resets"
check 1 "$(count "$tmp/out" "deferring")" "deferral is logged once, not every poll"
PERM=yes; polls 1
check 1 "$(count "$tmp/fix-calls")" "unlocked and still failing: resets on the next poll"

reset; PERM=auth; polls 10
check 0 "$(count "$tmp/fix-calls")" "permission auth (would need a password): never resets"

reset; PERM=""; polls 10
check 0 "$(count "$tmp/fix-calls")" "permission row missing: fails safe, no reset"

reset; PERM=no; polls 6; STATE=100; polls 1; STATE=50; polls 6
check 2 "$(count "$tmp/out" "deferring")" "reconnecting clears the deferral, next stall logs again"

reset; RADIO=disabled; polls 10
check 0 "$(count "$tmp/fix-calls")" "radio switched off by the user: left alone"

# Sleep: NetworkManager takes wifi down on purpose; that is not a lockup.
reset; NM=asleep; polls 40
check 0 "$(count "$tmp/fix-calls")" "NetworkManager asleep: never resets"
reset; SLEEPING=true; polls 40
check 0 "$(count "$tmp/fix-calls")" "suspend starting (PreparingForSleep): never resets"
# A failing suspend retrying every ~100s, NetworkManager asleep for part of
# each try: failing time on either side of a sleep must not add up.
reset
for _ in 1 2 3 4 5 6; do polls 4; NM=asleep; polls 2; NM=connecting; done
check 0 "$(count "$tmp/fix-calls")" "suspend retry loop: failures around each sleep don't add up"
reset; polls 5; SLEEPING=true; polls 1; SLEEPING=false; polls 5
check 0 "$(count "$tmp/fix-calls")" "PreparingForSleep restarts the count"
# A real sleep freezes the loop: the clock jumps and the count starts again.
reset; polls 5; CLOCK=$((CLOCK + 3600)); polls 5
check 0 "$(count "$tmp/fix-calls")" "woken after an hour: count starts again"
polls 1
check 1 "$(count "$tmp/fix-calls")" "still failing a full threshold after waking: resets"
reset; PERM=no; polls 6; CLOCK=$((CLOCK + 600)); PERM=yes; polls 1
check 0 "$(count "$tmp/fix-calls")" "a deferral from before a sleep doesn't fire on wake"
# A missing logind answer must not switch the watchdog off.
reset; BUSCTL_FAILS=true; polls 6
check 1 "$(count "$tmp/fix-calls")" "logind query failing: still resets a real lockup"

# /usr/bin:/bin keeps awk and friends but not /usr/local/bin, so a real
# fix-wifi on the machine running the tests is never picked up here.
reset; FIX_WIFI="" PATH=/usr/bin:/bin polls 6
check 0 "$(count "$tmp/direct-radio")" "fix-wifi missing: never toggles the radio itself"
check 1 "$(count "$tmp/notify" "fix-wifi is missing")" "fix-wifi missing: says so"

check 0 "$(count "$tmp/direct-radio")" "the radio is only ever toggled through fix-wifi"

# find_fix_wifi prefers the fix-wifi installed beside the watchdog, also
# through a symlink, without needing it on PATH.
mkdir -p "$tmp/bin"
cp "$WATCHDOG" "$tmp/bin/wifi-watchdog"
cp "$tmp/fix-wifi" "$tmp/bin/fix-wifi"
check "$tmp/bin/fix-wifi" \
    "$(PATH=/usr/bin:/bin bash -c '. "$1"; find_fix_wifi' _ "$tmp/bin/wifi-watchdog")" \
    "finds fix-wifi beside itself without it on PATH"
ln -s "$tmp/bin/wifi-watchdog" "$tmp/watchdog-link"
check "$tmp/bin/fix-wifi" \
    "$(PATH=/usr/bin:/bin bash -c '. "$1"; find_fix_wifi' _ "$tmp/watchdog-link")" \
    "resolves a symlinked wifi-watchdog to its real directory"

echo
if [ "$fails" -eq 0 ]; then
    echo "all tests passed"
else
    echo "$fails test(s) failed"
    exit 1
fi
