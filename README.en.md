# Everywhere

[简体中文](README.md) · **English**

Everywhere lets you set, change, or clear a paired iPhone or iPad’s simulated location from a map on macOS or Windows over USB or Wi-Fi. The mobile app can also control the host and show the location the device reports through Core Location. An experimental Bluetooth accessory mode uses iAP2 to send location updates.

> **Disclaimer**
>
> This project is for technical testing only. Do not use it for any illegal activity.

The Apple apps live in `swift/` and the Windows Qt console in `windows/`. From the repository root, run `./package.sh` to export the Apple apps or `./package-windows.ps1` from PowerShell to build the Windows x64 package.

The Mac console manages the device session. When using the mobile app as a remote, an iPhone or iPad can change only its own location. To establish that binding, connect the device over USB and enable its connection on the Mac. Later Wi-Fi connections to the same Mac reuse the binding. An unbound network client can view connection status only. Update the Mac and mobile apps together.

## Check the device’s location source

On iPhone, open the on-device location source panel (本机定位来源), tap **Start monitoring** (开始检测), and allow location access while using the app. Each Core Location sample shows `isSimulatedBySoftware` and `isProducedByAccessory` separately. The panel warns when the software simulation flag is `true` and shows **Unknown** when source information is missing. It retains the last sample and timestamp when you stop monitoring or leave the app. Monitoring works independently of the Mac.

Open **Diagnostics** at the top left of the map to see coordinates, horizontal accuracy, sample time, source flags, and network information. The home screen and diagnostics share one location subscription. Comparing Wi-Fi access points on a physical device requires an app signed with the Access Wi-Fi Information entitlement.

## Restore the device’s location

Select the target in the Mac console, or tap **Restore real location** (恢复真实定位) on the connected phone and confirm. Keep the connection active until the host acknowledges the clear request. On the target, tap the current-location button in Maps or check a fresh sample in Everywhere’s diagnostics. If the old location persists, restart the device and check again. If the request times out or the device disconnects, reconnect to the same device, refresh the list, and retry.

In Bluetooth receiver mode, **Clear Bluetooth location** removes the marker from the phone app and leaves the receiver active. In the simulator, **Clear simulator location** may leave the simulator without a new location sample.

## Choose a Mac mode and a map location

At startup, choose **Bluetooth accessory** or **Software simulation**. Software simulation lists devices found over USB and Wi-Fi. Select the target from that list. The packaged Mac app includes its own Python runtime and developer location service, so the bundled backend can set, change, and clear a location without Xcode on the target Mac. After ending the session, use the control on the right to return to mode selection.

Choose **GCJ-02** for a mainland China basemap that uses that coordinate system. Everywhere converts map selections back to WGS 84. Choose **WGS 84** for a native WGS 84 basemap. Manual entries, saved places, and coordinates sent to the device use WGS 84.

**Send a point.** On Mac, iPhone, and iPad, sending a new or replacement point opens the Location Services instructions. Tap **I understand** (我已知晓) to send the command or **Cancel** to return to the map.

**Connect a new device.** Unlock the iPhone, connect it to the Mac with a USB data cable, and select it under **Devices**. For wireless use, choose **Trust device and enable Wi-Fi**, then confirm trust on the phone. With both devices on the same LAN, unplug the cable and wait for the same device to appear over Wi-Fi. Enable Developer Mode when prompted. Preparing a matching developer image for the first time may require internet access. On iOS 17.0–17.3, a standalone tunnel also requires an existing RemotePairing record. On 17.4 and later, setup can begin over a trusted USB connection.

## Bluetooth accessory location with iAP2 (experimental)

The Mac app includes a Bluetooth client, an RFCOMM bridge, and an MFi v3 authentication provider. Its accessory certificate and matching signing key are in `Contents/Resources/asset/mfi/`. A copy of the app therefore includes a readable copy of the signing identity. An external provider can also be selected under **Authentication provider**.

