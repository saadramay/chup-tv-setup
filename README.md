# Chup TV box setup

Sets up an Android TV box for Chup: installs the Chup TV app and RustDesk, grants the permissions
RustDesk needs for unattended remote support, and checks it comes back by itself after a restart.

## Run it (macOS)

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

Set `RUSTDESK_PASSWORD=...` before the command to skip the password prompt.

## Files

- `tv-setup.sh`: the setup script.
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
