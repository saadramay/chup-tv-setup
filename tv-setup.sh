#!/bin/bash
# Chup TV box setup: installs Chup TV + RustDesk and grants what unattended remote support needs.
# Usage (macOS):  curl -fsSL https://raw.githubusercontent.com/saadramay/chup-tv-setup/main/tv-setup.sh | bash
#            or:  bash tv-setup.sh [path/to/ChupTvApp.apk]

CHUP_TV_BRANCH="${CHUP_TV_BRANCH:-selgate}"
REMOTE_SUPPORT_JSON="${REMOTE_SUPPORT_JSON:-https://raw.githubusercontent.com/saadramay/chup-tv-setup/main/remote-support.json}"
RUSTDESK=com.carriez.flutter_hbb
CHUPTV=com.chup.tvapp
WORK="$HOME/.chup-tv-setup"
LOCAL_CHUP_APK="${1:-}"
# The setup app guides the pairing and connecting itself, so it only needs this script up far
# enough to have adb in place. `bash tv-setup.sh --prep` does that and stops.
PREP_ONLY=""
if [ "$LOCAL_CHUP_APK" = "--prep" ]; then PREP_ONLY=1; LOCAL_CHUP_APK=""; fi

bold() { printf '\n\033[1m%s\033[0m\n' "$1"; }
ok()   { spinner_stop; printf '  \033[32m✓\033[0m %s\n' "$1"; }
warn() { spinner_stop; printf '  \033[33m!\033[0m %s\n' "$1"; }
die()  { spinner_stop; printf '\n\033[31mStopped:\033[0m %s\n' "$1"; exit 1; }
# GUI mode (CHUP_UI=1, set by the Chup Setup app): there is no controlling terminal, so a
# question is emitted to stderr as a '::ask [secure] <question>' control line and the answer
# comes back on stdin. stdout stays reserved for the log, which the app renders as-is.
# The app never logs either the question or the answer, so passwords stay off the screen.
ask()  {
    local a
    spinner_stop
    if [ -n "${CHUP_UI:-}" ]; then
        printf '::ask %s\n' "$1" >&2
        IFS= read -r a || {
            # The app closed our stdin, so no answer can ever arrive. Stop rather than loop on
            # empty answers. $$ is this script even inside $( ... ).
            printf 'Stopped: the app is no longer sending answers\n' >&2
            kill -TERM $$
            return 1
        }
        printf '%s\n' "$a"
        return 0
    fi
    read -r -p "  $1 " a </dev/tty \
        || { printf 'Stopped: nothing to read the answer from (set CHUP_UI=1 when running inside an app)\n' >&2; return 1; }
    echo "$a"
}
pause() {
    local a
    spinner_stop
    if [ -n "${CHUP_UI:-}" ]; then
        printf '::ask %s\n' "$1 Press Enter to continue..." >&2
        IFS= read -r a || {
            # Not being able to continue is not the same as having continued: say so and stop.
            printf 'Stopped: the app is no longer sending answers\n'
            kill -TERM $$
            return 1
        }
        return 0
    fi
    read -r -p "  $1 Press Enter to continue..." a </dev/tty \
        || { printf 'Stopped: nothing to read the answer from (set CHUP_UI=1 when running inside an app)\n' >&2; return 1; }
}

# A secret the log must never see. Same shape as ask(), but marked 'secure' on the control
# line so the app renders a password field and writes neither the question nor the answer down.
ask_secure() {
    local a
    spinner_stop
    if [ -n "${CHUP_UI:-}" ]; then
        printf '::ask secure %s\n' "$1" >&2
        IFS= read -r a || {
            printf 'Stopped: the app is no longer sending answers\n' >&2
            kill -TERM $$
            return 1
        }
        printf '%s\n' "$a"
        return 0
    fi
    read -r -p "  $1 " a </dev/tty \
        || { printf 'Stopped: nothing to read the answer from (set CHUP_UI=1 when running inside an app)\n' >&2; return 1; }
    echo "$a"
}