1. On the Mac, choose Bluetooth mode, then **iAP2 accessory** on the device page. On the iPhone, leave **Settings → Bluetooth** open.
2. For a new phone, click **Connect new iPhone** and select it in the device panel. The Mac opens a Classic Bluetooth connection, discovers the iAP2 service, and requests authentication. Confirm any system pairing prompt. For a paired phone, select it under **Existing iPhone connections** (已有iPhone连接). Select it again to retry a failed or closed connection.
3. When the console reports that accessory authentication passed, the iPhone has accepted the identity for that session. The Mac keeps the connection open after authentication and identification. Select a point and confirm **Send map point** (发送地图选点). On the iPhone, open Maps and request the current location. The console reports authentication events, location requests, and link acknowledgments. Check an independent Core Location sample on the phone to see whether the system adopted the point.

Transmission pauses while the phone suspends its subscription and resumes when it subscribes again. After a brief disconnect the client makes up to two reconnect attempts, after 2 and 5 seconds. After reauthentication, confirm the selected point again. Sending resumes when the phone resubscribes. To change points, send the new selection on the same connection and wait for its acknowledgment. **Stop session** ends the session. Check a fresh Core Location sample to confirm recovery.

To monitor the session from the phone, open **Connection settings → Bluetooth → Phone scans Mac** and select the Mac running iAP2. An encrypted, read-only Bluetooth service reports the target, handshake, authentication, failures, and session end. This status channel requires no receiver code.

The app ships with the client, corresponding source, and license. On the build machine, `EVERYWHERE_IAP2_PYTHON` selects a Python 3.11+ interpreter with PyInstaller 6 installed. The packaged client includes its runtime. See the [iAP2 client notes](swift/Host/IAP2Client/README.md).

## Direct Bluetooth connection to the mobile app

This mode uses Everywhere’s Bluetooth Low Energy (BLE) service to place a marker on the mobile app’s own map. For system location simulation over a developer connection, use USB or Wi-Fi.

- **Mac scans phone.** On the phone, choose **Connection settings → Bluetooth → Let Mac scan this device** and keep the app in the foreground for the first connection. In the packaged Mac console, choose **Bluetooth mode → Devices → Mac scans phone**, scan, select the phone, and connect. Once the console is connected, enter the six-digit receiver code shown on the phone.
- **Phone scans Mac.** In the same Mac panel, choose **Phone scans Mac** and start advertising. Select that option on the phone, choose the host, confirm any system pairing prompt, and enter the phone’s six-digit code on the Mac.

Enable Bluetooth on both devices. The link works with USB unplugged and Wi-Fi off. Scanning lists nearby advertisers and receivers that the system reports as connected at scan time. The console also tracks disconnects for connections it holds. With both apps updated, the phone reports **Bluetooth connected** as soon as it subscribes to the service. Each coordinate update or clear has its own acknowledgment.

Newer peers negotiate NMEA GPRMC messages containing the UTC time and date, WGS 84 coordinates, a simulation mode flag, and an XOR checksum. The phone validates each message, updates the in-app marker, and sends an acknowledgment. Older peers and links with smaller payloads use the compact coordinate format. Clearing uses a separate control command.

The code applies to one receiving session. The first Mac to authenticate controls that session. The phone can continue to receive Bluetooth events delivered by the system while locked or in the background. Turning off reception or switching connection modes clears the marker and revokes the code. A force quit or system termination ends reception. Reopen the app and reconnect. Before switching backends, clear any existing session on the Mac. If the phone has already started a new receiving session, enter its new code on the Mac and clear the old session.

To check BLE delivery, send A and then B, confirm each marker on the phone, and clear it. For comparison with system location, bring the phone app to the foreground and start monitoring. Diagnostics shows the distance from the fresh system sample to the Bluetooth marker, along with horizontal accuracy. The Mac packaging script adds the Bluetooth permission description to the app.

If map landmarks appear offset from known WGS 84 coordinates, select GCJ-02 in the layer menu and pick the point again. WGS 84 is the default. Map taps and search results use the selected basemap conversion. Older favorites have no coordinate-source metadata, so reselect any saved with the wrong setting.

## Project layout

| Path | Contents |
| --- | --- |
| `asset/mfi/` | Local `certificate.p7b` and `identity.pk8` used by the Mac accessory authentication provider. Git ignores this directory. Packaging copies both files into the Mac app. |
| `asset/ios-signing/` | iOS distribution signing materials and local signing password file. |
| `swift/Sources/MacHost/` | Mac entry point. `Console/` manages the UI, `Devices/` discovers devices, `Remote/` handles remote connections, and `Bluetooth/` contains BLE and iAP2 support. |
| `swift/Host/` | iAP2 client, Bluetooth bridge, software simulation backend, packaging and iOS signing tools. |
| `swift/Apps/`, `swift/Tests/` | iOS apps, standalone diagnostics project, and module tests. |
| `windows/` | Qt console, native Bluetooth bridges, and tests. See the [Windows build guide (Chinese)](windows/README.md). |

