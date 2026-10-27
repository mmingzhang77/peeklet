# Privacy

Peeklet is a local macOS app. It does not require an account, collect analytics, or include network access entitlements. It does not upload photos or scan your folders in the background.

## What happens when you import a photo

You choose files using the macOS file picker. Peeklet reads only the selected files and creates PNG copies with a maximum dimension of 2048 pixels. The copies use generated identifiers rather than the original filenames. The import process does not retain the original file's EXIF or GPS metadata, and it does not save the original path in the library manifest. The original files are not modified or deleted.

The copies and library index are stored in the app's sandbox under its Application Support directory:

```text
~/Library/Containers/io.github.peeklet.app/Data/Library/Application Support/Peeklet
```

This is local app storage, not an encrypted vault. Anyone who can access the files under your macOS account or its backups may be able to view the imported copies. macOS or your backup software may keep copies outside the app's control.

## Removing photos

The menu offers actions to remove the current imported copy or all imported copies, with a confirmation before removal. These actions do not delete the original files. Removing a copy from Peeklet does not guarantee secure erasure or removal from backups.

## What Peeklet cannot protect

Peeklet hides the preview when you release the control or move the pointer away. It cannot prevent screenshots, screen recordings, screen sharing, or another person seeing your display. It is not a security boundary or a tool for bypassing monitoring.

## Your photos and the source code

The MIT License applies to Peeklet's source code. It does not grant rights to photos that you or others import. Only use images you have permission to use.