# Progress for the stretches where the script is talking to the TV and has nothing to print:
# connecting, the settings run on the TV, and the reboot wait. Without it those minutes look
# exactly like a hang. The elapsed seconds tick along so it's obvious the script is alive.
# Output is one line rewritten in place, so anything that prints or prompts clears it first
# (ok/warn/die/ask/pause above). Only runs on a real terminal, so piped or logged runs stay clean.
SPIN_PID=""; SPIN_MSG=""
spinner_start() {
    [ -t 1 ] || return 0
    spinner_stop
    SPIN_MSG="$1"
    (
        F=( '|' '/' '-' '\' )
        i=0; t0=$SECONDS
        while :; do
            printf '\r  %s %s (%ss)' "${F[i]}" "$SPIN_MSG" "$((SECONDS - t0))"
            i=$(( (i + 1) % 4 ))
            sleep 0.2
        done
    ) &
    SPIN_PID=$!
}
spinner_stop() {
    [ -n "$SPIN_PID" ] || return 0
    kill "$SPIN_PID" 2>/dev/null
    wait "$SPIN_PID" 2>/dev/null
    SPIN_PID=""
    printf '\r%*s\r' 64 "" 2>/dev/null
}

mkdir -p "$WORK" || die "cannot create $WORK"

# Any keyboard character works; adb can't type accents or emoji.
password_ok() {
    [ ${#1} -ge 8 ] || { warn "needs at least 8 characters"; return 1; }
    case "$1" in *[![:print:]]*) warn "only plain keyboard characters (no accents or emoji)"; return 1;; esac
    LC_ALL=C; case "$1" in *[!\ -~]*) unset LC_ALL; warn "only plain keyboard characters (no accents or emoji)"; return 1;; esac; unset LC_ALL
}

# Asks for the RustDesk permanent password once RustDesk is installed and Start on boot is set.
# Or set RUSTDESK_PASSWORD to skip the prompt.
RD_PASSWORD="${RUSTDESK_PASSWORD:-}"
ask_password() {
    [ -n "$RD_PASSWORD" ] && { password_ok "$RD_PASSWORD" || die "RUSTDESK_PASSWORD doesn't meet RustDesk's rules"; return 0; }
    # The prompt goes straight to the terminal, so hide the spinner while it's up and put it
    # back afterwards -- the settings run on the TV continues for a while after this.
    local had_spin="$SPIN_PID"
    spinner_stop
    while :; do
        if [ -n "${CHUP_UI:-}" ]; then
            printf '::ask secure %s\n' "RustDesk permanent password" >&2
            IFS= read -r RD_PASSWORD || die "no password entered"
        else
            printf '  RustDesk permanent password: ' >/dev/tty
            IFS= read -r RD_PASSWORD </dev/tty || die "no password entered"
        fi
        password_ok "$RD_PASSWORD" && break
    done
    [ -n "$had_spin" ] && spinner_start "$SPIN_MSG"
    return 0
}


# ---------- adb ----------
bold "1/7  Getting adb"
# The manifest carries every download URL (adb and both apps), so read it up front.
# If it can't be refreshed we keep the copy from an earlier run rather than failing here.
MANIFEST="$WORK/remote-support.json"
MANTMP="$WORK/remote-support.json.tmp"
if curl -fsSL -o "$MANTMP" "$REMOTE_SUPPORT_JSON" 2>/dev/null || cp "${REMOTE_SUPPORT_JSON#file://}" "$MANTMP" 2>/dev/null; then
    mv "$MANTMP" "$MANIFEST"
else
    rm -f "$MANTMP"
fi

if command -v adb >/dev/null 2>&1; then
    ADB=$(command -v adb)
else
    ADB="$WORK/platform-tools/adb"
    if [ ! -x "$ADB" ]; then
        # Our pinned release asset first, Google's own mirror as the fallback.
        PT_URLS="$(plutil -extract platform_tools.darwin raw -o - "$MANIFEST" 2>/dev/null) https://dl.google.com/android/repository/platform-tools-latest-darwin.zip"
        for PT in $PT_URLS; do
            if curl -fsSL -o "$WORK/pt.zip" "$PT" 2>/dev/null && unzip -qo "$WORK/pt.zip" -d "$WORK" 2>/dev/null; then
                rm -f "$WORK/pt.zip"
                break
            fi
            rm -f "$WORK/pt.zip"
        done
        [ -x "$ADB" ] || die "could not download adb (tried our release mirror, then dl.google.com)"
    fi
fi
"$ADB" start-server </dev/null >/dev/null 2>&1
ok "adb ready"
# Stopped here on purpose: everything below wants a TV that is already reachable.
[ -z "$PREP_ONLY" ] || exit 0

# ---------- connect ----------
bold "2/7  Connecting to the TV box"
SERIAL=""

mdns_addr()  { "$ADB" mdns services </dev/null 2>/dev/null | awk -v t="$1" '$0 ~ t {print $NF; exit}'; }
# adb's mDNS browsing is racy: a single call often comes back empty, so keep looking
# for a few seconds and hold what we find.
MDNS_CACHE=""
mdns_refresh() {
    local i
    MDNS_CACHE=""
    for i in $(seq 1 6); do
        MDNS_CACHE=$("$ADB" mdns services </dev/null 2>/dev/null)
        printf '%s\n' "$MDNS_CACHE" | grep -q "adb-tls" && return 0
        sleep 2
    done
    return 0
}
# mdns_addrs <type>: every matching mDNS address, e.g. mdns_addrs "_adb-tls-connect"
mdns_addrs() { printf '%s\n' "$MDNS_CACHE" | awk -v t="$1" 'index($2, t) {print $3}'; }

# Older boxes expose adb on port 5555: scan this Mac's /24 for it.
scan_adb_port() {
    local ip prefix i
    ip=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null)
    [ -n "$ip" ] || return 0
    prefix=${ip%.*}
    for i in $(seq 1 254); do
        ( nc -z -G 1 -w 1 "$prefix.$i" 5555 >/dev/null 2>&1 && echo "$prefix.$i" ) &
    done
    wait
}

# connect_wait <addr> [tries]: connect and wait up to 2 minutes for the box to be ready.
connect_wait() {
    local addr="$1" tries="${2:-40}" state i
    spinner_start "connecting to $addr"
    case "$addr" in *:*) "$ADB" connect "$addr" </dev/null >/dev/null 2>&1;; esac
    for i in $(seq 1 "$tries"); do
        state=$("$ADB" -s "$addr" get-state </dev/null 2>&1)
        [ "$state" = "device" ] && { spinner_stop; return 0; }
        case "$state" in *unauthorized*)
            [ "$i" = 1 ] && { warn "On the TV, tick 'Always allow from this computer' and press OK on the debugging popup (waiting up to 2 minutes)."; spinner_start "$SPIN_MSG"; }
            # A denied popup never comes back on the same connection: reconnect every 15s to ask again.
            case "$addr" in *:*) [ $((i % 5)) = 0 ] && "$ADB" disconnect "$addr" </dev/null >/dev/null 2>&1;; esac ;;
        esac
        sleep 3
        case "$addr" in *:*) "$ADB" connect "$addr" </dev/null >/dev/null 2>&1;; esac
    done
    # Stop here rather than leave it to the caller: we're no longer connecting, so the
    # message is stale by now.
    spinner_stop
    return 1
}

# pair_wireless [pairing addr]: for boxes that only offer Wireless debugging with a pairing code
# (Xiaomi, Google TV). With an address it skips the mDNS lookup; without one it asks the TV.
# Sets ADDR and STATE.
pair_wireless() {
    local pair_addr="$1" code
    echo "  On the TV: Settings > Developer options > Wireless debugging > Pair device with pairing code"
    if [ -n "$pair_addr" ]; then
        ok "that TV is offering pairing at $pair_addr"
    else
        pause "Keep that pairing screen open on the TV."
        pair_addr=$(mdns_addrs "_adb-tls-pairing" | head -1)
    fi
    if [ -z "$pair_addr" ]; then
        pair_addr=$(ask "Type the IP address & Port shown on the TV pairing screen (like 192.168.1.20:37123):")
    fi
    [ -n "$pair_addr" ] || die "no pairing address given"
    case "$pair_addr" in
        *:*)
            code=$(ask "Type the 6-digit pairing code shown on the TV:")
            "$ADB" pair "$pair_addr" "$code" </dev/null | grep -qi "success" || die "pairing failed, check the code and try again"
            ok "paired"
            sleep 2
            # Pairing changes the connect port: look again for this TV's new one.
            mdns_refresh
            ADDR=$(mdns_addrs "_adb-tls-connect" | awk -v ip="${pair_addr%:*}" 'index($0, ip":") {print; exit}')
            [ -n "$ADDR" ] || ADDR=$(ask "Type the IP address & Port shown on the main Wireless debugging screen:")
            ;;
        *)
            ADDR="$pair_addr:5555"
            ;;
    esac
    STATE="new"
}