## Export the IPA and Mac app

The build machine needs full Xcode with the iPhoneOS SDK, Python 3.11+, and PyInstaller 6.x. The software location backend pins `pymobiledevice3==11.62.0`. The app ships both Python helpers. An ad hoc build can reuse the software location helper from the latest complete export if its signature is valid and its source, dependency declarations, scripts, and CPU architecture match. Selecting an interpreter explicitly forces a rebuild. The first build installs dependencies into dedicated environments under `Build/`. To use prepared interpreters, set `EVERYWHERE_IAP2_PYTHON` and `EVERYWHERE_PORTABLE_PYTHON`. The Mac app contains the readable accessory key. The iOS distribution signing materials stay on the build machine.

Run from the repository root:

```sh
./package.sh
```

Use `./package.sh --mac-only` or `./package.sh --ios-only` for a single platform. Each single-platform build uses a separate output directory. For a full build, `Build/Everywhere/` links to the most recent successful export under `Build/Exports/`. It contains `Everywhere.ipa` for iPhone and iPad, a signed `Everywhere.app` for the build Mac’s architecture, and `Everywhere-macOS.zip`. The script extracts the ZIP and verifies the enclosed app’s signature.

For iOS distribution, place a P12 certificate and matching provisioning profile in `asset/ios-signing/`. The script reads `EVERYWHERE_IOS_P12_PASSWORD`, then the local `p12-password` file, and otherwise prompts in the terminal. The signed `Everywhere.ipa` uses the app identifier authorized by the profile. The original is `Everywhere-unsigned.ipa`. An unsigned IPA can also be exported when the signing directory is absent.

The Mac app uses ad hoc signing by default. To use an existing self-signed code-signing identity, supply its Keychain name or fingerprint. The optional path sets the parent export directory.

```sh
MAC_SIGN_IDENTITY="Your code-signing identity" ./package.sh "$HOME/Desktop/Everywhere"
```

