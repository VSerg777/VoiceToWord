# Vosk Word Listener for macOS

`macos/VoskMac` contains the native Swift app. It uses the same offline Russian
Vosk model as the Windows application. Recognition runs locally.

## Build

On macOS with Xcode Command Line Tools installed, run:

```sh
macos/VoskMac/build.sh
```

This creates `macos/VoskWordListener.app` and
`macos/VoskWordListener-macOS-universal.zip`. The app bundle includes the
universal Vosk library; download the Russian model separately. The app supports
Apple silicon and Intel Macs running macOS 12 or later.

## First launch

The app is ad-hoc signed, not notarized with an Apple Developer ID. After
unzipping, Control-click the app, choose **Open**, then confirm the macOS
warning. Grant Microphone permission to recognize speech and Accessibility
permission in System Settings → Privacy & Security to type in other apps. After
allowing Accessibility, restart the app.

Choose the extracted Vosk model folder containing `am/final.mdl`, select a
microphone, and choose a destination app in **Куда вставлять текст**. Put the
cursor in an editable field in that app, then start dictation. The active-field
option remains available. `Control` + `Option` + `D` toggles listening; the
app's buttons also start and stop it. Punctuation, line breaks, literal speech,
undo, deletion, and unique phrase replacement are supported.

The Render build copies `macos/VoskMac/README-RU.md` to the website output and
serves the Mac app from the v1.4.0 GitHub release asset.
