# Security

Notebook reads and writes the files in the folders you give it, so security reports are taken seriously.

Please report vulnerabilities privately through
[GitHub's private vulnerability reporting](https://github.com/lukaskaibel/notebook/security/advisories/new) rather than
in a public issue. You will get a reply as soon as possible.

What the app can reach: the folders you add as locations, and Markdown files you open from the Finder. The App Store
build is sandboxed and keeps access to your locations through security-scoped bookmarks. Notebook has no server and
sends nothing anywhere; see [PRIVACY.md](PRIVACY.md) for what it stores.
