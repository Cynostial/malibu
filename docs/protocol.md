# Malibu protocol overview

This document records the parts of the Spectacles 2 protocol used by Malibu. It is an interoperability reference, not an official specification.

## Bluetooth transport

- Service: `0000FE45-0000-1000-8000-00805F9B34FB`
- Write characteristic: `6E400002-B5A3-F393-E0A9-E50E24DCCA9E`
- Notify characteristic: `6E400003-B5A3-F393-E0A9-E50E24DCCA9E`
- Pairing advertisement marker: ASCII `050`

Bluetooth messages use a one-byte kind followed by a 24-bit little-endian payload length and the payload. Malibu bounds frame sizes before allocating or parsing them.

## Pairing

The pairing path currently uses these Malibu commands:

| Command | Purpose |
| --- | --- |
| `80` | Exchange X25519 public keys and 16-byte nonces |
| `116` | Exchange mutual pairing proofs |
| `113` | Enable encrypted packets using fresh session nonces |
| `16` | Acknowledge the local identity |
| `115` | Associate the locally generated user identifier |

The shared packet key is the first 16 bytes of HMAC-SHA256 with the X25519 shared secret as the key and ASCII `v2` as the message.

## Packet encryption

Encrypted Bluetooth and media packets use AES-128-GCM. Each direction begins with a 16-byte session nonce that increments as a big-endian integer after every packet.

## Wi-Fi and media transfer

Command `21` asks the glasses to start a temporary WPA2 access point. Command `22` stops it. Malibu derives a stable SSID and password from the saved pairing key. The password is not stored separately or published. Changing the pairing key changes both the SSID fingerprint and password, which prevents an old iOS network profile from colliding with a new pairing.

The media service listens at `192.168.42.1:1234`. Malibu applies a persistent `NEHotspotConfiguration` as soon as the glasses start their access point, then establishes the encrypted media session and requests the clip catalogue. Video clips expose a dedicated thumbnail as file type `1` and the MP4 as file type `4` on tested hardware. Malibu fetches the thumbnail first and downloads the MP4 in bounded blocks. A failed request creates a fresh encrypted media session and retries the same block once. Partial files remain available for a later retry. Malibu does not send the storage-deletion command.

## Research status

The protocol has been validated with one 2018 Spectacles 2 Sapphire unit. Field layouts and behavior may differ across firmware versions. Compatibility reports should omit pairing keys, full serial numbers, and private media.