# adb's mDNS browser sometimes returns only one service type per call, so a single
# quick check often misses the pairing service. Run a few times and keep the fullest.
mdns_quick() {
    local i best=""
    MDNS_CACHE=""
    for i in 1 2 3 4; do
        local out
        out=$("$ADB" mdns services </dev/null 2>/dev/null)
        if printf '%s\n' "$out" | grep -q "adb-tls"; then
            # Count adb-tls lines; keep the richest response
            local n_new n_best
            n_new=$(printf '%s\n' "$out" | grep -c "adb-tls")
            n_best=$(printf '%s\n' "$best" | grep -c "adb-tls")
            if [ "$n_new" -gt "$n_best" ]; then
                best="$out"
            fi
        fi
        sleep 1
    done
    MDNS_CACHE="$best"
    return 0
}

# Everything this Mac could reach: what adb already has attached, boxes with adb open on
# port 5555, and boxes offering Wireless debugging over mDNS. Sets LIST and COUNT.
OPEN5555=$(scan_adb_port)
find_devices() {
    # Everything adb already sees (USB, network, emulator), ready or not.
    LIST=$("$ADB" devices </dev/null | awk 'NR>1 && $1!="*" && NF>=2 {print $1, $2}')
    # Plus boxes on this Wi-Fi with adb already open (port 5555): those need no pairing.
    for ip in $OPEN5555; do
        echo "$LIST" | awk -v a="$ip:5555" '$1==a {found=1} END {exit !found}' \
            || LIST="$LIST
$ip:5555 new"
    done
    # Plus devices offering Wireless debugging (Xiaomi, Google TV), which adb finds by mDNS.
    # A pairing service means that TV's pairing screen is open; it wins, because a connect
    # service only works on a device this Mac is already paired with.
    mdns_quick
    PAIRING_IPS=""
    for a in $(mdns_addrs "_adb-tls-pairing"); do
        PAIRING_IPS="$PAIRING_IPS ${a%:*}"
        case "$LIST" in *"$a "*) ;; *) LIST="$LIST
$a pairing";; esac
    done
    for a in $(mdns_addrs "_adb-tls-connect"); do
        case " $PAIRING_IPS " in *" ${a%:*} "*) continue;; esac
        echo "$LIST" | awk -v x="$a" '$1==x {found=1} END {exit !found}' \
            || LIST="$LIST
$a paired"
    done
    # No blank lines, so list position N is line N.
    LIST=$(printf '%s\n' "$LIST" | grep -v '^[[:space:]]*$')
    COUNT=$(printf '%s\n' "$LIST" | grep -c .)
}

ADDR=""; STATE=""
# The setup app chose and connected the TV in its own step and hands us that serial, so
# asking "which one is this TV?" here would only ask again what step 2 already answered.
# Trust it only while the box still answers: if it has dropped off, look for it the normal way.
if [ -n "${CHUP_SERIAL:-}" ]; then
    if [ "$("$ADB" -s "$CHUP_SERIAL" get-state </dev/null 2>/dev/null)" = "device" ] \
        || connect_wait "$CHUP_SERIAL" 4; then
        ADDR="$CHUP_SERIAL"
        STATE="device"
    fi
fi

if [ -z "$ADDR" ]; then
    echo "  Looking for devices on this Mac and this Wi-Fi..."
    find_devices
    # The first look is often too early -- somebody may still be switching Wireless debugging
    # on. Keep looking for a couple of minutes rather than call the network empty and fall
    # through to the pairing fallback.
    WAIT=0
    while [ -z "$LIST" ] && [ "$WAIT" -lt 120 ]; do
        [ "$WAIT" = 0 ] || echo "  Still looking for a TV... turn Wireless debugging on and leave this screen open. (${WAIT}s)"
        sleep 3
        WAIT=$((WAIT + 3))
        find_devices
    done

    if [ -n "$LIST" ]; then
        echo "  Devices found:"
        N=0
        first_addr=""
        first_label=""
        while read -r addr state; do
            [ -n "$addr" ] || continue
            N=$((N+1))
            case "$addr" in
                emulator-*) kind="emulator";;
                *:*)        kind="network";;
                *)          kind="USB";;
            esac
            case "$state" in
                device)
                    model=$("$ADB" -s "$addr" shell getprop ro.product.model 2>/dev/null </dev/null | tr -d '\r')
                    ver=$("$ADB" -s "$addr" shell getprop ro.build.version.release 2>/dev/null </dev/null | tr -d '\r')
                    label="$model, Android $ver";;
                new)     label="found on this Wi-Fi";;
                paired)  label="wireless debugging";;
                pairing) label="wireless debugging, type its pairing code";;
                *)       label="$state: press Allow on the TV";;
            esac
            printf '    %d. %-22s %-28s (%s)\n' "$N" "$addr" "$label" "$kind"
            if [ "$N" = 1 ]; then
                first_addr="$addr"
                first_label="$label"
            fi
        done < <(echo "$LIST")

        # Enter only picks when there is a single device, so nobody sets up the wrong one by accident.
        while :; do
            if [ "$COUNT" = 1 ]; then
                PICK=$(ask "Is this the TV? $first_addr ($first_label) — Enter = yes, or 'pair' to use a pairing code")
                [ -z "$PICK" ] && PICK=1
            else
                PICK=$(ask "Which one is this TV? Type its number (or 'pair' to use a pairing code)")
            fi
            [ -n "$PICK" ] && break
            warn "please type the number of the TV"
        done
        case "$PICK" in
            p|pair) pair_wireless;;
            n|N|no|No) [ "$COUNT" = 1 ] && pair_wireless;;
        esac
    fi

    if [ -z "$ADDR" ]; then
        if [ -z "$LIST" ]; then
            echo "  No device found."
            pair_wireless
        else
            case "$PICK" in
                *[!0-9]*)
                    # not a number: an address typed by hand
                    ADDR=$PICK; STATE=new
                    case "$ADDR" in *:*) ;; *) ADDR="$ADDR:5555";; esac ;;
                *)
                    PICKED=$(printf '%s\n' "$LIST" | sed -n "${PICK}p")
                    [ -n "$PICKED" ] || die "there is no device $PICK in the list"
                    ADDR=${PICKED%% *}; STATE=${PICKED##* } ;;
            esac
        fi
    fi
fi

if [ "$STATE" = "pairing" ]; then
    pair_wireless "$ADDR"
fi

if [ "$STATE" = "paired" ] && ! connect_wait "$ADDR" 3; then
    # A TV advertises its connect service whether or not this Mac is paired with it, and an
    # unpaired TV shows no popup at all: pairing is the only way in from here.
    "$ADB" disconnect "$ADDR" </dev/null >/dev/null 2>&1
    warn "this Mac isn't paired with that TV yet"
    pair_wireless
fi

if [ "$STATE" = "device" ]; then
    SERIAL=$ADDR
    ok "using $ADDR"
else
    connect_wait "$ADDR" || die "could not connect to $ADDR"
    SERIAL=$ADDR
    ok "connected ($SERIAL)"
fi

# The setup app has no other honest signal that the TV answered: mDNS reports what is
# advertising on the network, not what attached. This is what marks "Connect to the TV" done.
[ -z "${CHUP_UI:-}" ] || printf '::connected %s\n' "$SERIAL" >&2

# adb takes the script's stdin away from us (it is often piped in with curl | bash), and
# would otherwise swallow lines meant for a pipe further down. Never let it read stdin.
A() { "$ADB" -s "$SERIAL" "$@" </dev/null; }
S() { "$ADB" -s "$SERIAL" shell "$@" </dev/null; }

# Install an APK over whatever the box already has. A box can be running a newer build than
# this setup carries -- somebody installed one by hand, or the manifest is behind -- and adb
# then refuses with VERSION_DOWNGRADE. That is not a reason to stop: what this step is for is
# the app being installed and working, and a newer app still is. Aborting threw away a working
# setup, and the box's login, over a version number.
install_app() {
    local pkg=$1 apk=$2 label=$3 out have
    out=$(A install -r -g "$apk" 2>&1)
    case "$out" in
    *Success*)
        return 0
        ;;
    *VERSION_DOWNGRADE*)
        have=$(S dumpsys package "$pkg" 2>/dev/null | grep -m1 versionName | tr -d '\r' | sed 's/.*versionName=//; s/ .*//')
        [ -n "$have" ] || die "$label install failed ($(printf '%s' "$out" | tr -d '\r' | tail -1))"
        warn "$label: box is on $have, newer than this setup carries -- keeping it"
        return 0
        ;;
    esac
    # The real adb line, rather than the one-line "install failed" the old `| grep -q Success`
    # swallowed: [INSTALL_FAILED_...] is the whole reason it failed.
    die "$label install failed ($(printf '%s' "$out" | tr -d '\r' | tail -1))"
}

