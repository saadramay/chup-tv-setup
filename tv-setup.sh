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

bold() { printf '\n\033[1m%s\033[0m\n' "$1"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }
die()  { printf '\n\033[31mStopped:\033[0m %s\n' "$1"; exit 1; }
ask()  { local a; read -r -p "  $1 " a </dev/tty; echo "$a"; }
pause() { read -r -p "  $1 Press Enter to continue..." _ </dev/tty; }

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
    while :; do
        printf '  RustDesk permanent password: ' >/dev/tty
        IFS= read -r RD_PASSWORD </dev/tty || die "no password entered"
        password_ok "$RD_PASSWORD" && break
    done
}


# ---------- adb ----------
bold "1/6  Getting adb"
if command -v adb >/dev/null 2>&1; then
    ADB=$(command -v adb)
else
    ADB="$WORK/platform-tools/adb"
    if [ ! -x "$ADB" ]; then
        curl -fsSL -o "$WORK/pt.zip" https://dl.google.com/android/repository/platform-tools-latest-darwin.zip \
            || die "could not download adb from Google"
        unzip -qo "$WORK/pt.zip" -d "$WORK" || die "could not unpack adb"
        rm -f "$WORK/pt.zip"
    fi
fi
"$ADB" start-server >/dev/null 2>&1
ok "adb ready"

# ---------- connect ----------
bold "2/6  Connecting to the TV box"
SERIAL=""

mdns_addr()  { "$ADB" mdns services 2>/dev/null | awk -v t="$1" '$0 ~ t {print $NF; exit}'; }

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

# connect_wait <addr>: connect and wait up to 2 minutes for the box to be ready.
connect_wait() {
    local addr="$1" state i
    case "$addr" in *:*) "$ADB" connect "$addr" >/dev/null 2>&1;; esac
    for i in $(seq 1 40); do
        state=$("$ADB" -s "$addr" get-state 2>&1)
        [ "$state" = "device" ] && return 0
        case "$state" in *unauthorized*)
            [ "$i" = 1 ] && warn "On the TV, tick 'Always allow from this computer' and press OK on the debugging popup (waiting up to 2 minutes)."
            # A denied popup never comes back on the same connection: reconnect every 15s to ask again.
            case "$addr" in *:*) [ $((i % 5)) = 0 ] && "$ADB" disconnect "$addr" >/dev/null 2>&1;; esac ;;
        esac
        sleep 3
        case "$addr" in *:*) "$ADB" connect "$addr" >/dev/null 2>&1;; esac
    done
    return 1
}

# pair_wireless: for boxes that only offer Wireless debugging with a pairing code (Xiaomi and friends).
# Sets ADDR and STATE.
pair_wireless() {
    local pair_addr code
    echo "  On the TV: Settings > Developer options > Wireless debugging > Pair device with pairing code"
    pause "Keep that pairing screen open on the TV."
    pair_addr=$(mdns_addr "_adb-tls-pairing")
    if [ -z "$pair_addr" ]; then
        pair_addr=$(ask "Type the IP address & Port shown on the TV pairing screen (like 192.168.1.20:37123):")
    fi
    case "$pair_addr" in
        *:*)
            code=$(ask "Type the 6-digit pairing code shown on the TV:")
            "$ADB" pair "$pair_addr" "$code" </dev/null | grep -qi "success" || die "pairing failed, check the code and try again"
            ok "paired"
            sleep 2
            ADDR=$(mdns_addr "_adb-tls-connect")
            [ -n "$ADDR" ] || ADDR=$(ask "Type the IP address & Port shown on the main Wireless debugging screen:")
            ;;
        *)
            ADDR="$pair_addr:5555"
            ;;
    esac
    STATE="new"
}

echo "  Looking for devices on this Mac and this Wi-Fi..."
# Everything adb already sees (USB, network, emulator), ready or not.
LIST=$("$ADB" devices | awk 'NR>1 && $1!="*" && NF>=2 {print $1, $2}')
# Plus boxes on this Wi-Fi with adb already open (port 5555): those need no pairing.
for ip in $(scan_adb_port); do
    echo "$LIST" | awk -v a="$ip:5555" '$1==a {found=1} END {exit !found}' \
        || LIST="$LIST
$ip:5555 new"
done

ADDR=""; STATE=""
if [ -n "$LIST" ]; then
    echo "  Devices found:"
    N=0
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
            new) label="found on this Wi-Fi";;
            *)   label="$state: press Allow on the TV";;
        esac
        printf '    %d. %-22s %-28s (%s)\n' "$N" "$addr" "$label" "$kind"
    done < <(echo "$LIST")

    PICK=$(ask "Which one is this TV? (Enter = 1, or 'pair' to use a pairing code)")
    case "$PICK" in
        p|pair) pair_wireless;;
        "")     PICK=1;;
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

if [ "$STATE" = "device" ]; then
    SERIAL=$ADDR
    ok "using $ADDR"
