# Building Ghosted with xtool

xtool is installed at `~/.local/bin/xtool`. The Apple Developer account is already
authenticated, but the iOS SDK is not installed yet. No app or IPA has been produced.

## Install the iOS SDK

Download `Xcode.xip` from Apple's developer downloads while signed in with your Apple ID.
Then install the Darwin/iOS SDK from the downloaded Xcode archive:

```bash
xtool sdk install /path/to/Xcode.xip --slim
xtool sdk status
```

The `--slim` option uses less disk space. Use a Swift toolchain version supported by the
installed xtool release; its Linux installation guide currently specifies Swift 6.4.

## Build and sign Ghosted

From the repository root, build a signed IPA:

```bash
xtool dev build --sign --ipa
```

The command requires the SDK above and the existing Apple Developer authentication.
For device installation, connect and trust the iPhone and ensure `usbmuxd` is installed
and running.

## Environment notes

- The last attempt in this container failed before producing an app:
  `epoll_ctl(...): Operation not permitted`. This is a container restriction encountered
  by xtool's networking runtime. If it persists after installing the SDK, run the build
  on a Linux host where xtool is permitted to use epoll.
- Ghosted's device backend is not implemented yet. A successfully signed and installed
  build does not mean location simulation works; the app currently reports the missing
  device backend rather than silently claiming a location stream is active.
