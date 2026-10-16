fastlane documentation
----

# Installation

Make sure you have the latest version of the Xcode command line tools installed:

```sh
xcode-select --install
```

For _fastlane_ installation instructions, see [Installing _fastlane_](https://docs.fastlane.tools/#installing-fastlane)

# Available Actions

### build

```sh
[bundle exec] fastlane build
```

Builds the Mac, iPhone and iPad apps for the App Store, signed, without uploading them

### beta

```sh
[bundle exec] fastlane beta
```

Builds the Mac, iPhone and iPad apps and uploads them to TestFlight

----


## iOS

### ios build

```sh
[bundle exec] fastlane ios build
```

Builds the iPhone and iPad app for the App Store, signed, without uploading it

### ios beta

```sh
[bundle exec] fastlane ios beta
```

Builds the iPhone and iPad app and uploads it to TestFlight

----


## Mac

### mac build

```sh
[bundle exec] fastlane mac build
```

Builds the Mac app for the App Store, signed, without uploading it

### mac beta

```sh
[bundle exec] fastlane mac beta
```

Builds the Mac app and uploads it to TestFlight

----

This README.md is auto-generated and will be re-generated every time [_fastlane_](https://fastlane.tools) is run.

More information about _fastlane_ can be found on [fastlane.tools](https://fastlane.tools).

The documentation of _fastlane_ can be found on [docs.fastlane.tools](https://docs.fastlane.tools).
