# Contributing

Thanks for helping improve Peeklet. Bug reports and small, focused changes are welcome.

## Build and test

Peeklet requires macOS 13 or later and the Xcode Command Line Tools. From the repository root:

```bash
bash build.sh
.build/Peeklet.app/Contents/MacOS/Peeklet --self-test
python3 audit.py --bundle .build/Peeklet.app
```

For an Apple Silicon and Intel universal build, run `PEEKLET_ARCH=universal bash build.sh`.

Please describe what changed and how you tested it in your pull request. If a check cannot be run, say so rather than assuming it passed.

## Keep test data safe

Use synthetic images created specifically for testing. Do not commit personal photos, private file paths, logs containing personal data, credentials, app containers, generated binaries, or build outputs. Do not add networking or expanded permissions without explaining the need and the privacy implications.

For sensitive security reports, see [SECURITY.md](SECURITY.md).