A browser may add `com.apple.quarantine` to a downloaded ZIP, and the recipient’s extraction tool may propagate it to the app. Removing the attribute on the build machine has no effect on a later download. For public distribution with Gatekeeper developer verification, use a Developer ID Application certificate and Apple notarization. See [Apple’s distribution guide](https://developer.apple.com/developer-id/).

If a build already running in a sandbox reports `sandbox_apply: Operation not permitted`, use `EVERYWHERE_NESTED_SANDBOX=1 ./package.sh`.

## Development entry points

| Entry point | Use |
| --- | --- |
| [Swift package](swift/Package.swift) | Open in Xcode, choose `MacHost` and **My Mac**, or use SwiftPM below. The minimum macOS deployment target is 14. |
| [Everywhere mobile app](swift/Apps/Mobile/Mobile.xcodeproj) | The iPhone and iPad app for local location monitoring, host connections, and diagnostics. Installing on a physical device requires matching signing and provisioning. |
| [Modern backend](swift/Host/ModernBackend/README.md) | Set up an external Python environment, install pinned dependencies, prepare a developer device, or debug through the standalone JSONL interface. |
| [Windows Qt console](windows/README.md) | Windows connections, dependencies, builds, and tests (in Chinese). |

Run these commands from the repository root to keep build caches in a temporary directory. Starting `MacHost` leaves the device location untouched until you send a point.

```sh
swift run --package-path swift --scratch-path "${TMPDIR:-/tmp}/virtual-location-build" MacHost
swift test --package-path swift --scratch-path "${TMPDIR:-/tmp}/virtual-location-build"
```

## Set a paired device’s location directly over Wi-Fi

The advanced **Wi-Fi only (Xcode)** backend uses Xcode. Pair the device in Xcode’s Device Hub, enable Developer Mode, and confirm that developer services are available. Connect both devices to the same LAN and unplug USB. In the Mac console, open **Devices → Backend → Paired device · Wi-Fi**, refresh the wireless device list, and select the target. Use the map to set, change, or clear the location. This path works with the mobile remote app closed and the Mac remote listener off.

The project checked the `devicectl device simulate location coordinate` and `clear` commands against Xcode 27.2. The installed Xcode must provide them. The list includes paired devices that CoreDevice reports as connected over the LAN at the time of discovery. Before each command the console rechecks the UDID and connection type. After clearing, verify a new sample in diagnostics on the target.

## Connect to the remote service over the internet

On the Mac, open **Devices → Mobile remote → Network remote**, choose a TCP port (default `49372`), and start the listener. The port persists between launches. Stop the listener before changing it. Bonjour advertises the host on the LAN. Manual connections use the same TLS service.

The client must be able to reach the chosen port. For a Mac behind an IPv4 router, forward the external TCP port to the Mac’s LAN address and listening port. With public IPv6, allow inbound access to the routable address and port. With carrier-grade NAT and no inbound IPv4 mapping, use reachable IPv6 or an existing TCP forwarding endpoint. Verify reachability from an external client. The Mac panel shows local listener status.

On the phone, choose **Wi-Fi → Enter address manually** and enter the public hostname or IP, the **external TCP port**, and the pairing code supplied by the Mac. This also works over mobile data. Revoke the pairing on the Mac when needed. Only the remote service port needs forwarding. Device development connections originate locally from the Mac.

## Pick a point on the phone and apply it through the Mac

1. Run `./package.sh` from the root to build both Apple apps. Start the console with `open Build/Everywhere/Everywhere.app`.
2. Open [Mobile.xcodeproj](swift/Apps/Mobile/Mobile.xcodeproj) in Xcode and select an iPhone or iPad running iOS/iPadOS 17 or later. For first installation on hardware, configure a development team and unique bundle ID. Keep the Mac awake and the console running.
3. On the Mac, open **Devices** or click **Select device** in the bottom bar. The Mac can enable both remote transports at once. Choose one on the phone under **Connect to Mac**. For the first connection, enter the code shown by **Show pairing code** on the Mac.

   | Transport | On the Mac | On the mobile device |
   | --- | --- | --- |
   | USB | Plug in the trusted device and choose **Connect USB phone**. A single device is detected automatically. If several are attached, select the target first. | Choose USB, enter the code, enable USB reception, and keep the app in the foreground. The Mac reaches the app through local `usbmuxd`. Both peers authenticate over TLS. No IP address or separate `iproxy` installation is needed. |
   | Wi-Fi | Prepare the previously bound device and enable network remote control. To verify its wireless developer connection by address, enter the phone’s IP in the Wi-Fi backend and choose **Verify connection**. | Join the same LAN and allow Local Network access. Enter the Mac’s IP and listening port or choose a Bonjour host. An existing USB binding lets you reuse the saved pairing. |

4. Once the phone reports that it is bound to this device, search for a place, tap the map, enter coordinates, or open a favorite. Tap **Apply to this device**. Apply again to move, or tap **Restore real location** to finish. The Mac manages the session while the mobile app is in the background. On return, the phone attempts to reconnect and queries the session status.
5. Open diagnostics on the target. Compare the action time, coordinates, and horizontal accuracy. Record the first fresh sample after applying the point and the first sample showing recovery after clearing it.

Pairing credentials are stored in Keychain. **Forget this Mac** on the phone removes the local credential for the current transport. **Revoke pairing** on the Mac invalidates existing credentials for both transports. If the cable is unplugged during an active session, the result becomes unknown. Reconnect to the same device and clear before sending another point. Leaving the remote screen leaves the host session active.

### Search, favorites, and recent places

On Mac, iPhone, and iPad, search and map layers are above the map. Favorites and recent places are below the destination card. MapKit accepts place names, addresses, and landmarks. Selecting a result moves the map and updates the draft. You can name, rename, remove, or open a favorite from its map marker. The layers menu offers standard and satellite maps.

Each device stores its own favorites and 20 most recently applied distinct locations. Reusing a location moves it to the top. You can clear recent places separately. Browsing the map, selecting a point, and saving favorites all work before connecting to the Mac.

### Earlier simulator observations (before per-device binding)

In the recorded iPhone 18 Pro / iOS 27.2 simulator run, the mobile app paired with the MacHost TLS service over loopback. MacHost controlled the same simulator through `simctl`. A separate LocationProbe recorded the following samples on November 24, 2026.

| Mobile action | Probe reading (latitude, longitude) | Sample time (UTC) |
| --- | --- | --- |
| Apply the first map point | 31.25712434, 121.47370000 | 03:33:10.492 |
| Apply a second point | −33.86880000, 151.20930000 | 03:33:54.938 |
| Clear and restart monitoring | Awaiting a fresh sample. The last coordinate still showed Sydney. | Last sample at 03:34:31.340, before monitoring restarted at 03:34:49.580. |

The phone reconnected on returning to the foreground. Revoking pairing on the Mac disconnected it and prevented a new handshake with the old credentials. Bonjour discovered the Mac, but connecting by service name timed out, and connecting to the Mac’s LAN IP also failed in that environment. End-to-end verification succeeded at `127.0.0.1` on the same machine. Cross-device LAN access, the physical USB remote handshake, USB location simulation on hardware, and recovery of the actual location still require hardware verification.

The simulator run also covered map selection, naming a favorite, searching elsewhere, and reopening the favorite with its original coordinates. The USB listener reached its ready state. Xcode integration tests substituted a temporary UNIX socket for `usbmuxd` and forwarded bytes after `Connect` to a loopback TLS service. They exercised fragmented handshakes and the request/acknowledgment round trip. The physical cable, system daemon, and device location require separate checks.

## Choose a backend for a physical device

| Candidate device | Host setup and selection |
| --- | --- |
| Paired USB device visible to Xcode | Under **Devices → Backend**, choose the automatic paired USB backend, refresh, and select the device. Version 16 uses the legacy tools. For version 17 and later, the console checks for Xcode location commands before targeting the UDID. It stops if the version is unknown, pairing is invalid, or the device is no longer visible over USB. |
| iOS/iPadOS 17.4 or later | The modern USB backend is another option. Trust the device, enable Developer Mode, and confirm developer services are available. Select a Python interpreter with the pinned `pymobiledevice3` and enter the target UDID from Xcode’s device information. |
| iOS/iPadOS 16.x | Use the legacy USB backend with a matching developer image and the `libimobiledevice` 1.4.0 tools in one installation directory. The console searches `/opt/homebrew/bin` and `/usr/local/bin`. Refresh and confirm the selected device. |
| Other cases | For 17.0–17.3, try the automatic Xcode USB path. The modern Python USB helper requires 17.4 or later. These are candidate configurations in the code. Compatibility still requires verification on each physical device and OS combination. |

Select a point or enter decimal coordinates, check the target, and apply the draft. To move, submit a new draft. When finished, clear the location, keep the device connected, and inspect subsequent samples. If the host loses power or the device disconnects, reconnect and explicitly clear the same target. After restarting the console, use the most recent clear result and fresh samples to determine whether the location recovered.

The desktop and mobile clients share one session per device. If the same coordinates are submitted within two seconds of an acknowledgment, the console reuses that acknowledgment. After two seconds you can resend. Clear an unknown session after a disconnect before applying another point. The modern USB helper retries once on a connection error or timeout before it first becomes ready. It releases the channel and rechecks the USB identity before retrying. The combined wait is at most 75 seconds.

## Interpret the results

1. At the actual location A, start the independent probe. Record location permission, sample time, horizontal accuracy, and source information.
2. On the Mac, apply two clearly separated points B and C in succession. For each, record whether the probe receives a matching fresh sample. Separately record the default nearby places shown by the location picker in WeChat Moments.
3. After clearing, record when the host acknowledged the request and when the first fresh sample returned to A. Record denied permissions, stale samples, and an unchanged nearby-place list separately.

A host acknowledgment, a system location sample, and the WeChat interface each provide a different observation. The project has yet to document a device and OS combination that has passed this physical-device verification.

## Acknowledgments

Thank you to the authors and contributors of [DiPlay](https://github.com/shihabal3amri/DiPlay) for sharing the MFi accessory authentication approach that informed Everywhere’s Bluetooth accessory mode.

Thank you to the authors and contributors of [accessory-location](https://github.com/aur3l14no/accessory-location) for demonstrating how to send location updates over iAP2. Everywhere’s Bluetooth iAP2 client is adapted from their work. The [upstream notice](swift/Host/IAP2Client/NOTICE) identifies the revision and license.
