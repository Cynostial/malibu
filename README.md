# Malibu

**An independent iPhone app for pairing with Spectacles 2 and importing their videos directly into Photos and Files.**

Malibu communicates with the glasses over Bluetooth and their private Wi-Fi network. Pairing and importing happen locally on your iPhone, without a Snapchat account or cloud service.

> [!WARNING]
> Malibu is alpha software. Pairing and MP4 import have been verified with one 2018 Spectacles 2 Sapphire unit. Support for other frames and firmware versions still needs testing.

## What Malibu does

- Pairs directly with Spectacles 2 over Bluetooth Low Energy
- Creates and stores a fresh pairing identity in the iPhone Keychain
- Remembers the paired glasses without embedding their serial number in the app
- Authorizes the glasses once with Apple's accessory setup card
- Starts a stable private Wi-Fi network and joins it automatically when the installed app has Apple's Hotspot capability
- Keeps Bluetooth, Specs Wi-Fi, and the media session connected while Malibu is open
- Watches for new recordings and imports them without another Wi-Fi join
- Finds and downloads MP4 recordings
- Starts importing automatically whenever Malibu opens
- Resumes interrupted video downloads and retries dropped connections
- Fetches each clip's camera thumbnail before its MP4 and uses it in a circular progress portal
- Saves videos inside Malibu, in Files, and optionally in Photos
- Renames, sorts, shares, and deletes local video copies
- Shows battery level, charge state, frame color, firmware, serial number, temperature, and storage use
- Works without Snapchat during pairing and importing
- Uses no accounts, analytics, advertising, or remote services
- Leaves the original recordings on the glasses

## Compatibility

| Hardware | Status |
| --- | --- |
| Spectacles 2, Original frame, 2018 | Experimental; tested with Sapphire |
| Spectacles 2, Nico and Veronica | Untested |
| First-generation Spectacles | Unsupported |
| Spectacles 3 and newer | Unsupported |

Malibu requires an iPhone running iOS 18 or later. iOS 18 is required for Apple's one-time Bluetooth and Wi-Fi accessory authorization.

If you test another Spectacles 2 model or firmware version, please open a compatibility report. Do not include your complete serial number or pairing key.

## Installing Malibu

Malibu is not distributed through the App Store.

### Install the IPA without a Mac