else
    connect_wait "$ADDR" || die "could not connect to $ADDR"
    SERIAL=$ADDR
    ok "connected ($SERIAL)"
fi

A() { "$ADB" -s "$SERIAL" "$@"; }
S() { "$ADB" -s "$SERIAL" shell "$@" </dev/null; }

MODEL=$(S getprop ro.product.model | tr -d '\r')
ANDROID=$(S getprop ro.build.version.release | tr -d '\r')
ABI=$(S getprop ro.product.cpu.abi | tr -d '\r')
ok "$MODEL, Android $ANDROID, $ABI"

# ---------- download ----------
bold "3/6  Downloading apps"
MANIFEST="$WORK/remote-support.json"
curl -fsSL -o "$MANIFEST" "$REMOTE_SUPPORT_JSON" 2>/dev/null || cp "${REMOTE_SUPPORT_JSON#file://}" "$MANIFEST" 2>/dev/null \
    || die "could not read $REMOTE_SUPPORT_JSON"
RD_URL=$(plutil -extract "builds.$ABI" raw -o - "$MANIFEST" 2>/dev/null)
[ -n "$RD_URL" ] || die "no RustDesk build listed for $ABI"
curl -fL --progress-bar -o "$WORK/rustdesk.apk" "$RD_URL" || die "RustDesk download failed"
ok "RustDesk"

if [ -n "$LOCAL_CHUP_APK" ]; then
    [ -f "$LOCAL_CHUP_APK" ] || die "file not found: $LOCAL_CHUP_APK"
    cp "$LOCAL_CHUP_APK" "$WORK/chup-tv.apk"
else
    CHUP_TV_APK_URL=$(plutil -extract "chup_tv.$CHUP_TV_BRANCH.url" raw -o - "$MANIFEST" 2>/dev/null)
    [ -n "$CHUP_TV_APK_URL" ] || die "no Chup TV app listed for '$CHUP_TV_BRANCH'"
    curl -fL --progress-bar -o "$WORK/chup-tv.apk" "$CHUP_TV_APK_URL" || die "Chup TV app download failed ($CHUP_TV_APK_URL)"
fi
ok "Chup TV app"

# ---------- install + grants ----------
bold "4/6  Installing and granting permissions"
A install -r -g "$WORK/chup-tv.apk" | grep -q Success || die "Chup TV app install failed"
ok "Chup TV app installed"
A install -r -g "$WORK/rustdesk.apk" | grep -q Success || die "RustDesk install failed"
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
bold "5/6  RustDesk settings (Start on boot, password, start service)"

SIZE=$(S wm size | tr -d '\r' | awk '/Physical/{print $3}')
SW=${SIZE%x*}; SH=${SIZE#*x}
case "$SW$SH" in *[!0-9]*|"") SW=1280; SH=720;; esac
SWIPE="$((SW/2)) $((SH*3/4)) $((SW/2)) $((SH/4))"

ui_dump() { S uiautomator dump /sdcard/chup-ui.xml >/dev/null 2>&1; A exec-out cat /sdcard/chup-ui.xml 2>/dev/null; }

