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

4. Type the RustDesk permanent password when asked. On boxes with a pairing code, type the
   6-digit code shown on the TV. Don't touch the TV remote while it works.

Set `RUSTDESK_PASSWORD=...` before the command to skip the password prompt.

## Files

- `tv-setup.sh`: the setup script.
- `remote-support.json`: download links. RustDesk comes from its official GitHub releases; the
  Chup TV app APK is attached to this repository's
  [releases](https://github.com/saadramay/chup-tv-setup/releases).

## Releasing a new Chup TV app

1. Build the release APK in the `chup.tvapp` repository.
2. Create a release here with the APK attached, tag `chup-tv-<branch>-<version>`.
3. Update `chup_tv.<branch>.url` and `version` in `remote-support.json`.

RustDesk is AGPL-3.0 and is downloaded unmodified from https://github.com/rustdesk/rustdesk.
