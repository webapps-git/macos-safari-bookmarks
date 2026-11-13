# Safari Bookmarks for macOS

A bookmark manager for Safari on macOS. Move, rename, sort and delete bookmarks and folders without losing them.

Rearranging bookmarks by drag and drop in Safari's sidebar can lose whole folders. Safari Bookmarks works on Safari's bookmarks file directly, checks every change before it is written and keeps a backup of each previous version.

## Features

- **Library window** like in Firefox or Edge: the folder tree on the left, the contents of the selected folder on the right (name and address, number of bookmarks in each folder).
- **Drag and drop**: drop bookmarks and folders on a folder in the tree or in the list, change the order within a folder, move several items at once.
- **Rename** (Return), **Move to…** a folder picked from a list, **Delete** (Delete key, with confirmation).
- **Sort** the open folder alphabetically: folders first, bookmarks first or all together, optionally with all subfolders. The Reading List can be sorted alphabetically too. Polish and other accented letters are sorted correctly.
- **Reading List**: single bookmarks can be moved between the Reading List and your folders. Folders cannot be moved into the Reading List, because Safari has no folders there.
- **Search** in names and addresses across all folders, with the folder of each result.
- **Undo and redo** (⌘Z, ⇧⌘Z) for every change until it is saved.
- **Unsaved changes** are not lost by accident: quitting the app or closing its window asks whether to save them. Closing the main window quits the app.
- **Backups**: a copy of the bookmarks file is made before every save; any copy can be restored from the app.
- **Info** for a bookmark or folder (right click): address, folder, date added, whether it syncs with iCloud.

## How saving keeps bookmarks safe

- Changes stay in the app until you click **Save**.
- Safari must be closed. The app never quits Safari by itself; while Safari is open, a bar at the top says so and saving is blocked.
- Before anything is written, the app checks the new file against the one it loaded:
  - every bookmark and folder is still there, except the ones you deleted;
  - the number of bookmarks matches;
  - nothing changed except names and order: addresses, dates and iCloud sync data are untouched;
  - Safari's own folders (Favorites, Bookmarks Menu, Reading List) stay in place.

  If anything does not match, nothing is written.
- If the file changed since it was loaded (in Safari or through iCloud), nothing is written.
- The current file is copied to a backup, the new file replaces it in one step, and the app reads it back to compare.

## Keyboard

| Key | Action |
| --- | --- |
| Return | Rename |
| ⌫ | Delete (with confirmation) |
| ⇧⌘M | Move to… |
| ⌥⌘↑ / ⌥⌘↓ | Move up / down within the folder |
| ⌘Z / ⇧⌘Z | Undo / redo |
| ⌘S | Save to Safari |
| ⌘R | Reload from Safari |
| ⌘W / ⌘Q | Close the window / quit (asks about unsaved changes) |

## iCloud

Safari syncs bookmarks through iCloud in the background, also while Safari is closed. Safari Bookmarks does not touch the sync data, but how iCloud handles changes made outside Safari is still being tested. Try the app on a test folder first.

## Requirements

- macOS 15.0 or later, Apple Silicon or Intel (universal build).
- Xcode 26 or later to build (the project uses Swift 6.2).
- **Full Disk Access** for the app (System Settings → Privacy & Security → Full Disk Access): Safari's folder in `~/Library/Safari` is protected by macOS.

## Build

**Xcode:** create `Local.xcconfig` next to `Signing.xcconfig` with your team (`DEVELOPMENT_TEAM = ABCDE12345`; the file is not committed), open `SafariBookmarks.xcodeproj` and run. Without a team, Xcode signs the app to run locally.

**Command line** (builds Release and installs into `/Applications`):

```bash
ADHOC=1 ./build.sh
```

`ADHOC=1` signs the app ad hoc, so no Apple developer account is needed; the result runs on the Mac that built it. Without it, `build.sh` signs with the team from `Local.xcconfig`, or ad hoc when that file does not exist.

Full Disk Access is tied to the app's signature. With ad hoc signing, macOS may ask for it again after each rebuild.

To share a ready-built app with other people, sign it with a Developer ID certificate and notarize it, otherwise Gatekeeper blocks it.

## Trying it on a copy

The app can work on any copy of `Bookmarks.plist` instead of Safari's file. Safari is then ignored:

```bash
open "/Applications/Safari Bookmarks.app" --args -BookmarksFile ~/Desktop/Bookmarks-copy.plist
```

## Notes

- The app is **not sandboxed**: it needs to read and write Safari's bookmarks file. For the same reason it cannot be distributed through the Mac App Store.
- Backups are stored in `~/Library/Application Support/Safari Bookmarks/Backups/`, a log of saves in `log.txt` next to it.
- The app is in English and Polish. It follows the macOS language: Polish when macOS picks Polish for the app, English otherwise.
- Not affiliated with or endorsed by Apple. Safari is a trademark of Apple Inc.

## Changes

See [CHANGELOG.md](CHANGELOG.md).

## License

MIT, see [LICENSE](LICENSE).
