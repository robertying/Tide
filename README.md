# Tide

A small macOS menu bar app for a desk setup with an external display and a TV soundbar. It does two things:

- **Dims idle external displays.** After 2 minutes without mouse or keyboard input, external displays fade to 25% of their current brightness, and fade back as soon as you return. It does not dim while an app keeps the display awake (video, calls), and if you change the brightness yourself while dimmed, it leaves your setting alone.
- **Volume keys control the soundbar.** When the Mac's audio goes to the TV over HDMI (and on to a soundbar over eARC), macOS can't change the volume. While the TV is the output, Tide takes over the volume keys and sets the soundbar's HomeKit accessory through the Homebridge UI API instead, with a volume HUD like the system one.

## Requirements

- macOS 14 or later, with the Xcode Command Line Tools (`xcode-select --install`)
- For dimming: an external display whose brightness macOS can control (the same displays that respond to the brightness keys)
- For the soundbar: a Homebridge with [homebridge-config-ui-x](https://github.com/homebridge/homebridge-config-ui-x) exposing the soundbar volume as a fan (RotationSpeed), light (Brightness) or speaker (Volume)

## Build and install

```sh
./build.sh
```

This compiles `Tide.app`, signs it with your Apple Development certificate if you have one, copies it to `/Applications`, and opens it. Rerun it after any change; it quits the running copy first. `./build.sh --no-install` only builds `build/Tide.app`.

Signing with a stable certificate matters: with an ad-hoc signature, macOS drops the Accessibility grant (and asks again for Keychain access) after every rebuild.

On first launch Tide opens its Settings window. Then:

1. Grant **Accessibility** when asked (System Settings → Privacy & Security → Accessibility). It's needed to intercept the volume keys. Dimming works without it.
2. In **Settings → Soundbar**, fill in the Homebridge address, username and password (and the two-factor secret if you use two-factor sign-in), pick the TV under **TV Audio Output**, then click **Test Connection**.
3. Turn on **Launch at Login** in the menu.

## Settings

Everything is set in the Settings window; there are no environment variables or config files.

| Setting | Default | Stored in |
|---|---|---|
| Dim external displays when idle | on | UserDefaults `dim.enabled` |
| Dim after | 120 seconds | `dim.after` |
| Dimmed brightness | 25% of the brightness before dimming | `dim.factor` |
| Fade out / fade in | 1.2 s / 0.3 s | `dim.fadeOut`, `dim.fadeIn` |
| Control the soundbar with the volume keys | on | `soundbar.enabled` |
| Homebridge address, username | none | `soundbar.url`, `soundbar.user` |
| Homebridge password, two-factor secret | none | login Keychain, service `io.ruiying.Tide` |
| TV audio output | none (any output whose name contains the chosen name) | `soundbar.device` |
| HomeKit accessory | `Soundbar Volume` | `soundbar.accessory` |
| Volume step / maximum volume | 2 / 100 | `soundbar.step`, `soundbar.max` |

The Homebridge address is the web page you sign in to, with its port (8581 by default), for example `http://hostname:8581`. UserDefaults live in the `io.ruiying.Tide` domain (`defaults read io.ruiying.Tide`). The two-factor secret is the one behind the authenticator QR code: base32, or the full `otpauth://` link. Tide generates a fresh code whenever it has to log in again.

## Menu

- Status of each part, with toggles for dimming and the soundbar
- **Pause Dimming** for 1 hour, 3 hours, or until tomorrow
- A soundbar level slider (also picks up changes from the TV remote)
- Settings, Launch at Login, Open Log (`~/Library/Logs/Tide/tide.log`), Quit

Quitting while the display is dimmed restores it first. Shift-Option-volume changes the soundbar by 1.

## Command line

The app binary also works as a CLI:

```sh
T=/Applications/Tide.app/Contents/MacOS/Tide
$T brightness          # print current brightness (0.0–1.0) of the first external display
$T brightness 0.3 1.5  # fade all external displays to 0.3 over 1.5 seconds
$T soundbar            # show output device and current soundbar level
$T soundbar 20         # also set it to 20
$T status              # idle time, display-sleep assertions, brightness
```

## Caveats

- Brightness uses `DisplayServicesSetBrightness` from Apple's private `DisplayServices` framework. It could change or break in a future macOS release.
- Tested on one setup (Apple Silicon, one external display, a TV with a soundbar). Other monitors, docks and adapters may not accept brightness changes; `Tide status` shows whether a display is found.
- If Tide is killed outright while dimmed, the brightness to return to is kept in `~/Library/Application Support/Tide/dim.state` and restored the next time it starts.
- Launch at Login doesn't restart Tide if it crashes.
- This is not the screen saver or display sleep. Set those in System Settings as usual; Tide just adds an earlier, gentler step.

## License

MIT, see [LICENSE](LICENSE).
