# Changelog

## 1.2.0 – 2026-11-13

- Bookmarks → Send Old Changes to iCloud…: changes saved with 1.0.0 never reached iCloud. The app works them out from its backups (moves, order, renames, deletions), shows a summary with the list of deleted items, and adds them to Safari's list of changes for iCloud. Bookmarks on the Mac do not change. Can be done once.
- The check before saving accepts these entries only for items that exist (moves, renames) or no longer exist (deletions).
- Tested with a real iCloud account: moves, order, renames and deletions saved in the app were accepted by iCloud; a moved bookmark showed up on an iPhone.
- Known problem, not solved: changes reach iCloud only after a small edit to bookmarks in Safari itself; the app cannot start the sending (see README).

## 1.1.0 – 2026-11-13

- New Bookmark (⌘D): name and address, added at the end of the open folder; an address copied to the clipboard is filled in. Also in the toolbar and the right-click menu. Not in the Reading List.
- New Folder (⇧⌘N), also in the toolbar and the right-click menu.
- iCloud: saving now adds the changes to Safari's list of changes for iCloud (new, moved, renamed and deleted items), so they can reach other devices. Changes saved with 1.0.0 were not sent. Not yet tested with a real iCloud account.
- The check before saving also covers new items and the list of changes for iCloud.
- `build.sh` builds only for the processor of the Mac it runs on.

## 1.0.0 – 2026-11-13

First release.

- Library window: folder tree on the left, folder contents on the right.
- Drag and drop: into folders, reordering within a folder, several items at once.
- Rename, Move to…, Delete with confirmation.
- Alphabetical sorting of a folder (folders first, bookmarks first or all together, optionally with subfolders) and of the Reading List.
- Single bookmarks can be moved between the Reading List and folders.
- Search in names and addresses.
- Undo and redo until saving.
- Checks before every save; nothing is written if anything does not match.
- Saving only while Safari is closed; the app never quits Safari.
- Backup before every save, restore from the app.
- Question about unsaved changes when quitting or closing the window.
- English and Polish, following the macOS language.
