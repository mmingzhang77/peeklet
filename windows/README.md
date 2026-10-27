# Peeklet for Windows

Peeklet is a small floating photo viewer. Import images of your choosing from the menu, then hold the control to display the selected image and release to close the preview. Drag the control to move it, use the mouse wheel to select another image, and right-click it or the notification-area icon for options. If the control is difficult to locate, left-click the notification-area icon to restore it to the upper-right corner.

Peeklet starts with an empty library. It accepts JPEG, PNG and TIFF images, up to 30 photos of at most 50 MiB and 100 megapixels each. Preview images are limited to 2048 pixels on their longest side. Imported copies and their generated identifiers are stored locally under `%LOCALAPPDATA%\Peeklet`. Original images are not changed or deleted. The import creates a fresh PNG from decoded pixels without copying the source metadata; no original paths or filenames are stored in the library.

The app uses no network access, accounts, analytics, global keyboard or mouse hooks, or automatic startup entries. Imported files are not encrypted. Screenshots, recordings, backups, and exclusive full-screen applications are outside Peeklet's control. Windows may display warnings for an unsigned executable.

## Build on Windows

Install the .NET 10 SDK on a 64-bit Windows machine, then run the following from this directory:

```powershell
dotnet build Peeklet.Windows.csproj -c Release
dotnet bin\Release\net10.0-windows\Peeklet.dll --self-test
```

The self-tests generate their own temporary images and do not access the user's photo library or display photos. Check the process exit code if the Windows subsystem suppresses console output.

To build a self-contained, single-file Windows x64 executable:

```powershell
dotnet publish Peeklet.Windows.csproj -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -p:PublishTrimmed=false -o bin\publish\win-x64
```

The executable is `bin\publish\win-x64\Peeklet.exe`. A real Windows test is still required to verify desktop input, scaling, placement, and behavior with particular full-screen apps.
