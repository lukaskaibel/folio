# Changelog

Everything users would notice, newest first. The format follows [Keep a Changelog](https://keepachangelog.com), and
versions follow [semantic versioning](https://semver.org).

## [Unreleased]

### Added

- Notebook on iPhone and iPad, with the editor, search and files of the Mac. On the iPhone, one folder per screen as in
  the Files app, with search and a new note at the bottom as in Notes; on the iPad, the Mac's sidebar, the note and its
  outline.
- A bar above the keyboard with the text styles and formatting, a checklist, a link, and pictures from the camera, the
  document scanner, Photos or the Files app.
- Swipe actions and menus on touch and hold for files, drag and drop of files and pictures, and the Mac's keyboard
  shortcuts and menus on an iPad with a keyboard.
- Notes as a PDF to share, or printed, on iPhone and iPad.
- On iPhone and iPad, the bar above the keyboard floats over the note as in Notes and scrolls a page of tools at a
  time; Settings › Writing Bar chooses its tools and their order. Aa opens the Format panel in the keyboard's place.
- Touch and hold a picture or file in a note and drag it to another place in the note, or let go to copy, cut, share or
  delete it.
- Drawings in notes, as in Notes. The pencil in the toolbar starts drawing where you are without moving the note: in the
  drawing on screen, or in a new one below the line you're writing on (at the end of the note, or in the middle of the
  screen, when you aren't writing), as wide as the text and with no frame around it; it grows as you draw near its lower
  edge, and at the end of the note you can draw anywhere below the text. On iPhone and iPad with Apple Pencil or a
  finger and the system's tool picker; on the Mac with the mouse, the trackpad or a tablet, and a pen, pencil, marker
  and eraser at the bottom of the note. Each drawing is a PNG in `.assets` that other apps show, with its strokes in a
  `.drawing` file next to it, so it stays a drawing you can go on with in Notebook.
- Hide folders you don't want to see, such as the ones other apps keep in iCloud Drive: right-click one and choose
  Hide Folder. Hidden folders leave the sidebar, search and Move To, and stay hidden on your other Macs through iCloud.
  To see them again, dimmed, click the eye next to the location's name or press ⇧⌘.; links to notes in them keep
  working.

### Changed

- Checkboxes are circles, as in Notes and Reminders, filled with the accent colour when done. On iPhone and iPad they
  are bigger, for a fingertip.

### Fixed

- Links in a note opened while Notebook was still reading your folders showed as links to notes that don't exist yet.
- Giving a new note its name could stop Notebook for a long time in a large folder in iCloud Drive. Renaming a note
  still updates the links to it in other notes, now in the background.

## [0.1.0] – not released yet

The first version: a Mac app for Markdown notes in your own folders. While it was being built, it was called Folio.

### Added

- Locations: iCloud Drive or any folder in the sidebar, with favourites, read in place and watched for changes.
- iCloud Drive as the Finder shows it, with Desktop, Documents and the folders of apps such as Pages or Obsidian.
- A live-preview editor: Markdown marks show only next to the caret, and heading levels in the margin.
- Headings, bold, italic, strikethrough, highlights, inline code, links, checklists, lists, quotes, callouts, tables,
  code with highlighting, LaTeX maths, Mermaid diagrams, footnotes and folded front matter.
- A copy button in the corner of the code block under the pointer, and Copy Code when you right-click one.
- Pictures, `[[links]]` and `![[embeds]]` as objects; pictures and files pasted or dropped in go to `.assets`.
- The title is the file name; renaming a note updates the links to it.
- Search with ⌘F across file names, note text and PDF text.
- Back and forward with ⌘[ and ⌘], or with a swipe as in Safari.
- PDFs, pictures and videos in the window as in Preview and QuickTime Player, there at once: PDFs back where you
  left them, pictures to zoom in on with a pinch or a double click. Quick Look for every other file.
  The inspector shows a file's details.
- The outline of a note in the inspector, with a word count.
- Saving as you type, with a three-way merge when a note changed somewhere else, and a choice when both changed the
  same lines.
- Export as PDF or PNG, and printing.
- Markdown files opened from the Finder or with ⌘O in windows of their own; folders opened either way go to the
  sidebar.
- Settings for the typeface, size, line spacing and line width, and for what the sidebar shows.
- A leather notebook as the app icon. Make it your own in Settings › App Icon: the leather, the elastic band, the
  ribbon and the background, shown in the Dock while Notebook is open. A tip in the sidebar points there.
- Ink blue as Notebook's accent colour, for links, the caret and folders, when the accent in System Settings is set
  to Multicolour.
