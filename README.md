# Safari Bookmarks for macOS

A bookmark manager for Safari on macOS. Add, edit, move, sort and delete bookmarks and folders without losing them.

Rearranging bookmarks by drag and drop in Safari's sidebar can lose whole folders. Safari Bookmarks works on Safari's bookmarks file directly, checks every change before it is written and keeps a backup of each previous version.

## ⚠️ Unsolved problem: Reading List order on iPhone after sorting

After the Reading List was sorted alphabetically in the app, an iPhone shows it in exactly the **reverse order** of the Mac (Z at the top). A Reading List item that Safari on the Mac put at the top also shows up at the bottom on the iPhone. The cause is not known yet. Until it is, sorting the Reading List is best avoided.

## Features

- **Library window** like in Firefox or Edge: the folder tree on the left, the contents of the selected folder on the right (name and address, number of bookmarks in each folder).
- **Drag and drop**: drop bookmarks and folders on a folder in the tree or in the list, change the order within a folder, move several items at once.
- **New Bookmark** (⌘D): name and address, added at the end of the open folder. An address copied to the clipboard is filled in; `example.com` becomes `https://example.com/`; an empty name becomes the site name. Not available in the Reading List – add pages to it in Safari.
- **New Folder** (⇧⌘N) in the open folder. Both are also in the toolbar and in the right-click menu.
- **Edit** (Return): name and address of a bookmark, name of a folder. **Move to…** a folder picked from a list, **Delete** (Delete key, with confirmation).
- **Sort** the open folder alphabetically: folders first, bookmarks first or all together, optionally with all subfolders. The Reading List can be sorted alphabetically too. Polish and other accented letters are sorted correctly.
- **Reading List**: single bookmarks can be moved between the Reading List and your folders. Folders cannot be moved into the Reading List, because Safari has no folders there.
- **Search** in names and addresses across all folders, with the folder of each result.
- **Find Duplicates** (Bookmarks menu): bookmarks with an identical address, and "almost identical" ones that differ only in http/https, "www." or a trailing slash. Each shows its folder and date added. For identical ones the app suggests keeping one (from Favorites, with https, or the oldest) and checks the rest for deletion; almost identical ones are left for you to decide. The Reading List is skipped.
- **Check Links** (Bookmarks menu): the app visits every bookmark like a browser, without cookies or saved logins, several at a time, and only reads the first part of the answer. Results: **permanently moved** (suggests the new address), **works over https** (suggests https instead of http), **dead** (the page or the domain is gone – you check which to delete), **unsure** (login needed, blocked, server error, no answer in time – shown only). Address fixes are checked by default, deletions are not; nothing changes until you click Apply, and it can be undone until saving. **Skip** hides a bookmark from future checks. The Reading List is not checked. Each site sees an ordinary visit from your address; a firewall app may ask once whether Safari Bookmarks may connect.
- **Undo and redo** (⌘Z, ⇧⌘Z) for every change until it is saved.
- **Unsaved changes** are not lost by accident: quitting the app or closing its window asks whether to save them. Closing the main window quits the app.
- **Backups**: a copy of the bookmarks file is made before every save; any copy can be restored from the app.
- **Info** for a bookmark or folder (right click): address, folder, date added, whether it syncs with iCloud.
- **iCloud status** in the toolbar: green – everything sent, orange – changes waiting, red – a problem (for example no permission to control Safari), grey – iCloud off. A click shows details and a **Send Now** button.

## How saving keeps bookmarks safe

- Changes stay in the app until you click **Save**.
- Safari must be open: Safari watches its bookmarks file and loads the saved changes right away. While Safari is closed, a bar at the top says so and saving is blocked; the bar has a button to open Safari. The app never quits Safari.
- Before anything is written, the app checks the new file against the one it loaded:
  - every bookmark and folder is still there, except the ones you deleted, plus the ones you added;
  - the number of bookmarks matches;
  - nothing changed except names, order and the addresses you edited: dates and iCloud sync data are untouched;
  - the list of changes for iCloud (see below) only describes what you did;
  - Safari's own folders (Favorites, Bookmarks Menu, Reading List) stay in place.

  If anything does not match, nothing is written.
- If the file changed since it was loaded (in Safari or through iCloud), nothing is written.
- The current file is copied to a backup, the new file replaces it in one step, and the app reads it back to compare.

## Keyboard

| Key | Action |
| --- | --- |
| ⌘D | New bookmark |
| ⇧⌘N | New folder |
| Return | Edit (name and address) |
| ⌫ | Delete (with confirmation) |
| ⇧⌘M | Move to… |
| ⌥⌘↑ / ⌥⌘↓ | Move up / down within the folder |
| ⌘Z / ⇧⌘Z | Undo / redo |
| ⌘S | Save to Safari |
| ⌘R | Reload from Safari |
| ⌘W / ⌘Q | Close the window / quit (asks about unsaved changes) |

## iCloud

Safari syncs bookmarks through iCloud in the background, also while Safari is closed. The sync does not compare the bookmarks file with iCloud: it only sends the changes listed in a list of changes inside the file, which Safari fills in itself.

So that changes made in Safari Bookmarks reach your other devices, the app adds them to that list when saving, in the same form as Safari: new bookmarks and folders, moves and new order, new names and addresses, deletions. It does not change the sync data of the bookmarks themselves. The list is added only when iCloud sync is turned on for Safari.

- Changes saved with version 1.0.0 were not added to the list, so iCloud did not get them. **Bookmarks → Send Old Changes to iCloud…** works them out from the backups (moves, order, renames, deletions), shows what will be sent, including every deleted item, and adds them to the list. Then save.

### How the changes are sent

Safari's sync program sends the list only when Safari tells it to, and Safari does that only after it saves bookmarks itself. The sync program does not accept this request from any other app: it needs a private Apple permission that only Safari has.

So right after saving, the app asks Safari (AppleScript) to add the **top item of the Reading List** again, with the same address, title and preview text. Safari replaces that item with a new one, saves its bookmarks and sends everything waiting in the list to iCloud, the app's changes included. The app waits up to 30 seconds and shows "Sent to iCloud" when the list is empty.

- The first time, macOS asks whether Safari Bookmarks may control Safari. Without this permission (System Settings → Privacy & Security → Automation) the changes wait until your next bookmark change in Safari.
- Side effect: the top Reading List item gets today's date added and may lose its picture until Safari loads it again.
- With an empty Reading List the app adds one item to it: the app's page on GitHub ("Safari Bookmarks"). It stays there and is the item added again with later saves, so there is always just one.

## Requirements

- macOS 15.0 or later, Apple Silicon or Intel (`build.sh` builds for the Mac it runs on).
- Xcode 26 or later to build (the project uses Swift 6.2).
- **Full Disk Access** for the app (System Settings → Privacy & Security → Full Disk Access): Safari's folder in `~/Library/Safari` is protected by macOS.

## Build

**Xcode:** create `Local.xcconfig` next to `Signing.xcconfig` with your team (`DEVELOPMENT_TEAM = ABCDE12345`; the file is not committed), open `SafariBookmarks.xcodeproj` and run. Without a team, Xcode signs the app to run locally.

**Command line** (builds Release for the processor of this Mac only and installs into `/Applications`):

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
