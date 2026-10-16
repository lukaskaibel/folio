# Privacy

Notebook is a notes app for files on your Mac. It has no server, no accounts, no analytics and no advertising, and it
collects nothing about you.

## What the app stores, and where

- **Your notes** are the Markdown files in your own folders. Notebook reads and writes them in place. Pictures and files
  you add to a note go into a hidden `.assets` folder next to it.
- **The folders you add** as locations are remembered on your Mac, with the permission to open them again (a
  security-scoped bookmark).
- **Favourites, recently opened files, the folders open in the sidebar and your settings** (typeface, text size,
  what the sidebar shows) are kept in the app's preferences on your Mac.
- **The folders you hide and the reminders you set** are kept in the app's preferences and, in the App Store build, in
  iCloud's key-value store, which Apple syncs to your other devices signed in to the same Apple Account. A reminder is
  the place of its note in your folders and its time; it is never written into the note, so it doesn't go along when
  you share the note.
- **Notifications** of reminders are scheduled on each of your devices by the system. Their text is the note's name,
  the time and the note's first points, read from the note on that device. Notebook asks whether it may send
  notifications when you set your first reminder, and you can turn them off in System Settings or Settings.
- **The search index** of file names, note text and PDF text is kept in memory only, and built again at every launch.

## What is sent, and to whom

- **Nothing.** Notebook contains no code that connects to the internet. Pictures in notes that point to a web address
  are not downloaded; Notebook shows the address instead.
- When you click a web link in a note, your browser opens it.
- If your notes are in iCloud Drive, Apple syncs them as it syncs every other file there; Notebook asks the system to
  download notes that aren't on your Mac yet, so it can show and search them. What Apple does with iCloud Drive is
  described in [Apple's privacy policy](https://www.apple.com/legal/privacy/).

## Sample notes

Debug builds can create sample notes in a folder you name (`-NotebookDemo YES`), for trying the app and for the README's
pictures. They are made up, and nothing about them is sent anywhere.

## Questions

Write to [notebook.app@icloud.com](mailto:notebook.app@icloud.com) or open an issue in the
[repository](https://github.com/lukaskaibel/notebook/issues). Security problems are best reported privately, as described
in [SECURITY.md](SECURITY.md).
