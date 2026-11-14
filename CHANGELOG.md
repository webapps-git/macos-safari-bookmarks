# Changelog

## 1.6.0 – 2026-11-14

- Bookmarks → Check Links…: visits every bookmark (without cookies or saved logins, 8 at a time, only the start of each answer) and sorts the problems into: permanently moved (new address suggested), works over https (https suggested), dead (page or domain gone), unsure (login, blocking, server error, no answer). Address fixes are pre-checked, deletions are not; Apply makes one undoable step for the addresses and one for deletions. Skip hides a bookmark from future checks. The Reading List is not checked.

## 1.5.0 – 2026-11-14

- Bookmarks → Find Duplicates…: groups of bookmarks with an identical address and "almost identical" ones (only http/https, "www." or a trailing slash differ), with folder and date added. For identical groups the app suggests keeping one – from Favorites, with https, or the oldest – and checks the others for deletion. Almost identical groups are left unchecked. Deleting is one step that can be undone until saving. The Reading List is skipped.

## 1.4.0 – 2026-11-14

- Edit instead of Rename (Return, toolbar, right-click menu): name and address of a bookmark in one window, like New Bookmark; name of a folder. A changed address goes to iCloud like a change made in Safari.
- iCloud status in the toolbar: green – everything sent, orange – changes waiting, red – a problem, grey – iCloud off. A click shows details and a Send Now button. The app checks Safari's bookmarks file every few seconds, so it also shows changes made in Safari that are still waiting.
- The check before saving allows a new address only for bookmarks you edited.

## 1.3.1 – 2026-11-14

- Empty Reading List: instead of leaving the changes waiting, the app adds one item to the Reading List – the app's page on GitHub – which makes Safari send the changes to iCloud. The item stays and is used again with later saves.

## 1.3.0 – 2026-11-14

- Saving now works only while Safari is open (before: only while Safari was closed). Safari loads the changed file right away. While Safari is closed, a bar says so and has an Open Safari button. The same applies to restoring a backup.
- Changes now reach iCloud right after saving: the app asks Safari (AppleScript) to add the top Reading List item again with the same address, title and preview text. Safari saves its bookmarks and sends everything waiting to iCloud. The app shows "Sent to iCloud" when done. macOS asks once for permission to control Safari. Side effect: that one Reading List item gets today's date.
- Tested with a real iCloud account: a change saved in the app showed up on an iPhone a few seconds later.
- Known problem: after sorting the Reading List in the app, an iPhone shows it in reverse order (see README).

## 1.2.0 – 2026-11-13

- Bookmarks → Send Old Changes to iCloud…: changes saved with 1.0.0 never reached iCloud. The app works them out from its backups (moves, order, renames, deletions), shows a summary with the list of deleted items, and adds them to Safari's list of changes for iCloud. Bookmarks on the Mac do not change. Can be done once.
- The check before saving accepts these entries only for items that exist (moves, renames) or no longer exist (deletions).
- Tested with a real iCloud account: moves, order, renames and deletions saved in the app were accepted by iCloud; a moved bookmark showed up on an iPhone.

## 1.1.0 – 2026-11-13

- New Bookmark (⌘D): name and address, added at the end of the open folder; an address copied to the clipboard is filled in. Also in the toolbar and the right-click menu. Not in the Reading List.
- New Folder (⇧⌘N), also in the toolbar and the right-click menu.
- iCloud: saving now adds the changes to Safari's list of changes for iCloud (new, moved, renamed and deleted items), so they can reach other devices. Changes saved with 1.0.0 were not sent.
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
