# Contributing to Malibu

Thank you for helping make older camera hardware useful and interoperable.

## Compatibility reports

Please include:

- Spectacles generation and frame style
- Approximate purchase year
- iPhone model and iOS version
- The step that failed
- The exact Malibu error message
- Relevant logs with personal identifiers removed

Never publish pairing keys, Apple credentials, complete device serial numbers, or private videos.

## Code contributions

1. Open an issue describing the change or compatibility problem.
2. Fork the repository and create a focused branch.
3. Keep protocol parsing bounded and validate all lengths before reading data.
4. Test changes against recorded protocol vectors when hardware is unavailable.
5. Explain the hardware and iOS versions used for physical testing.

Contributions are distributed under CPAL-1.0. Preserve the copyright and attribution notices required by [`LICENSE`](LICENSE), including the launch-time credit to Leon M'laiel (Cynostial).
