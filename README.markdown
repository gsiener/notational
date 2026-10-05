# Notational

A native Apple Silicon fork of [nvALT](https://brettterpstra.com/projects/nvalt/) (itself a fork of Notational Velocity), by way of [@n8henrie's fork](https://github.com/n8henrie/nvalt).

- **Native arm64**, no Rosetta, and only system-linked libraries; bundled source dependencies are documented in the [dependency audit](docs/research/apple-library-dependency-audit.md)
- **Simplenote is the source of truth**: notes live in a local SQLite copy of your Simplenote account and sync over the Simperium API (sign in with an emailed code under *Notational → Simplenote Account…*). Works without signing in too, as a local-only notes app. See [ADR 0001](docs/adr/0001-simplenote-backed-storage.md).
- On first launch it migrates once from an old nvALT installation (old files are never modified) and copies nvALT's look-and-feel preferences.
- Not affiliated with Simplenote/Automattic; third-party clients can be blocked by Simplenote at any time.

The [architecture decision records](docs/adr/README.md) explain the app’s design and distinguish accepted decisions from proposed changes.

**Download:** [the latest build](https://github.com/gsiener/notational/releases/download/latest/Notational.zip) (Apple Silicon). CI rebuilds it from every push to `master` that passes the tests; the [release page](https://github.com/gsiener/notational/releases/tag/latest) shows which commit it is and has a SHA-256 checksum.

To build locally you only need Xcode:

```
xcodebuild -target Notation -configuration ForBuilding build
```

The app lands in `build/ForBuilding/Notational.app`. Encryption, hashing and link
detection use macOS's built-in CommonCrypto and Foundation APIs; MultiMarkdown 6 is
compiled into the app from `Vendor/MultiMarkdown-6` (see [ADR 0010](docs/adr/0010-in-process-multimarkdown-6.md)).

When you try to open the application, you will likely be greeted by a warning along the lines of:

- Notational can't be opened because it is from an unidentified developer
- Notational can't be opened because the developer cannot be verified
- Notational can't be opened because Apple cannot check it for malicious software
- Apple could not verify "Notational.app" is free of malware that may harm your Mac or compromise your privacy

An application must be signed by an Apple-provided developer certificate to avoid these warnings; these cost $100 / year and I do not have one at this point.

Luckily these warnings can be worked around and should be a one-time-only nuisance.

To open the application (macOS 15 and later no longer offer right-click → Open for this):

- try to open Notational once and dismiss the warning
- open `System Settings` → `Privacy & Security`
- scroll down and click `Open Anyway` for Notational, then confirm

Signing and notarizing the app, which removes this step, is tracked in [#49](https://github.com/gsiener/notational/issues/49).

For more information, please review Apple's official guidance on this process: <https://support.apple.com/en-us/102445>

# nvALT 2

A collaboration between Brett Terpstra (ttscoff) and David Halter (ElasticThreads) based on [DivineDominion's](github.com/divineDominion/nv) fork. nvALT adds a few features we'd been looking for (and let me get some coding practice).

![Screenshot](http://img.skitch.com/20110520-k5y4i6i3p8ciftq2dbs7rx64e7.jpg)

## Contents

- [About nvALT](#about-nvalt)
- [What it is](#what-it-is)
- [Additional Features](#additional-features)
- [Customization](#customization)
- [Download](#download)
- [Credits](#credits)

## About nvALT

nvALT is a fork of the original [Notational Velocity][notational] with some additional features and some interface modifications. It is a work in progress. I'm not listing it as a beta, as that would imply that it was on its way to being its own product. It's an experiment, and I hope you enjoy it!

## What it is

Notational Velocity is a way to take notes quickly and effortlessly using just your keyboard. You press a shortcut to bring up the window and just start typing. It will begin searching existing notes, filtering them as you type. You can use &#x2318;-J and &#x2318;-K to move through the list. Enter selects and begins editing. If you're creating a new note, you just type a unique title and press enter to move the cursor into a blank edit area. Check out the descriptions at [notational.net][notational] for a more eloquent synopsis.

## Additional Features

nvALT adds:

* Widescreen (horizontal) layout option
* Shortcut (&#x2318;-&#x2325;-N) to collapse the notes panel
* Markdown, Textile and MultiMarkdown support with Preview window
* HTML source code tab in the Preview window for fast copy/paste to blogs, etc.
* Unique interface design changes
* Fixes for a couple of bugs/annoyances
* Customizable HTML and CSS files for the Preview window
    * You can use Javascript in the templates to do a few neat tricks

## Customization

Select "Open Custom CSS Folder" within the Preview menu, and the application's supprt folder will open. You will find two files:` template.html` and `custom.css`. If you're handy with HTML and CSS, feel free to customize these in whatever way you like. You can add Javascript as well, but you'll need to load external scripts from a url or using a full file:// path. If worst comes to worst, you can just delete or rename your customizations and the default files will be put back in place automatically when you select the menu item again.

## Download

More info and a download for the compiled binary can be found at [brettterpstra.com/projects/nvalt](http://brettterpstra.com/projects/nvalt/)

## Credits

* [Notational Velocity][notational]
* Code: The original Notational Velocity [source code][original source] by Zachary Schneirov
* Code: DivineDominion's [MultiMarkdown fork][DivineDominion]
* Inspiration: [Elastic Threads' version](http://elasticthreads.tumblr.com/nv) of Notational Velocity

[notational]: http://notational.net/
[original source]: https://github.com/scrod/nv
[DivineDominion]: https://github.com/DivineDominion/nv