# KEYCODE_WAKEUP: turns the screen on, and does nothing if it already is.
wake_screen() { S input keyevent 224 >/dev/null 2>&1; }

# A TV that sleeps its screen takes wireless debugging down with it - and comes back on a
# different port - which kills a run half way through. Turn the screen on and hold it for as
# long as we are working, then put the setting back exactly as we found it.
# Empty means "we have not touched this setting", so restore_awake stays a no-op until
# keep_awake has read what was there. A run stopped before that point must not write back a
# value it never took.
STAY_ON_WAS=""
restore_awake() { if [ -n "$STAY_ON_WAS" ]; then S settings put global stay_on_while_plugged_in "$STAY_ON_WAS" >/dev/null 2>&1; fi; }
# One handler for both clean-ups: kill the progress spinner so it can't outlive the script on
# your terminal, then put the TV's stay-on setting back the way we found it. Installed before
# anything touches the TV, so a run stopped at any point - Ctrl-C, a failed step, or the setup
# app being closed - still cleans up after itself.
on_exit() { spinner_stop; restore_awake; }
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
keep_awake() {
    local v
    v=$(S settings get global stay_on_while_plugged_in 2>/dev/null | tr -d '\r')
    case "$v" in ''|null|*[!0-9]*) v=0 ;; esac
    STAY_ON_WAS=$v
    S svc power stayon true >/dev/null 2>&1
}
wake_screen
sleep 1
keep_awake
ok "keeping the screen awake"

MODEL=$(S getprop ro.product.model | tr -d '\r')
ANDROID=$(S getprop ro.build.version.release | tr -d '\r')
ABI=$(S getprop ro.product.cpu.abi | tr -d '\r')
ok "$MODEL, Android $ANDROID, $ABI"

# ---------- download ----------
bold "3/7  Downloading apps"
# --progress-bar redraws one line with \r, which fills a log pane with noise instead of
# feedback. -sS works on every curl macOS has shipped; --no-progress-meter (7.67+) does not.
get() { if [ -n "${CHUP_UI:-}" ]; then curl -fL -sS "$@"; else curl -fL --progress-bar "$@"; fi; }
# MANIFEST was fetched in step 1; it must exist now for the URLs below.
[ -s "$MANIFEST" ] || die "could not read $REMOTE_SUPPORT_JSON"
RD_URL=$(plutil -extract "builds.$ABI" raw -o - "$MANIFEST" 2>/dev/null)
[ -n "$RD_URL" ] || die "no RustDesk build listed for $ABI"
get -o "$WORK/rustdesk.apk" "$RD_URL" || die "RustDesk download failed"
ok "RustDesk"

if [ -n "$LOCAL_CHUP_APK" ]; then
    [ -f "$LOCAL_CHUP_APK" ] || die "file not found: $LOCAL_CHUP_APK"
    cp "$LOCAL_CHUP_APK" "$WORK/chup-tv.apk"
else
    CHUP_TV_APK_URL=$(plutil -extract "chup_tv.$CHUP_TV_BRANCH.url" raw -o - "$MANIFEST" 2>/dev/null)
    [ -n "$CHUP_TV_APK_URL" ] || die "no Chup TV app listed for '$CHUP_TV_BRANCH'"
    get -o "$WORK/chup-tv.apk" "$CHUP_TV_APK_URL" || die "Chup TV app download failed ($CHUP_TV_APK_URL)"
fi
ok "Chup TV app"

# ---------- install + grants ----------
bold "4/7  Installing and granting permissions"
install_app $CHUPTV "$WORK/chup-tv.apk" "Chup TV app"
ok "Chup TV app installed"
install_app $RUSTDESK "$WORK/rustdesk.apk" "RustDesk"
ok "RustDesk installed"

