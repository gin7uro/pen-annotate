DO NOT INSTALL - WIP

# Pen Annotate — a KOReader plugin for stylus ink annotations

Draw freehand ink annotations directly on document pages in
[KOReader](https://koreader.rocks/), using an **active stylus** such as the
Supernote pen on a Nomad or Manta. Finger touches are left completely alone,
so normal page turning, tapping menus, and every other gesture keeps working
exactly as before, even while pen drawing is turned on.

## How it distinguishes the pen from your finger

KOReader's input layer reports every touch contact tagged with a *tool
type* (finger, pen, eraser, highlighter) when the underlying platform
supports it. This plugin registers with `Device.input:registerStylusCallback()`,
an API that hands it **only** contacts tagged as a stylus, before they ever
reach KOReader's normal touch/gesture handling. That means:

- Drawing only ever happens from genuine pen contact, never from a finger.
- While "Draw with pen" is enabled, your finger can still swipe/tap to turn
  pages, open the menu, etc. — only the pen's strokes get intercepted.
- If your pen has a side button that KOReader maps to an eraser/highlighter
  tool, switching the button switches mode in this plugin too.
- If it doesn't (e.g. the Supernote pen has no side buttons), use the
  **Tool** menu (or bind gestures to it via the Dispatcher) to switch
  between Pen, Highlighter and Eraser manually.

This depends on the Android/Linux input layer actually reporting the
Supernote pen as a distinct tool (as it does for most EMR/Wacom-style
styluses, e.g. on Kobo Elipsa, reMarkable, and Android devices in general).
If "Draw with pen" is grayed out in the menu, your build isn't exposing that
information yet — `registerStylusCallback` itself is polyfilled in pure Lua
(see `lib/input_stylus_hook.lua`) for KOReader builds that don't ship it
natively, so this only happens if the platform truly never tags the pen.

## Low-latency ink on Supernote devices

On Supernote hardware, `lib/supernote_ink.lua` talks directly to the
firmware's own ink-rendering service (over a raw Android Binder call, no
koreader-base or launcher patch required) so strokes appear instantly
instead of waiting on KOReader's normal e-ink repaint. It's on by default;
toggle **Pen annotations → Low-latency Supernote ink** off if a firmware
update ever makes it misbehave. It's a no-op on every other device.

## Installation

1. Copy the `penannotate.koplugin` folder into KOReader's `plugins/`
   directory on your device (e.g. via USB, or the built-in file manager +
   an archive tool):
   ```
   koreader/plugins/penannotate.koplugin/
   ```
2. Restart KOReader.
3. Open a book, then go to the main menu → **Pen annotations**.

### Notes for Supernote Nomad / Manta

Supernote devices run a custom Android-based OS. KOReader itself isn't
officially published for Supernote hardware, so you'll typically be running
a community/sideloaded Android build of KOReader (the generic `.apk`
release, or a build shared by the KOReader-on-Supernote community). Once
KOReader is running:

- Copy this plugin into the `plugins/` folder inside KOReader's data
  directory on the device (commonly under `.../koreader/plugins/`).
- Use the Supernote pen as usual — no special pairing is required, it's
  recognized the same way any other stylus is.
- If drawing doesn't appear, check **Pen annotations → About pen
  annotations** in the menu, and confirm "Draw with pen" isn't grayed out.

## Usage

- **Main menu → Pen annotations → Draw with pen** — toggle drawing mode.
  You can also bind this to a gesture or hardware button via *More tools →
  Taps and gestures → Dispatcher* (action: "Pen annotate: toggle draw mode").
- **Tool** — pick **Pen**, **Highlighter** or **Eraser** as the active tool.
  This is what you use to switch modes if your stylus has no side buttons
  (e.g. the Supernote pen): a pen with a wired eraser/highlighter button
  still overrides this while held, but with no buttons the menu selection
  is what's used. Each tool choice can also be bound to its own
  gesture/button via the Dispatcher (actions: "Pen annotate: switch to
  pen/highlighter/eraser"), so you can flip tools without opening the menu.
- **Show tool picker popup** — opens a small popup dialog (Pen /
  Highlighter / Eraser / drawing on-off) instead of the full menu tree.
  Bind it to a gesture or hardware button via the Dispatcher (action:
  "Pen annotate: show tool picker") for one-tap tool switching, e.g. a
  corner tap or a shortcut on devices without pen side buttons.
- **Pen color / Pen width / Highlighter width / Eraser size** — adjust ink
  appearance and each tool's stroke/erase size independently.
- **Undo last stroke / Clear this page / Clear all** — manage existing ink.
  Undo can also be bound to a gesture or hardware button via the Dispatcher
  (action: "Pen annotate: undo last stroke").

Annotations are saved automatically with the book (in KOReader's per-book
sidecar settings) and reappear next time you open it.

## Troubleshooting: no pen strokes are registering at all

This plugin relies on `Device.input:registerStylusCallback()`, which was only
added to mainline KOReader recently, plus a matching fix in `koreader-base`
that reads the Android `MotionEvent` tool type so pen contacts are actually
tagged as a stylus instead of a finger. Both pieces need to be present in
your build for any of this to work:

1. Enable **Help → Enable debug logging** (or equivalent in your build), try
   drawing with the pen, then look at `koreader/crash.log` (or the on-screen
   log viewer) for lines starting with `PenAnnotate:`.
2. `PenAnnotate: stylus API available = false` means your KOReader build
   predates `registerStylusCallback` entirely — "Draw with pen" will be
   grayed out, and you need a newer build.
3. If it logs `true` but you **never** see `PenAnnotate: onStylusSlot`
   lines while actively touching the screen with the pen, the callback is
   never being invoked — meaning the platform itself never tags the
   contact as a stylus (tool type stays "finger"), so KOReader has no way
   to distinguish it from a plain touch, and every attempted stroke is
   instead handled as a normal tap/swipe (page turns, menu opens, etc.).

If you're on case 3, that points to the Supernote's Android build not
surfacing `AMOTION_EVENT_TOOL_TYPE_STYLUS` for its pen through the standard
input path that any third-party app (including KOReader) can read — this
appears to be a genuine platform limitation, not something a plugin can work
around. Notably, the only known working pen support for KOReader on
Supernote ([plateaukao's fork](https://github.com/plateaukao/koreader/releases/tag/supernote-eink-v1))
does *not* rely on Android's normal touch input at all: its release notes
say ink is read straight from the firmware's own `service_myservice` binder
service and explicitly mention that an "all-Lua plugin variant didn't ship"
for that reason. That requires native code changes in `koreader-base` and
the Android launcher, which is out of reach for a drop-in `.koplugin` like
this one. If your log confirms case 3, the options are: petition upstream
KOReader/koreader-base to add a proper Supernote input bridge, or install a
build that already has one.

## Limitations

- Ink coordinates are stored in unscaled page-pixel space, so they stay
  correctly positioned across zoom/pan for fixed-layout documents (PDF,
  DjVu, CBZ, scanned books).
- For reflowable documents (EPUB, FB2, ...), ink is anchored to the screen
  position at the time it was drawn, and may drift if you later change
  fonts, margins, or other layout settings.
- The eraser removes whole strokes that pass near the contact point, rather
  than erasing individual pixels.
- Drawing quality is intentionally simple (stamped filled squares along the
  stroke path) since KOReader's Lua drawing API only exposes rectangle
  fills — good enough for markup, not meant to replace a full drawing app.
