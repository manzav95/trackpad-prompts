# Edge Controls

A menu bar app for macOS 14 or later. It is off until you turn it on.

With one finger:

Each edge can be volume, brightness, tracks, or nothing. The defaults are right for volume, left for brightness, and the bottom edge for the next and previous song in Spotify or Music. Up, or a swipe to the right, raises the level or skips forward. If both Spotify and Music are open, the one in front is used.

The finger has to start in a strip about 6% of the trackpad, then slide along the edge about 3%. A finger that moves toward the centre first is the pointer. Two or more fingers are never a gesture, and nothing starts again until every finger has lifted. Sliding the whole edge changes the level by 60%. The sensitivity slider changes that.

While a slide is active the pointer stays where it was when the slide started. Nothing is sent off this Mac. Open at Login is in the capsule menu. macOS may ask you to allow that under System Settings, General, Login Items.

While a volume or brightness slide is active, a black pill with a symbol and a blue bar hangs from the notch. A track skip shows only the forward or back icon, centered. The pill stays up for the hide delay in Settings, in milliseconds.

## Run

Use Mac Terminal, the window where `swiftc` is available. From this folder:

```bash
bash build.sh
open "Edge Controls.app"
```

The menu bar icon is a capsule. Turn Edge Controls on from that menu, or from Settings. `swift test` checks the gesture rules when Xcode's XCTest is installed. A Swift install without XCTest can still build the app.

## Trackpad probe

`probe.swift` is the command-line check that confirmed the touch layout on this Mac: each finger is 96 bytes, normalized x is the float at byte 32, y is the float at byte 36, x = 0 is the left edge, and y = 0 is the bottom edge.

```bash
swiftc probe.swift -o trackpad-probe
./trackpad-probe
```
