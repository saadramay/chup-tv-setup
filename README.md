# Chup TV box setup

Sets up an Android TV box for Chup: installs the Chup TV app and RustDesk, grants the permissions
RustDesk needs for unattended remote support, and checks it comes back by itself after a restart.

## Run it (macOS)

### Chup Setup app — no terminal needed

The app is a guided walk-through: a rail on the left holds all seven steps and marks where you
are, and the right-hand side shows what to do and what the app is doing about it.

**Remote in your hand:**

1. **Turn on Developer options** — Settings > About > tap **Android TV OS build** 7 times. This is
   the one step the app cannot see from here, so it waits for you.
2. **Turn on Wireless debugging** — Settings > System > Developer options > **Wireless debugging**.
   The app watches adb's mDNS browser and moves on the instant the box appears, so there is no
   guessing whether it worked.

**Then put the remote down:**

3. **Connect to the TV** — attaches by itself. Boxes that insist on pairing first (Xiaomi and
   similar) get a code field here: type the six digits the TV is showing.
4. **Install the apps** — downloads and installs Chup TV and RustDesk and grants the permissions.
5. **Turn on remote support** — Start on boot, the permanent password (typed into a field here,
   never onto the TV) and the share-screen service.
6. **Sign in to Chup TV** — asks for the 6-digit code from the dashboard, types it in and checks
   the home screen came up.
7. **Restart and check** — reboots and waits for RustDesk to come back by itself.

From step 4 on it runs unattended, streaming into a collapsible **Activity log** at the bottom of
the window. Whatever it cannot finish is marked red in the rail with the reason, and **Run again**
retries from where it stopped. Don't touch the TV remote while steps 4 to 7 run.

Build it with only the Command Line Tools installed — no Xcode project, no Apple Developer
account:

```bash
./app/build.sh
open "app/dist/Chup Setup.app"
```

The binary is a universal arm64/x86_64 build and is **ad-hoc signed**, so it launches without
complaint on the Mac that built it. Copying the `.app` to another Mac marks it as downloaded, so
on first launch there right-click it and choose **Open** once, or run:

```bash
xattr -dr com.apple.quarantine "/path/to/Chup Setup.app"
```

### From the terminal

1. On the TV: Settings > About > tap **Build** 7 times. Then Developer options > turn on
   **Wireless debugging** (or **USB debugging** on older boxes).
2. Connect the Mac to the same Wi-Fi as the TV (or plug in a USB cable).
3. Open Terminal and run:

   ```bash
   curl -fsSL https://raw.githubusercontent.com/saadramay/chup-tv-setup/main/tv-setup.sh | bash
   ```

4. The script shows every device it can see (USB, this Wi-Fi, emulators) and asks which one is the
   TV. Enter alone chooses the first one. If the TV only offers Wireless debugging with a pairing
   code (Xiaomi and similar), type `pair` and then the 6-digit code shown on the TV. Don't touch
   the TV remote while the rest runs.
5. When RustDesk is installed and 'Start on boot' is on, the script asks for the RustDesk
   permanent password and types it into the TV itself.
6. It then asks for the 6-digit Chup TV login code from the dashboard and signs the app in,
   falling back to instructions on the TV if it does not take.

Set `RUSTDESK_PASSWORD=...` before the command to skip the password prompt. `CHUP_RESTART=no`
skips the final restart check.

### How the app drives the script

`tv-setup.sh` runs unchanged in both places. When `CHUP_UI=1` it has no terminal to read from, so
a question is written to **stderr** as `::ask [secure] <question>` and the answer is read back on
**stdin**; stdout stays a plain log, which the app renders. `secure` marks prompts whose answers
must never be logged. When `CHUP_UI` is unset it reads from `/dev/tty` exactly as before, so
`curl | bash` is unaffected.

## Files

- `tv-setup.sh`: the setup script.
- `app/`: the Chup Setup macOS app. `app/build.sh` compiles it with `swiftc` and assembles and
  signs the `.app` bundle; `app/dist/` and `app/build/` are not checked in.
- `remote-support.json`: download links. RustDesk comes from its official GitHub releases; the
  Chup TV app APK and the mirrored Android platform-tools (`adb`) are attached to this
  repository's [releases](https://github.com/saadramay/chup-tv-setup/releases).

## Releasing a new Chup TV app

1. Build the release APK in the `chup.tvapp` repository.
2. Create a release here with the APK attached, tag `chup-tv-<branch>-<version>`.
3. Update `chup_tv.<branch>.url` and `version` in `remote-support.json`.

RustDesk is AGPL-3.0 and is downloaded unmodified from https://github.com/rustdesk/rustdesk.

## Mirroring a new adb

The script uses an `adb` already on `PATH` if there is one. Otherwise it downloads
platform-tools — from this repository's release asset first, falling back to `dl.google.com`,
so an install doesn't break if Google is unreachable.

1. Download `https://dl.google.com/android/repository/platform-tools_r<VERSION>-darwin.zip`.
2. Create a release here with the zip attached, tag `platform-tools-<VERSION>`.
3. Update `platform_tools.darwin` in `remote-support.json`.
