# App icon updated

The launcher icon `android/app/src/main/res/mipmap-*/ic_launcher.png` has been replaced with the supplied custom icon.

The Android manifest already references `@mipmap/ic_launcher`, so no manifest change was required.

Both parent and child flavors use this launcher icon unless a flavor-specific resource override is added later.