1. Download the `.ipa` asset from the [latest release](../../releases/latest).
2. Install [Sideloadly](https://sideloadly.io/) on Windows or macOS.
3. Connect your iPhone and trust the computer when prompted.
4. Drag the IPA into Sideloadly, enter your Apple Account, and install it.
5. Enable Developer Mode on the iPhone if iOS requests it.
6. Trust the installed developer profile under **Settings › General › VPN & Device Management** if required.

A free Apple Account can sign and install the app, but Apple does not include the Hotspot Configuration capability in free Personal Team profiles. When iOS rejects the automatic switch, Malibu shows the exact saved network name and password with copy controls. It keeps the glasses access point and Bluetooth session alive while the user changes networks, then continues importing on return. Fully automatic import requires an Apple Developer Program profile containing the Hotspot capability. Apple's current [iOS capability table](https://developer.apple.com/help/account/reference/supported-capabilities-ios) lists Hotspot for paid Developer Program and Enterprise profiles, but not free Apple Developer profiles.

Free Personal Team profiles also expire after seven days. The app must then be signed again using the same account and bundle identifier. This is an [Apple Personal Team limitation](https://developer.apple.com/help/account/basics/about-your-developer-account).

Once Malibu is installed, pairing and importing require only the iPhone and glasses. Free-signed builds need one tap on the saved Specs Wi-Fi network for a new transfer session.

### Build from source

1. Clone this repository.
2. Open `Malibu.xcodeproj` in Xcode.
3. Select your development team and choose a unique bundle identifier.
4. Connect an iPhone running iOS 18 or later.
5. Build and run the `Malibu` scheme.

The repository also includes a manually triggered GitHub Actions workflow that produces an unsigned device IPA.

## Pairing the glasses

1. Charge the glasses and unfold them.
2. Keep them close to the iPhone.
3. Hold the glasses' only button continuously for **seven seconds**, then release it.
4. Open Malibu and tap **Pair Spectacles**.
5. Select the glasses on Apple's accessory card and tap **Set Up**.
6. Keep Malibu open while it completes the Spectacles pairing exchange and begins the first import.

Pairing mode remains available for a limited time, so tap **Pair Spectacles** shortly after releasing the button.

Malibu does not use a PIN, Snapcode, camera scan, Snapchat login, or the Bluetooth page in iOS Settings. It performs the Spectacles 2 pairing exchange directly.

## Reverse engineering

Malibu started as a Windows probe for hardware that had outlived its supported software. The protocol was recovered in layers: Bluetooth advertisements revealed the `050` pairing marker, GATT captures identified the FE45 service and UART-style characteristics, and packet traces exposed a four-byte command frame split across BLE notifications.

Static inspection of the retired client showed that command payloads and media records use protobuf. Controlled requests then mapped the X25519 exchange, proof envelope, AES-GCM session setup, access-point controls, media catalogue, thumbnail records, and MP4 byte ranges. Runtime traces through the legacy native pairing routine established the exact nonce ordering and key inputs. Those findings were reproduced independently in Python before the transport was implemented in Swift.

The implementation includes deterministic vectors for protobuf, AES-GCM, and the pairing proof path. Length checks, authenticated packets, bounded downloads, fresh nonces after reconnects, and exact final-size validation turn the recovered protocol into a client that can safely resume interrupted transfers.

The complete field maps, byte order, command sequence, cryptographic derivation, media framing, and remaining unknowns are documented in [`docs/protocol.md`](docs/protocol.md).

## Importing videos

1. Pair the glasses once with Malibu and Apple's accessory card.
2. Allow Local Network access. Photos access is optional.

After that first setup, unfold the paired glasses, keep them nearby, and open Malibu. The app authenticates and starts the same saved Wi-Fi network. With Apple's Hotspot capability it joins automatically. With free signing, Malibu presents a persistent connection card containing the network name, password, copy controls, and a Wi-Fi settings button. Select the named Malibu network and return to the app. Malibu keeps the Bluetooth and access-point session alive during that handoff and continues importing on return. It then keeps the session open while Malibu is in the foreground and checks for new recordings every 15 seconds. Recording another clip during that session does not require another Wi-Fi join. The **Check for videos** button remains available for an immediate check or retry.

iOS releases temporary accessory Wi-Fi when Malibu moves to the background. When the app becomes active again, Malibu automatically rebuilds the saved Bluetooth, Wi-Fi, and media session. This is an iOS platform rule for `joinAccessoryHotspot`, not a changing Spectacles password.

If you paired with an older Malibu build, the first launch of this version shows Apple's accessory migration card once. Approve it to give Malibu access to the already-paired glasses. Later imports join automatically.

Do not press the glasses button to start an import. A normal button press records a new 10-second video.

Imported MP4 files appear in Malibu's library and under **Files › On My iPhone › Malibu**. When Photos permission is granted, new videos are also added to the Photos library.

Tap a video to play it. Use the options button beside a video to rename, share, save, or delete the local Malibu copy. The library options menu can sort the list, refresh it, or delete all local copies. Renaming a local copy does not cause Malibu to import the same clip again under its original name.

Open the information button in the navigation bar to see live device details. Malibu reads these values over the authenticated BLE connection and never writes them to logs or sends them elsewhere.

## Known limitations

- Hardware compatibility has only been verified with one Spectacles 2 unit.
- Only MP4 video import is implemented.
- Photo import and storage management are not implemented.
- iOS requires one explicit accessory approval during setup or migration.
- Background importing is not supported because iOS releases the temporary accessory hotspot after the app leaves the foreground.
- Automatic Wi-Fi joining is unavailable with a free Personal Team profile. Malibu falls back to the Wi-Fi page and resumes after the user selects the saved network.
- Malibu stores one pairing identity at a time.
- Deleting a Malibu copy does not delete copies in Photos or recordings on the glasses.
- Builds signed with a free Apple Account expire after seven days.

## How it works

Malibu uses two connections:

1. **Bluetooth Low Energy** handles discovery, pairing, authentication, and Wi-Fi control.
2. **Wi-Fi** carries the media catalogue and encrypted video data.

During fresh pairing, Malibu performs an X25519 key exchange, completes the Spectacles proof exchange, confirms the derived session key with an encrypted response, and associates a locally generated identity with the glasses. The resulting packet key and the iOS Bluetooth identifier are stored in the iPhone Keychain.

During setup, Malibu uses `AccessorySetupKit` to authorize the glasses as one Bluetooth and Wi-Fi accessory. During a session, Malibu authenticates over Bluetooth, reads device status through the recovered protobuf commands, asks the glasses to create a WPA2 access point with credentials derived from the saved pairing, and uses `joinAccessoryHotspot` to join that approved accessory automatically. It then connects to the media service at `192.168.42.1:1234`, downloads each clip's dedicated thumbnail file, and transfers the MP4. Malibu keeps the session active with catalogue and battery requests while it remains in the foreground. If the media connection drops, Malibu creates a fresh encrypted session and resumes the partial video.

Before each connection, Malibu resolves the current Core Bluetooth identifier from the authorized `ASAccessory`. iOS can issue a different app-scoped identifier after the app is re-signed or reinstalled, so Malibu reconciles that identifier with the saved pairing instead of treating the radio as unavailable. The target also declares Apple's Hotspot Configuration capability required by `NEHotspotConfigurationManager` for the automatic Wi-Fi join. The app's provisioning profile must contain the same entitlement, which free Personal Team profiles do not.

See [`docs/protocol.md`](docs/protocol.md) for the full reverse-engineered wire specification.

## Privacy

Malibu does not require an account and does not contact a server.

Pairing data remains in the iPhone Keychain. Videos travel directly from the glasses to the iPhone and are written only to Malibu's storage and, when permitted, the Photos library.

## Contributing

Hardware reports, protocol research, documentation, and code contributions are welcome. See [`CONTRIBUTING.md`](CONTRIBUTING.md).

Never publish pairing keys, Apple credentials, complete device serial numbers, or private videos.

## License

[CPAL-1.0](LICENSE)

## Trademark notice

Malibu is an independent community project. It is not affiliated with, endorsed by, or sponsored by Snap Inc.

Spectacles, Snapchat, and their associated names and marks belong to their respective owners.