S appops set $RUSTDESK PROJECT_MEDIA allow
S appops set $RUSTDESK SYSTEM_ALERT_WINDOW allow
S appops set $RUSTDESK RUN_IN_BACKGROUND allow
S appops set $RUSTDESK RUN_ANY_IN_BACKGROUND allow >/dev/null 2>&1
S dumpsys deviceidle whitelist +$RUSTDESK >/dev/null

INPUT_SVC="$RUSTDESK/$RUSTDESK.InputService"
# Turned on only after step 5: every uiautomator screen read suspends accessibility services.
enable_input() {
    local cur
    cur=$(S settings get secure enabled_accessibility_services | tr -d '\r')
    case "$cur" in
        *"$INPUT_SVC"*) ;;
        ""|null) S settings put secure enabled_accessibility_services "$INPUT_SVC" ;;
        *) S settings put secure enabled_accessibility_services "$cur:$INPUT_SVC" ;;
    esac
    S settings put secure accessibility_enabled 1
    sleep 2
    S dumpsys accessibility | grep -q "label=RustDesk Input"
}
S cmd appops write-settings >/dev/null

S cmd appops get $RUSTDESK | grep -q "PROJECT_MEDIA: allow" || die "screen capture permission did not stick"
[ "$(S dumpsys deviceidle whitelist | grep -c $RUSTDESK)" -ge 1 ] || die "battery exemption did not stick"
ok "screen capture, overlay, background, battery exemption"

# ---------- RustDesk settings ----------
bold "5/7  RustDesk settings (Start on boot, password, start service)"

SIZE=$(S wm size | tr -d '\r' | awk '/Physical/{print $3}')
SW=${SIZE%x*}; SH=${SIZE#*x}
case "$SW$SH" in *[!0-9]*|"") SW=1280; SH=720;; esac
SWIPE="$((SW/2)) $((SH*3/4)) $((SW/2)) $((SH/4))"
# The same swipe the other way: back up towards the top of the list.
SWIPE_BACK="$((SW/2)) $((SH/4)) $((SW/2)) $((SH*3/4))"

# uiautomator dump can refuse -- "could not get idle state" while an app animates or ticks a
# clock, which Chup TV's home screen does forever -- and it leaves the file from the last
# successful dump behind. Reading that would have every ui_find describing a screen that is no
# longer there and aiming taps at it, so clear it first: a failed dump then honestly reads as
# "nothing on screen" rather than confidently as last time's screen.
ui_dump() {
    A shell rm -f /sdcard/chup-ui.xml
    S uiautomator dump /sdcard/chup-ui.xml >/dev/null 2>&1
    A exec-out cat /sdcard/chup-ui.xml 2>/dev/null
}

# A fingerprint of what is on screen, so we can tell whether a swipe moved the list.
ui_sig() {
    ui_dump | LC_ALL=C perl -0ne '
        my @o;
        while (/<node\b([^>]*)>/g) {
            my $a = $1;
            my ($d) = $a =~ /\bcontent-desc="([^"]*)"/; my ($t) = $a =~ /\btext="([^"]*)"/;
            my ($y1) = $a =~ /\bbounds="\[\d+,(\d+)\]/;
            my $v = defined $d ? $d : (defined $t ? $t : "");
            next unless defined $y1 && length $v;
            push @o, "$y1:$v"; last if @o >= 6;
        }
        print join("|", @o);'
}

ui_scroll() { if [ "$1" -eq 1 ]; then S input swipe $SWIPE 300; else S input swipe $SWIPE_BACK 300; fi; sleep 1; }

# ui_seek <probe> <regex>: scroll until the probe prints something. Goes down the list first
# and reverses when it stops moving, so a row above the current position is still reachable.
# Prints the probe's output; returns 1 when the row is not on this screen at all.
ui_seek() {
    local out sig prev="" dir=1 i
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
        out=$("$@")
        [ -n "$out" ] && { printf '%s\n' "$out"; return 0; }
        sig=$(ui_sig)
        if [ -n "$sig" ]; then
            if [ "$sig" = "$prev" ]; then
                [ "$dir" -eq 1 ] || return 1
                dir=-1
            fi
            prev=$sig
        fi
        ui_scroll "$dir"
    done
    return 1
}

