# Contributing

Thanks for wanting to help. This is a small project with one maintainer, so a little coordination up front saves
everyone time.

## Before you start

- **Bugs:** open an issue with what you did, what you expected and what happened. Screenshots or a short recording
  help a lot for anything visual, and so does the Markdown of the note, if you can share it.
- **Features and larger changes:** open an issue first and describe the idea. Folio is deliberately small: every
  feature has to answer "do I need this to replace Apple Notes day to day?", and [PLAN.md](PLAN.md) lists what is left
  out on purpose. It is better to find out whether something fits before you write the code.
- **Small fixes** (typos, obvious bugs): a pull request without an issue is fine.

## Making a change

1. Fork the repository and create a branch from `main`.
2. Build and run from Xcode (see the README). Try your change on the sample notes (`-FolioLibrary <folder>
   -FolioDemo YES`) rather than your own.
3. Run the tests: `cd Packages/FolioKit && swift test`.
4. Open a pull request against `main` and describe what changed and how you checked it.

Every pull request is reviewed and merged by the maintainer; nothing lands on `main` without that approval.

## What to keep in mind

- **The file is the truth.** The editor holds the file's Markdown character for character, and what Folio saves is
  Markdown any other app reads the same. Don't add a database, a sidecar file or syntax only Folio understands.
- **Never lose a change.** Saving goes through `NSFileCoordinator` and merges with what is on disk
  (`Files/NoteDocument.swift`, `Files/Diff3.swift`). Anything that writes files keeps that promise, and deleting means
  the Trash.
- **Nothing jumps.** Text never moves under a selection or the mouse, and scrolling never jumps. If you touch the
  editor's styling or layout, type in a long note and scroll it before and after; `EditorSmoothnessTests` has to pass.
- **Markdown is a file format, not the interface.** Pictures, links and embeds are objects; marks show only next to
  the caret.
- **Use what the Mac has.** System components and layout (split view, source list, inspector, toolbar, search field,
  alerts, Quick Look) rather than custom chrome, and system colours rather than new ones.
- **Show what changed.** A change people will notice gets a line in `CHANGELOG.md` under "Unreleased", and the README
  follows: the tour, "What it does", the shortcut tables, "Not there yet", and the pictures (`Tools/readme-images.sh`).
  A feature worth a picture gets something in the sample notes (`Debug/DemoLibrary.swift`) to show it with.
- Match the style of the code around you. Comments explain why, not what.

## Releases

Versions follow semantic versioning. The version lives in `Config/Shared.xcconfig`; each release gets an entry in
`CHANGELOG.md` and a tag of the form `v0.1.0`.
