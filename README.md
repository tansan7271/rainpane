# Rainpane

[한국어](README.ko.md)

A macOS menu bar app that makes it rain on your screen. Water pools on the top edges of your windows, runs down their sides, and drips from the corners.

## Inspired by Weatherling

Rainpane is based on the idea of [Weatherling](https://apps.apple.com/app/weatherling/id6813641198) by Matt Senter. I liked it and wanted to see how far I could rebuild the app my own way with Claude Code.

- Rainpane is an independent reimplementation. It contains no code or assets from Weatherling and is not affiliated with it.
- I made it for fun and to learn. It is not meant to compete with Weatherling or to infringe on its rights.
- Weatherling runs in the App Sandbox and asks for no permissions. Rainpane uses private macOS APIs and was only optimized as far as I needed. If you want a polished app, please buy Weatherling and support the developer who came up with the idea.
- If you are the developer of Weatherling and want anything changed or removed, please open an issue. I will change or remove it.

## Features

- Rain falls behind your windows. The frontmost window stays dry, and windows further back get more rain.
- Water pools on the top edges of windows, flows around the corners, runs down the sides, and drips from the bottom corners.
- When you close, minimize, or hide a window, its water slides down the screen as a sheet.
- Droplets roll down the window glass. Desktop widgets collect water too.
- Clicking makes a water drop. It spreads while you hold the button. Small droplets fly off when you press and again when you release. On macOS 26 or later the drop uses Liquid Glass.
- Optional: Keyboard drops. Water splashes when you press Return or Tab.
- Optional: switch desktops on all displays together. When one display moves to desktop N, the other displays follow.
- English and Korean UI.

## Requirements

- macOS 15 or later. I have only tested it on an Apple Silicon Mac running macOS 27.
- Xcode or the Command Line Tools (Swift 6).

## Build and run

```sh
git clone https://github.com/tansan7271/rainpane.git
cd rainpane
./setup-signing.sh   # Optional, once. Creates a local self-signed certificate so permissions survive rebuilds.
./build.sh run
```

The app lives in the menu bar. Left-click opens the settings. Right-click turns the rain on or off.

## Permissions and privacy

With the default settings, Rainpane asks for no permissions.

- It reads the position and size of the windows on screen (`CGWindowListCopyWindowInfo`). It does not read window titles and does not need Screen Recording permission.
- It watches mouse clicks to place the water drop. This needs no permission.
- Keyboard drops and desktop switching are off by default. Turning either one on asks for Accessibility permission.
  - Keyboard drops react only to Return and Tab. They read only the focused element's type, position, size, and text cursor position. They never read what you type, and they skip password fields.
  - Desktop switching reads which desktop each display shows and presses the macOS "Switch to Desktop N" shortcut for the other displays. If those shortcuts are off, a button in the settings can turn them on. Rainpane changes your keyboard settings only when you press that button.
- It makes no network connections. Settings are stored in the app's own preferences.

## Private APIs

These can stop working after a macOS update.

- SkyLight `SLSCopyManagedDisplaySpaces`: reads the desktops of each display (desktop switching).
- Liquid Glass filter values on private Core Animation layers: makes the glass drop fully clear.
- `com.apple.symbolichotkeys` and `activateSettings -u`: used only when you press the button that turns on the desktop shortcuts.

## How it was made

This project was fully vibe-coded. I described what I wanted, mostly with screenshots and notes on how it felt. Claude Code wrote all of the code. The code comments and the design notes in [ARCHITECTURE.md](ARCHITECTURE.md) are in Korean because that is the language we worked in. The design notes have an English translation in [ARCHITECTURE.en.md](ARCHITECTURE.en.md). The Korean version is the original.

Limitations:

- I did not write the code, and I have not reviewed all of it line by line. Expect rough edges.
- Performance work stopped at "good enough on my Mac". A transparent full-screen overlay redrawn at 60 fps has a constant system cost. On my M1 Pro with two 4K displays, Rainpane uses about 17% CPU while it rains. Settings → Speed has options to lower it.
- Optimizations I skipped: the drawing and the window list reads run on the main thread. A separate render thread would help when many windows move at once.
- I have only tested it on my own setup.
- Some behavior depends on guesses about macOS internals, such as the minimize animation and Mission Control. It can misfire.

## License

MIT. See [LICENSE](LICENSE).

The files in `Resources/` are third-party and keep their own licenses:

- Font Awesome Free (font: SIL OFL 1.1, icons: CC BY 4.0). See `Resources/FontAwesome-LICENSE.txt`.
- Microsoft Fluent Emoji (MIT). See `Resources/FluentEmoji-LICENSE.txt`.