# "x1 y1 x2 y2" of the first node whose text or content-desc matches the regex.
ui_box() {
    ui_dump | LC_ALL=C perl -0ne '
        my $re = qr/'"$1"'/i;
        while (/<node\b([^>]*)>/g) {
            my $a = $1;
            my ($t) = $a =~ /\btext="([^"]*)"/; my ($d) = $a =~ /\bcontent-desc="([^"]*)"/;
            next unless (($t // "") =~ $re) || (($d // "") =~ $re);
            if ($a =~ /bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"/) { print "$1 $2 $3 $4"; exit }
        }'
}

# Prints "x y" of the first node whose text or content-desc matches the regex.
ui_find() {
    local b
    b=$(ui_box "$1")
    [ -n "$b" ] || return 0
    set -- $b
    printf '%d %d\n' $((($1 + $3) / 2)) $((($2 + $4) / 2))
}

# The on-screen keyboard swallows every tap inside its touchable region, which on a TV is the
# whole width of the lower part of the screen - far wider than the keys you can see. Empty
# when no keyboard is showing.
ime_rect() {
    A shell dumpsys window windows 2>/dev/null | tr -d '\r' | awk '
        /Window\{[^}]*InputMethod\}/ { im = 1; next }
        im && /touchable region=/ {
            if (match($0, /SkRegion\(\(-?[0-9]+,-?[0-9]+,-?[0-9]+,-?[0-9]+\)\)/)) {
                s = substr($0, RSTART, RLENGTH); gsub(/[^0-9-]/, " ", s); print s; exit
            }
        }
        /^  Window #/ { im = 0 }'
}

# A point inside "x1 y1 x2 y2" that the keyboard is not covering, so the tap reaches the app.
tap_point() {
    local x1=$1 y1=$2 x2=$3 y2=$4 r kx1 ky1 kx2 ky2 cx cy cand x y i
    cx=$(((x1 + x2) / 2)); cy=$(((y1 + y2) / 2))
    r=$(ime_rect)
    [ -n "$r" ] || { printf '%d %d\n' "$cx" "$cy"; return 0; }
    set -- $r; kx1=$1; ky1=$2; kx2=$3; ky2=$4
    for cand in "$cx $cy" "$cx $((y1 + 4))" "$cx $(((y1 + ky1) / 2))" \
                "$cx $((y2 - 4))" "$cx $(((ky2 + y2) / 2))" \
                "$((x1 + 4)) $cy" "$(((x1 + kx1) / 2)) $cy" \
                "$((x2 - 4)) $cy" "$(((x2 + kx2) / 2)) $cy"; do
        set -- $cand; x=$1; y=$2
        [ "$x" -ge "$x1" ] && [ "$x" -le "$x2" ] && [ "$y" -ge "$y1" ] && [ "$y" -le "$y2" ] || continue
        if [ "$x" -lt "$kx1" ] || [ "$x" -gt "$kx2" ] || [ "$y" -lt "$ky1" ] || [ "$y" -gt "$ky2" ]; then
            printf '%d %d\n' "$x" "$y"; return 0
        fi
    done
    # Fully covered: Tab moves focus off the control, which makes the keyboard go away.
    # Wait until it has really gone - the keyboard takes a moment to slide out, and a tap
    # sent too early lands on the keys instead of the control.
    for i in 1 2 3 4 5; do
        [ -z "$(ime_rect)" ] && break
        S input keyevent 61
        sleep 0.5
    done
    sleep 0.3
    printf '%d %d\n' "$cx" "$cy"
}

# Optional popups: look once, never scroll.
ui_tap_if() {
    local b
    b=$(ui_box "$1")
    [ -n "$b" ] || return 0
    S input tap $(tap_point $b); sleep 1.5
}

ui_tap() {
    local b
    b=$(ui_seek ui_box "$1") || return 1
    [ -n "$b" ] || return 1
    S input tap $(tap_point $b); sleep 1.5
}

# Prints "on|off x y" for the Switch sitting on the same row as the label matching the regex.
ui_switch() {
    ui_dump | LC_ALL=C perl -0ne '
        my $re = qr/'"$1"'/i; my ($top, $bot); my @sw;
        while (/<node\b([^>]*)>/g) {
            my $a = $1; my ($d) = $a =~ /\bcontent-desc="([^"]*)"/; my ($t) = $a =~ /\btext="([^"]*)"/;
            my ($x1,$y1,$x2,$y2) = $a =~ /bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"/;
            if (!defined $top && ((($d // "") =~ $re) || (($t // "") =~ $re))) { ($top, $bot) = ($y1, $y2); }
            if ($a =~ /\bcheckable="true"/) { my ($c) = $a =~ /\bchecked="(\w+)"/; push @sw, [($x1+$x2)/2, ($y1+$y2)/2, $c]; }
        }
        exit unless defined $top;
        for my $s (@sw) { if ($s->[1] >= $top && $s->[1] <= $bot) { printf "%s %d %d\n", ($s->[2] eq "true" ? "on" : "off"), $s->[0], $s->[1]; exit } }'
}

# ui_switch_set <label regex> <on|off>: scrolls to the row, flips it if needed, confirms the result.
ui_switch_set() {
    local st
    st=$(ui_seek ui_switch "$1") || return 1
    [ "${st%% *}" = "$2" ] && return 0
    S input tap ${st#* }; sleep 2
    ui_tap_if '^(OK|Confirm|Allow)$'
    st=$(ui_seek ui_switch "$1") || return 1
    [ "${st%% *}" = "$2" ]
}
ui_switch_on() { ui_switch_set "$1" on; }

# A run that stops halfway can leave the password dialog or the overflow menu open. Both sit
# on top of the rows, so every tap aimed at a row behind them silently goes nowhere.
dismiss_leftovers() {
    local i
    for i in 1 2 3; do
        [ -z "$(ui_find '^Set password$')" ] && break
        ui_tap_if '^Cancel$'
        sleep 1
    done
    [ -z "$(ui_find '^Set permanent password$')" ] || { S input keyevent 4; sleep 1; }
}

auto_settings() {
    S monkey -p $RUSTDESK -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
    sleep 6
    dismiss_leftovers
    ui_tap '^Settings&#10;Tab' || return 1
    ui_switch_on '^Start on boot' || return 1
    # The floating icon stuck to the screen edge; battery exemption + foreground service keep RustDesk alive without it.
    ui_switch_set '^Floating window' off || return 1
    ask_password
    ui_tap '^Share screen&#10;Tab' || return 1
    # On a re-run the service is already up and the button reads "Stop service".
    if [ -z "$(ui_find '^Stop service$')" ]; then
        ui_tap '^Start service$' || return 1
        accept_scam_warning
        accept_warning_ok
        accept_start_now
    fi
    set_password || return 1
    return 0
}

# The unlabeled overflow button at the top-right of RustDesk's Share screen tab.
# The app bar is a different height on every device, so measure the screen instead of
# assuming a fixed bar: any unlabeled button in the top-right corner will do.
ui_menu() {
    local box
    box=$(ui_dump | LC_ALL=C perl -0ne '
        my ($bx1, $by1, $bx2, $by2, $best) = (0, 0, 0, 0, -1);
        while (/<node\b([^>]*)>/g) {
            my $a = $1;
            next unless $a =~ /\bclass="android\.widget\.Button"/ && $a =~ /\bcontent-desc=""/;
            my ($x1,$y1,$x2,$y2) = $a =~ /bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"/;
            next unless defined $y2 && $y2 <= '"$((SH/5))"' && $x1 >= '"$((SW/2))"';
            if ($x2 > $best) { $best = $x2; ($bx1, $by1, $bx2, $by2) = ($x1, $y1, $x2, $y2); }
        }
        printf "%d %d %d %d\n", $bx1, $by1, $bx2, $by2 if $best >= 0;')
    [ -n "$box" ] || return 1
    S input tap $(tap_point $box); sleep 1.5
}

# Tap-safe points inside the text fields, one per line. The keyboard usually covers the
# lower field, so ask for a point it is not covering.
ui_fields() {
    ui_dump | LC_ALL=C perl -0ne '
        while (/<node\b([^>]*)>/g) {
            my $a = $1;
            next unless $a =~ /\bclass="android\.widget\.EditText"/;
            print "$1 $2 $3 $4\n" if $a =~ /bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"/;
        }' | while read -r x1 y1 x2 y2; do tap_point $x1 $y1 $x2 $y2; done
}

# Types one character at a time so quotes, spaces and % reach the TV unchanged.
type_text() {
    local str="$1" i=0 c q
    while [ $i -lt ${#str} ]; do
        c="${str:$i:1}"
        if [ "$c" = " " ]; then
            S input keyevent 62
        else
            q=$(printf '%s' "$c" | sed "s/'/'\\\\''/g")
            S input text "'$q'"
        fi
        i=$((i+1))
    done
}

# Permanent password, accept sessions by password only, and accept BOTH the one-time password
# and the permanent one. Tapping "Use permanent password" instead would switch one-time
# password (OTP) login off, and support sometimes needs to read the OTP off the TV screen.
set_password() {
    local f1 f2 fields
    # An earlier attempt can leave this dialog open, with the overflow menu hidden behind it.
    dismiss_leftovers
    ui_menu || return 1
    ui_tap '^Set permanent password$' || return 1
    sleep 1
    fields=$(ui_fields)
    f1=$(printf '%s\n' "$fields" | sed -n 1p)
    f2=$(printf '%s\n' "$fields" | sed -n 2p)
    [ -n "$f1" ] && [ -n "$f2" ] || return 1
    S input tap $f1; sleep 0.5; type_text "$RD_PASSWORD"; sleep 0.5
    S input tap $f2; sleep 0.5; type_text "$RD_PASSWORD"; sleep 0.5
    ui_tap_if '^OK$'   # tap_point moves the keyboard out of the way first, if it is covering OK
    sleep 2
    [ -z "$(ui_find '^Set password$')" ] || { ui_tap_if '^Cancel$'; return 1; }
    ui_menu && ui_tap '^Accept sessions via password$' || return 1
    ui_menu && ui_tap '^Use both passwords$' || return 1
    # The dialog-closing check above is what proves the password was written, and a correct
    # password otherwise gives no sign that it worked.
    ok "Permanent password is set"
    return 0
}

# Second "Warning" dialog after I Agree, with Cancel / OK.
accept_warning_ok() {
    local i
    for i in 1 2 3 4; do
        if [ -n "$(ui_find '^Warning$')" ] && [ -n "$(ui_find '^OK$')" ]; then ui_tap_if '^OK$'; return 0; fi
        sleep 2
    done
    return 0
}

# RustDesk's "You May Be Being SCAMMED!" dialog: tick "Don't show again", then "I Agree" once its countdown ends.
accept_scam_warning() {
    local i
    for i in 1 2 3 4; do [ -n "$(ui_find 'SCAMMED')" ] && break; sleep 2; done
    [ -n "$(ui_find 'SCAMMED')" ] || return 0
    ui_switch_on "^Don.t show again" >/dev/null 2>&1
    for i in 1 2 3 4 5 6 7 8 9 10; do
        ui_tap_if '^I Agree'
        sleep 3
        [ -z "$(ui_find 'SCAMMED')" ] && return 0
    done
    return 1
}

# Android's screen-capture prompt; normally skipped because PROJECT_MEDIA is allowed.
accept_start_now() {
    local i
    for i in 1 2 3; do
        [ -n "$(ui_find '^Start now$')" ] && { ui_tap_if '^Start now$'; return 0; }
        sleep 2
    done
    return 0
}

# MainService stays listed after it stops (something is still bound to it), so ask whether it
# was actually started rather than just whether the name appears.
service_running() { S dumpsys activity services $RUSTDESK | grep -qE 'startRequested=true|isForeground=true'; }

DONE=0
echo "  Working on the TV screen, please don't press anything on the remote..."
wake_screen
spinner_start "setting up RustDesk on the TV"
if auto_settings && service_running; then DONE=1; ok "done automatically"; else warn "automatic setup didn't finish, please do these steps by hand"; fi

if [ "$DONE" = 0 ]; then
    ask_password
    echo "  On the TV, open RustDesk and:"
    echo "    1. Settings > turn ON 'Start on boot' and turn OFF 'Floating window'"
    echo "    2. Open the 'Share screen' tab and press 'Start service'"
    echo "    3. Top-right menu > 'Set permanent password' (the one you typed above)"
    echo "    4. Top-right menu > 'Accept sessions via password', then 'Use both passwords'"
    pause "When all four are done,"
    service_running || die "RustDesk service is not running yet. Press 'Start service' in RustDesk, then run this again."
fi

enable_input || die "RustDesk remote control (Input control) is not active. Turn it on in RustDesk > Share screen, then run this again."
ok "RustDesk is running, with remote control"

# ---------- sign in ----------
# Chup TV opens on its email/password screen; the 6-digit code from the dashboard sits one tap
# away behind "Login with OTP". Returns 0 only once the Login button has left the screen, which
# is what reaching the home screen does -- a refused code leaves the button sitting there.
chup_signin() {
    local code="$1" field attempt wait ready
    S monkey -p $CHUPTV -c android.intent.category.LEANBACK_LAUNCHER 1 >/dev/null 2>&1

    # Let it land before reading the screen. Either login control means "not signed in yet";
    # neither appearing after this long means it went straight to the home screen. A cold
    # start on these boxes can take half a minute, so keep looking that long rather than
    # conclude "signed in" and leave the login screen sitting there for a person to click.
    ready=""
    for wait in 1 2 3 4 5 6 7 8 9 10 11 12; do
        sleep 2
        if [ -n "$(ui_find '^Login$')" ] || [ -n "$(ui_find '^Login with OTP$')" ]; then
            ready=1; break
        fi
    done
    [ -n "$ready" ] || return 0

    # Both screens carry the words "Login with OTP" -- a button on the email screen, the
    # heading on the OTP screen -- so that string tells them apart not at all. The OTP screen
    # is the one with an "OTP" label of its own and a single field. Choose it here so nobody
    # has to click it on the TV: tap, look for the OTP screen, and tap again if the first
    # tap landed while the app was still animating into place.
    for attempt in 1 2 3; do
        [ -n "$(ui_find '^OTP$')" ] && break
        ui_tap '^Login with OTP$' || break
        for wait in 1 2 3 4 5; do
            [ -n "$(ui_find '^OTP$')" ] && break
            sleep 1
        done
    done
    [ -n "$(ui_find '^OTP$')" ] || return 1

    for attempt in 1 2 3; do
        field=$(ui_fields | head -n 1)
        [ -n "$field" ] || return 1
        S input tap $field
        sleep 2
        # input text appends, so clear whatever a previous attempt left behind.
        S input keyevent 67 67 67 67 67 67 67 67 67 67 67 67
        type_text "$code"
        sleep 1
        # ui_tap measures the keyboard's own touchable region and taps somewhere it is not
        # covering, pressing Tab until it slides away if it covers the whole control. Nothing
        # to dismiss here, and no BACK that could leave the screen instead.
        ui_tap '^Login$' || return 1
        for wait in 1 2 3 4 5; do
            [ -z "$(ui_find '^Login$')" ] && return 0
            sleep 2
        done
    done
    return 1
}

bold "6/7  Sign in to Chup TV"
wake_screen
while :; do
    CHUP_CODE=$(ask_secure "Chup TV login code from the dashboard:") || die "no code entered"
    case "$CHUP_CODE" in
        *[!0-9]*) warn "the code is digits only"; continue;;
    esac
    [ ${#CHUP_CODE} -eq 6 ] && break
    warn "the code is six digits"
done
spinner_start "signing in to Chup TV"
if chup_signin "$CHUP_CODE"; then
    ok "Chup TV is signed in"
else
    spinner_stop
    warn "automatic sign-in didn't take"
    echo "  On the TV, open Chup TV and sign in with that same code:"
    echo "    1. Choose 'Login with OTP'"
    echo "    2. Enter the 6-digit code from the dashboard"
    echo "    3. Press 'Login'"
    pause "When the home screen is showing,"
fi

# The RustDesk ID, read off the TV's own screen. RustDesk puts it in an accessibility label
# at the top of its service tab -- "Your device / ID / 123 456 789 / ... / Ready" -- which is
# readable without root, unlike anything in the app's private storage. Prints the digits only.
# Returns 1 when the screen will not say it, so the caller can point at the TV instead.
rustdesk_id() {
    local dump id i tab
    S monkey -p $RUSTDESK -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
    sleep 5
    # The label lives on the service tab, which is where the setup above left it. Some builds
    # show the ID on the connection tab instead, so look on both, alternating on every pass.
    for i in 1 2 3 4 5 6 7 8; do
        dump=$(ui_dump)
        id=$(printf '%s' "$dump" | LC_ALL=C perl -0ne '
            while (/<node\b([^>]*)>/g) {
                my $a = $1;
                for my $v ($a =~ /\b(?:content-desc|text)="([^"]*)"/g) {
                    # The label is "ID" on a line of its own, with the number on the next.
                    if ($v =~ /(?:^|&#10;)ID&#10;\s*([0-9][0-9 ]{4,})/) {
                        my $n = $1; $n =~ s/\D//g; print $n and exit;
                    }
                }
            }')
        [ -n "$id" ] && { printf '%s\n' "$id"; return 0; }
        # One tab at a time: an alternation here would match the same (first) tab every pass
        # and never reach the other one.
        if [ $((i % 2)) -eq 1 ]; then tab='^Share screen&#10;Tab'; else tab='^Connection&#10;Tab'; fi
        ui_tap_if "$tab" >/dev/null 2>&1
        sleep 2
    done
    return 1
}

# 1835216533 -> "1 835 216 533", the way RustDesk writes it on the TV, so it reads aloud in
# threes. Anything not a digit is already gone by here.
group_id() {
    printf '%s' "$1" | LC_ALL=C sed -E 's/([0-9])([0-9]{3})([0-9]{3})([0-9]+)$/ \1 \2 \3 \4/; s/^ //'
}

# ---------- finish ----------
bold "7/7  Finishing"
wake_screen
# Read the ID before Chup TV takes the screen: it is the one thing Chup support needs, and the
# whole setup is wasted if it has to be hunted for afterwards.
RUSTDESK_ID=$(rustdesk_id) || RUSTDESK_ID=""
S monkey -p $CHUPTV -c android.intent.category.LEANBACK_LAUNCHER 1 >/dev/null 2>&1
ok "Chup TV app opened"

# The Chup Setup app sets CHUP_RESTART from its checkbox rather than prompting at the very end.
if [ -n "${CHUP_UI:-}" ] && [ -n "${CHUP_RESTART:-}" ]; then
    R="$CHUP_RESTART"
    echo "  Restart the TV after setup: $R"
else
    R=$(ask "Restart the TV now to check RustDesk comes back by itself? [Y/n]:")
fi
# 'no' has to count: typing it at the [Y/n] prompt used to reboot anyway, and the setup app
# sends the checkbox value as 'yes'/'no'.
case "$R" in n|N|no|No|NO) ;; *)
    A reboot
    echo "  Restarting, this takes about 2 minutes..."
    spinner_start "waiting for the TV to come back"
    sleep 60
    for i in $(seq 1 24); do
        case "$SERIAL" in *:*) NEW=$(mdns_addr "_adb-tls-connect"); [ -n "$NEW" ] && SERIAL="$NEW"; "$ADB" connect "$SERIAL" </dev/null >/dev/null 2>&1;; esac
        [ "$("$ADB" -s "$SERIAL" get-state </dev/null 2>/dev/null)" = "device" ] && break
        sleep 5
    done
    sleep 30
    if [ "$("$ADB" -s "$SERIAL" get-state </dev/null 2>/dev/null)" != "device" ]; then
        warn "Couldn't reconnect to check. Ask Chup support to try connecting with RustDesk."
    elif service_running; then
        ok "RustDesk came back by itself after the restart"
    else
        warn "RustDesk did not start by itself. Check 'Start on boot' is ON in RustDesk settings."
    fi
    ;;
esac

# The ID is the whole point of the last screen, so it gets the largest type a terminal has.
# The app reads the control line and shows it even bigger.
if [ -n "$RUSTDESK_ID" ]; then
    printf '::rustdesk-id %s\n' "$RUSTDESK_ID" >&2
    bold "All done. Read this RustDesk ID out to Chup support:"
    printf '\n\033[1m %s\033[0m\n\n' "$(group_id "$RUSTDESK_ID")"
    echo "  It is also on the TV: open RustDesk, top of the Share screen tab."
else
    bold "All done. Read out the RustDesk ID shown on the TV to Chup support."
    echo "  (Open RustDesk on the TV; the ID is at the top of the Share screen tab.)"
fi
