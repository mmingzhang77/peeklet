using System;
using System.IO;
using System.Threading;
using System.Windows;

namespace Peeklet;

internal static class Program
{
    [STAThread]
    private static int Main(string[] args)
    {
        if (args.Length == 1 && args[0] == "--self-test")
        {
            try { SelfTests.Run(); return 0; }
            catch (Exception) { Console.Error.WriteLine("Peeklet self-test failed."); return 1; }
        }

        // A single active instance avoids simultaneous edits to the same library.
        using var instance = new Mutex(true, @"Local\Peeklet.App", out bool ownsInstance);
        if (!ownsInstance)
        {
            MessageBox.Show("Peeklet is already running. Use its notification-area icon to find the entrance.",
                "Peeklet", MessageBoxButton.OK, MessageBoxImage.Information);
            return 0;
        }

        try
        {
            var root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Peeklet");
            var library = new PhotoLibrary(root);
            var app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
            var window = new PeekWindow(library);
            app.Run(window);
            return 0;
        }
        catch (Exception)
        {
            MessageBox.Show("Peeklet could not open its photo library. The existing library was not replaced.",
                "Peeklet", MessageBoxButton.OK, MessageBoxImage.Warning);
            return 1;
        }
    }
}
