#!/bin/bash
# Drives the real rustdesk_id() out of tv-setup.sh against a live box, with the same
# helpers the script itself would have. Nothing here is a copy of the logic under test.
cd "$(dirname "$0")/.."
ADB="$HOME/.chup-tv-setup/platform-tools/adb"
SERIAL="${1:-192.168.100.24:5555}"
RUSTDESK=com.carriez.flutter_hbb

S() { "$ADB" -s "$SERIAL" shell "$@" </dev/null 2>&1 | tr -d '\r'; }
A() { "$ADB" -s "$SERIAL" "$@" </dev/null 2>&1; }

# Pull the helpers rustdesk_id() leans on, straight out of the script.
for fn in ui_dump ui_box ui_find ui_seek ui_scroll ui_sig tap_point ime_rect ui_tap_if; do
    eval "$(awk -v f="$fn" '$0 ~ "^"f"\\(\\)" {p=1} p {print} p && /^}/ {p=0}' tv-setup.sh)"
done
eval "$(awk '/^rustdesk_id\(\)/ {p=1} p {print} p && /^}/ {p=0}' tv-setup.sh)"
eval "$(awk '/^group_id\(\)/ {p=1} p {print} p && /^}/ {p=0}' tv-setup.sh)"

# The swipes need a screen size, which the script reads the same way.
SIZE=$(S wm size | awk '/Physical/{print $3}')
SW=${SIZE%x*}; SH=${SIZE#*x}
case "$SW$SH" in *[!0-9]*|"") SW=1280; SH=720;; esac
SWIPE="$((SW/2)) $((SH*3/4)) $((SW/2)) $((SH/4))"
SWIPE_BACK="$((SW/2)) $((SH/4)) $((SW/2)) $((SH*3/4))"

id=$(rustdesk_id) && rc=0 || rc=$?
echo "rustdesk_id rc=$rc id=$id"
[ -n "$id" ] && echo "grouped: $(group_id "$id")"
exit $rc
