# OReader ⇄ KOReader Sync bridge

Reading-position sync for **old Android e-ink readers** that cannot run KOReader.

KOReader's Android build requires **Android 4.3 (API 18)** or newer, so it simply
cannot be installed on devices that are stuck on Android 2.x. This project brings
KOReader Sync (kosync) support to those devices anyway: it reads the position from
**AlReader / OReader**, converts it into a **KOReader-style EPUB XPointer**, and
exchanges it with any KOReader Sync server.

Primary target and the device this was developed and tested on:

- **Onyx Boox i63ML Newton** — Android 2.3.1 (API 9), OReader / AlReader
  (`com.neverland.oreader`)

The other side of the sync in testing was an **Xteink X4** running CrossPoint
firmware (a KOReader Sync client).

---

## How it works

```
AlReader DB (RLIST: POS, SZ)
        │
        │  bookpos: parse EPUB → node table → XPointer
        ▼
/body/DocFragment[13]/body/p[1]/text()[1].50
        │
        │  kosync.sh: HTTP PUT/GET with x-auth-user / x-auth-key
        ▼
KOReader Sync server  ⇄  KOReader / CrossPoint device
```

1. **AlReader / OReader** stores the position in
   `/data/data/com.neverland.oreader/databases/alreader.db`, table `RLIST`:
   `POS` — character offset in the book, `SZ` — total text length.
2. **`bookpos`** (small C program, built on the device's side) parses the EPUB,
   builds a table of nodes (spine fragment → element path → codepoint offsets)
   and converts `POS` ⇄ KOReader XPointer.
3. Because AlReader and `bookpos` count text slightly differently (`SZ` vs the
   model total), offsets are rescaled between the two coordinate spaces.
4. **`kosync.sh`** talks to the sync server over plain HTTP. `x-auth-key` is
   `md5(password)`, exactly like KOReader does.
5. The **Android app** wraps the script: shows the local and server progress
   *before* any action, has a settings screen (server, user, password) and asks
   for confirmation before writing anything.

---

## Requirements

### Device

- Android **2.3+** (tested on 2.3.1 / API 9), ARMv7
- **Root** (`su`) — reading the reader database and writing progress requires it
- Wi-Fi; **plain HTTP only** — the busybox shipped with Android 2.3 has no TLS,
  so the sync server must be reachable over `http://`

### Reader

- **AlReader / OReader**, package `com.neverland.oreader`
  (the stock `/system/app/AlReader.apk` on Onyx Boox is this app)
- **EPUB** books. FB2 is not supported by the XPointer mapper

### Binaries on the device

- `sqlite3` — static ARM build (used to read/write `alreader.db`)
- `bookpos` — static ARM build of `device/bookpos.c`

Both go to `/data/local/tmp/` and must be executable.

### Sync server

Any KOReader Sync (kosync) server, for example a self-hosted one or a public
service. The app/script needs: server URL, username, password
(the password is hashed to `md5` locally).

### Other reading device

KOReader itself, or firmware that speaks KOReader Sync and KOReader XPointers —
e.g. **CrossPoint** on Xteink X4/X3.

### Build tools (only if you want to rebuild)

- `zig` — cross-compile `bookpos` for ARM
- Android build-tools (`aapt`, `zipalign`), `dx`, Eclipse compiler (`ecj`),
  JDK 8 — for the APK (`app/build.ps1`)

---

## Installation

1. **Copy the helper binaries** to the device and make them executable:

   ```sh
   adb push sqlite3 /data/local/tmp/sqlite3
   adb push bookpos /data/local/tmp/bookpos
   adb shell su -c "chmod 755 /data/local/tmp/sqlite3 /data/local/tmp/bookpos"
   ```

2. **Install the sync script:**

   ```sh
   adb push device/kosync.sh /data/local/tmp/kosync.sh
   adb shell su -c "chmod 755 /data/local/tmp/kosync.sh"
   ```

3. **Create the settings file** from the example (it is read by the script and
   can also be written by the app's Settings screen):

   ```sh
   adb shell su -c "mkdir -p /sdcard/oreader-kosync"
   adb push device/kosync.conf.example /sdcard/oreader-kosync/kosync.conf
   ```

   Then edit it:

   ```sh
   SERVER='http://your-sync-server'
   AUTH_USER='your_username'
   AUTH_KEY='md5_of_your_password'
   ```

4. **(Optional) Build and install the app:**

   ```powershell
   powershell -ExecutionPolicy Bypass -File app\build.ps1 -Install
   ```

   The build script expects Android build-tools, `ecj`, `dx` and JDK 8; adjust
   the paths at the top of `build.ps1` to your machine.

---

## Usage

### From the app

- The main screen shows the current book, the local percentage and the
  **server** percentage (with the device name and the time of the last write).
- **Отправить / Send** — writes the current local position to the server.
- **Загрузить / Pull** — applies the server position locally (asks for
  confirmation and shows both percentages).
- **Настройки сервера / Server settings** — URL, username, password
  (the app computes `md5` itself; a 32-hex string is accepted as a ready key;
  leaving the field empty keeps the existing key).

### From a terminal

```sh
sh /data/local/tmp/kosync.sh server   # show local/server progress
sh /data/local/tmp/kosync.sh push     # send the last opened book
sh /data/local/tmp/kosync.sh pull     # apply the server position
sh /data/local/tmp/kosync.sh status   # detailed status
```

`push`/`pull` accept an optional book name (`push 609279.epub`) or `all`.

> Before `pull`, close the book in OReader: the script refuses to write while a
> book is on screen, to avoid the reader overwriting the new position from memory.

---

## Project layout

```
app/                    Android app (Java, API 9)
  AndroidManifest.xml
  build.ps1             aapt + ecj + dx + apksigner pipeline
  src/ru/local/oreadersync/MainActivity.java
device/
  kosync.sh             sync script (push / pull / status / server)
  kosync.conf.example   settings template
  bookpos.c             EPUB position ⇄ XPointer converter
  miniz/                zlib-compatible inflate used by bookpos (MIT)
```

## Building bookpos

```sh
# host (for testing)
zig cc -O2 -I device/miniz device/bookpos.c device/miniz/miniz.c -o bookpos

# ARM, static, for the reader
zig cc -target arm-linux-musleabihf -mcpu=cortex_a8 -O2 -static -fno-pie -no-pie \
       -I device/miniz device/bookpos.c device/miniz/miniz.c -o bookpos
```

Commands: `info`, `table`, `p2x <pos>`, `x2p <xpath>`.

---

## Limitations

- **EPUB only.** FB2 and other formats have no XPointer mapping here.
- **Percentages differ between devices.** CrossPoint computes the percentage from
  the byte sizes of spine files, AlReader from character counts. The *position*
  is transferred exactly; percentages are informational only.
- **±1 page visual difference is normal.** The two readers paginate differently
  (font, size, margins), so the same text position lands on different pages.
- **Plain HTTP only** on Android 2.3 — no TLS in the stock busybox.
- The other side must understand KOReader XPointers
  (`/body/DocFragment[N]/body/.../text()[k].off`).

## Privacy

No credentials, server addresses or personal data are stored in this repository.
The APK and the script read all settings from `/sdcard/oreader-kosync/kosync.conf`
on the device. No books are included.

## License

MIT. `device/miniz` is the public-domain/MIT miniz library — see its `LICENSE`.
