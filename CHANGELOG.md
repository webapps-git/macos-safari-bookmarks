# Changelog

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
