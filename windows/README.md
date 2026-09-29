# Rainpane for Windows (experimental)

[한국어](README.ko.md)

A Windows port of Rainpane. It is much more experimental than the Mac version.

- Claude Code ported it from the Mac version in one long session. The water simulation and the shaders follow the Mac code closely. The Windows parts are new.
- I have only run it in a Windows 11 ARM virtual machine (VMware Fusion on an Apple Silicon Mac). It has never run on a real Windows PC, on an x64 machine, or with more than one monitor.
- There is no prebuilt download. You need to build it yourself.
- Expect bugs. Frame rates and CPU numbers from a VM do not say much.

## What works

- Rain falls behind your windows. The frontmost window stays dry.
- Water pools on the top edges of windows, runs down the sides, and drips from the bottom corners. Drops roll down the window glass.
- When you close or minimize a window, its water slides down the screen as a sheet. When you switch virtual desktops, the water is kept.
- The taskbar and menus hide the rain. With the taskbar at the bottom, rain splashes on its top edge.
- Mouse drops. Optional: scroll dust and keyboard drops.
- Settings window with English and Korean. Left-click the tray icon to open it.
- Optional and even more experimental: glass drops. Windows has no Liquid Glass, so this copies the screen behind the drop and bends it in a shader.

Not in the Windows version:

- Desktop switching across displays. Windows already switches all displays together.
- Desktop widgets.

## Build

Requirements: Windows 10 version 2004 or later (Windows 11 recommended), [Rust](https://rustup.rs) with the MSVC toolchain, and Visual Studio Build Tools with the C++ workload.

```sh
cd windows
cargo build --release
target\release\rainpane.exe
```

To build on a Mac, use [cargo-xwin](https://github.com/rust-cross/cargo-xwin). It downloads the Microsoft CRT and Windows SDK files, which means accepting Microsoft's license for them.

```sh
cargo install cargo-xwin
rustup target add aarch64-pc-windows-msvc   # or x86_64-pc-windows-msvc
cd windows
cargo xwin build --release --target aarch64-pc-windows-msvc
```

The app lives in the tray. It may be hidden under the ^ arrow. Left-click opens the settings. Right-click shows a menu to turn it off or quit.

## Permissions and privacy

Windows does not ask for any permission for these. This is what the app reads:

- The position, size, class name, and style of the windows on screen. It does not read window titles.
- Mouse buttons and the wheel, through Raw Input.
- Keyboard drops (off by default): only whether Return or Tab was pressed. Other keys are ignored. It reads the focused element's type, position, size, and text cursor position with UI Automation. It never reads what you type, and it does not ask for the cursor position in password fields.
- Glass drops (off by default): while a drop is on screen, it copies the screen with the Desktop Duplication API. The image stays on the GPU and is never saved. While glass drops are on, the rain window is always left out of screenshots and recordings.

It stores settings in `%APPDATA%\Rainpane\settings.json`. "Open at login" adds a value under `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`. It makes no network connections.

## How it differs from the Mac version

- Windows tells the app why a window disappeared: closed, minimized, or moved to another virtual desktop. The Mac version has to guess from the minimize animation and Mission Control.
- The rain is drawn with Direct3D 11 in a click-through, always-on-top window (DirectComposition). The Metal shaders were ported to HLSL.
- Screenshots and recordings: the rain window uses the Windows capture exclusion (`SetWindowDisplayAffinity`) instead of detecting the screenshot tool.
- The settings window uses egui with a Direct3D 11 renderer, because some Windows on ARM machines have no OpenGL.

Test options: `--debug` writes `rainpane.log` next to the exe. `--quit-after N`, `--intensity X`, `--press "x,y,down,up[,dx,dy]"`, `--glass`, `--settings`, and `--tab NAME` were used to check things in the VM without a mouse.

## License

MIT, like the rest of the project. The icons in `assets/` come from Font Awesome Free (icons: CC BY 4.0) and Microsoft Fluent Emoji (MIT). Their license files are in `assets/`.
