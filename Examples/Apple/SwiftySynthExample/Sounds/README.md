# Sounds

Drop a SoundFont here to make the example play sound. The app looks for
`GeneralUser-GS.sf2` first, then any `*.sf2` in this folder.

`*.sf2` files are gitignored (the repo does not ship a SoundFont). Copy your own:

    cp ~/Desktop/Sounds/GeneralUser-GS.sf2 Examples/Apple/SwiftySynthExample/Sounds/

Or set the `SWIFTYSYNTH_SF2` environment variable to an absolute path when
running from the CLI / Xcode scheme.