# Prints "x y" of the first node whose text or content-desc matches the regex.
ui_find() {
    ui_dump | LC_ALL=C perl -0ne '
        my $re = qr/'"$1"'/i;
        while (/<node\b([^>]*)>/g) {
            my $a = $1;
            my ($t) = $a =~ /\btext="([^"]*)"/; my ($d) = $a =~ /\bcontent-desc="([^"]*)"/;
            next unless (($t // "") =~ $re) || (($d // "") =~ $re);
            if ($a =~ /bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"/) { printf "%d %d\n", ($1+$3)/2, ($2+$4)/2; exit }
        }'
}

# Optional popups: look once, never scroll.
ui_tap_if() {
    local xy
    xy=$(ui_find "$1")
    [ -n "$xy" ] && { S input tap $xy; sleep 1.5; }
    return 0
}

ui_tap() {
    local xy i
    for i in 1 2 3 4 5; do
        xy=$(ui_find "$1")
        if [ -n "$xy" ]; then S input tap $xy; sleep 1.5; return 0; fi
        S input swipe $SWIPE 300; sleep 1
    done
    return 1
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
    local st i
    for i in 1 2 3 4 5 6; do
        st=$(ui_switch "$1")
        if [ -n "$st" ]; then
            [ "${st%% *}" = "$2" ] && return 0
            S input tap ${st#* }; sleep 2
            ui_tap_if '^(OK|Confirm|Allow)$'
            st=$(ui_switch "$1")
            [ "${st%% *}" = "$2" ]; return $?
        fi
        S input swipe $SWIPE 300; sleep 1
    done
    return 1
}
ui_switch_on() { ui_switch_set "$1" on; }

auto_settings() {
    S monkey -p $RUSTDESK -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
    sleep 6
    ui_tap '^Settings&#10;Tab' || return 1
    ui_switch_on '^Start on boot' || return 1
    # The floating icon stuck to the screen edge; battery exemption + foreground service keep RustDesk alive without it.
    ui_switch_set '^Floating window' off || return 1
    ask_password
    ui_tap '^Share screen&#10;Tab' || return 1
    ui_tap '^Start service$' || return 1
    accept_scam_warning
    accept_warning_ok
    accept_start_now
    set_password || return 1
    return 0
}

# The unlabeled overflow button at the top-right of RustDesk's Share screen tab.
ui_menu() {
    local xy
    xy=$(ui_dump | LC_ALL=C perl -0ne '
        my ($bx, $by, $best) = (0, 0, -1);
        while (/<node\b([^>]*)>/g) {
            my $a = $1;
            next unless $a =~ /\bclass="android\.widget\.Button"/ && $a =~ /\bcontent-desc=""/;
            my ($x1,$y1,$x2,$y2) = $a =~ /bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"/;
            next unless $y2 <= 70;
            if ($x2 > $best) { $best = $x2; $bx = ($x1+$x2)/2; $by = ($y1+$y2)/2; }
        }
        printf "%d %d\n", $bx, $by if $best >= 0;')
    [ -n "$xy" ] || return 1
    S input tap $xy; sleep 1.5
}

# Centers of the text fields on screen, one per line.
ui_fields() {
    ui_dump | LC_ALL=C perl -0ne '
        while (/<node\b([^>]*)>/g) {
            my $a = $1;
            next unless $a =~ /\bclass="android\.widget\.EditText"/;
            printf "%d %d\n", ($1+$3)/2, ($2+$4)/2 if $a =~ /bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"/;
        }'
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

# Permanent password, accept sessions by password only, use the permanent password.
set_password() {
    local f1 f2
    ui_menu || return 1
    ui_tap '^Set permanent password$' || return 1
    sleep 1
    f1=$(ui_fields | sed -n 1p); f2=$(ui_fields | sed -n 2p)
    [ -n "$f1" ] && [ -n "$f2" ] || return 1
    S input tap $f1; sleep 0.5; type_text "$RD_PASSWORD"; sleep 0.5
    S input tap $f2; sleep 0.5; type_text "$RD_PASSWORD"; sleep 0.5
    ui_tap_if '^OK$'
    sleep 1
    [ -z "$(ui_find '^Set password$')" ] || { ui_tap_if '^Cancel$'; return 1; }
    ui_menu && ui_tap '^Accept sessions via password$' || return 1
    ui_menu && ui_tap '^Use permanent password$' || return 1
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

service_running() { S dumpsys activity services $RUSTDESK | grep -q "MainService"; }

DONE=0
echo "  Working on the TV screen, please don't press anything on the remote..."
if auto_settings && service_running; then DONE=1; ok "done automatically"; else warn "automatic setup didn't finish, please do these steps by hand"; fi

if [ "$DONE" = 0 ]; then
    ask_password
    echo "  On the TV, open RustDesk and:"
    echo "    1. Settings > turn ON 'Start on boot' and turn OFF 'Floating window'"
    echo "    2. Open the 'Share screen' tab and press 'Start service'"
    echo "    3. Top-right menu > 'Set permanent password' (the one you typed above)"
    echo "    4. Top-right menu > 'Accept sessions via password', then 'Use permanent password'"
    pause "When all four are done,"
    service_running || die "RustDesk service is not running yet. Press 'Start service' in RustDesk, then run this again."
fi

enable_input || die "RustDesk remote control (Input control) is not active. Turn it on in RustDesk > Share screen, then run this again."
ok "RustDesk is running, with remote control"

# ---------- finish ----------
bold "6/6  Finishing"
S monkey -p $CHUPTV -c android.intent.category.LEANBACK_LAUNCHER 1 >/dev/null 2>&1
ok "Chup TV app opened"

R=$(ask "Restart the TV now to check RustDesk comes back by itself? [Y/n]:")
case "$R" in n|N) ;; *)
    A reboot
    echo "  Restarting, this takes about 2 minutes..."
    sleep 60
    for i in $(seq 1 24); do
        case "$SERIAL" in *:*) NEW=$(mdns_addr "_adb-tls-connect"); [ -n "$NEW" ] && SERIAL="$NEW"; "$ADB" connect "$SERIAL" >/dev/null 2>&1;; esac
        [ "$("$ADB" -s "$SERIAL" get-state 2>/dev/null)" = "device" ] && break
        sleep 5
    done
    sleep 30
    if [ "$("$ADB" -s "$SERIAL" get-state 2>/dev/null)" != "device" ]; then
        warn "Couldn't reconnect to check. Ask Chup support to try connecting with RustDesk."
    elif service_running; then
        ok "RustDesk came back by itself after the restart"
    else
        warn "RustDesk did not start by itself. Check 'Start on boot' is ON in RustDesk settings."
    fi
    ;;
esac

bold "All done. Read out the RustDesk ID shown on the TV to Chup support."
