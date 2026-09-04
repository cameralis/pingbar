# PingBar

A menu bar app for macOS. It shows the round trip time to one host, for example `42 ms`,
and updates it every second. There is no window and no Dock icon.

## Build

```sh
./build.sh          # makes build/PingBar.app
open build/PingBar.app
```

To install it:

```sh
cp -R build/PingBar.app /Applications/
```

## Use

Click the value in the menu bar to open the menu:

- Select the host: `1.1.1.1`, `8.8.8.8`, `9.9.9.9`, `apple.com`, or `Other Host...`
- `Open at Login` starts the app with the Mac.
- `Quit PingBar`

The value becomes red `-- ms` when a reply does not come in 3 seconds.

## How it works

`Sources/main.swift` starts one `/sbin/ping -i 1 -n <host>` process and reads each reply
line as it comes. The process is restarted if it stops, and also after the Mac wakes.
The host is kept in `UserDefaults` (`defaults read com.github.cameralis.pingbar host`).
