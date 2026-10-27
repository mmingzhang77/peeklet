using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace Peeklet;

internal static class SelfTests
{
    private static int checks;

    private static void Check(bool condition, string name)
    {
        if (!condition) throw new InvalidOperationException("Self-test failed: " + name);
        checks++;
    }

    private static void Reject(Action action, string name)
    {
        bool rejected = false;
        try { action(); } catch (Exception) { rejected = true; }
        Check(rejected, name);
    }

    public static void Run()
    {
        var peek = new PeekState();
        Check(peek.ShouldHide(100, true, true, true), "initially hidden");
        peek.Begin(100);
        Check(!peek.ShouldReveal(259), "short press remains hidden");
        Check(peek.ShouldReveal(260), "hold reveals");
        Check(peek.ShouldHide(261, false, true, true), "release hides");
        Check(peek.ShouldHide(261, true, false, true), "pointer exit hides");
        Check(peek.ShouldHide(261, true, true, false), "application switch hides");
        Check(peek.ShouldHide(10100, true, true, true), "hold timeout");
        peek.End();
        Check(!peek.ShouldReveal(300), "cancellation remains hidden");

        string root = Path.Combine(Path.GetTempPath(), "peeklet-test-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try { RunLibraryTests(root); }
        finally { Directory.Delete(root, recursive: true); } // Only this newly created test directory.
        Console.WriteLine($"PASS: {checks} checks using synthetic images; no photos displayed.");
    }

    private static void RunLibraryTests(string root)
    {
        string source = Path.Combine(root, "synthetic-source.png");
        string invalid = Path.Combine(root, "invalid.txt");
        string libraryPath = Path.Combine(root, "library");
        const string marker = "SYNTHETIC_PRIVATE_METADATA_MARKER";
        byte[] original = PngWithText(marker);
        File.WriteAllBytes(source, original);
        File.WriteAllText(invalid, "Not an image.");
        var library = new PhotoLibrary(libraryPath);
        Check(library.Count == 0, "new library is empty");
        library.Import(new[] { source });
        Check(library.Count == 1, "import one image");
        Guid first = library.Ids[0];
        string copy = Path.Combine(libraryPath, first.ToString("N") + ".png");
        Check(File.Exists(copy), "generated copy exists");
        var reload = new PhotoLibrary(libraryPath);
        Check(reload.Count == 1 && reload.Ids[0] == first, "reload library");
        BitmapSource image = reload.Image(0);
        Check(image.PixelWidth == 16 && image.PixelHeight == 12, "decode image");
        string manifest = File.ReadAllText(Path.Combine(libraryPath, "manifest.json"));
        Check(!manifest.Contains(source, StringComparison.OrdinalIgnoreCase) &&
              !manifest.Contains(Path.GetFileName(source), StringComparison.OrdinalIgnoreCase), "no original name or path stored");
        Check(Encoding.Latin1.GetString(original).Contains(marker, StringComparison.Ordinal), "source contains synthetic metadata");
        Check(!Encoding.Latin1.GetString(File.ReadAllBytes(copy)).Contains(marker, StringComparison.Ordinal), "source metadata removed");
        Reject(() => reload.Import(new[] { source, invalid }), "mixed batch rejected");
        Check(reload.Count == 1 && reload.Ids[0] == first, "failed batch rolls back");
        Check(Directory.GetFiles(libraryPath, "*.png").Length == 1, "failed batch leaves no extra copy");
        reload.Import(Enumerable.Repeat(source, 29).ToArray());
        Check(reload.Count == 30 && reload.Ids.Distinct().Count() == 30, "capacity and unique identifiers");
        Reject(() => reload.Import(new[] { source }), "capacity enforced");
        Check(reload.Count == 30, "capacity failure leaves library unchanged");
        reload.Remove(0);
        Check(reload.Count == 29 && !File.Exists(copy), "remove one copy");
        reload.RemoveAll();
        Check(reload.Count == 0 && new PhotoLibrary(libraryPath).Count == 0, "remove all and reload");
        Check(File.ReadAllBytes(source).SequenceEqual(original), "original remains unchanged");

        string journal = Path.Combine(libraryPath, ".transaction.json");
        Guid abandoned = Guid.NewGuid();
        string abandonedPath = Path.Combine(libraryPath, abandoned.ToString("N") + ".png");
        File.WriteAllBytes(abandonedPath, Encoding.ASCII.GetBytes("partial"));
        WriteJournal(journal, "importing", abandoned);
        var recoveredImport = new PhotoLibrary(libraryPath);
        Check(recoveredImport.Count == 0 && !File.Exists(abandonedPath) && !File.Exists(journal),
              "interrupted import rolls back");
        recoveredImport.Import(new[] { source });
        Guid removal = recoveredImport.Ids[0];
        string removalPath = Path.Combine(libraryPath, removal.ToString("N") + ".png");
        string pendingPath = Path.Combine(libraryPath, ".pending-" + removal.ToString("N") + ".png");
        WriteJournal(journal, "removing", removal);
        File.Move(removalPath, pendingPath);
        var recoveredRemoval = new PhotoLibrary(libraryPath);
        Check(recoveredRemoval.Count == 1 && File.Exists(removalPath) && !File.Exists(pendingPath),
              "uncommitted removal restored");
        WriteJournal(journal, "removing", removal);
        File.Move(removalPath, pendingPath);
        File.WriteAllText(Path.Combine(libraryPath, "manifest.json"), "{\"version\":1,\"ids\":[]}");
        var committedRemoval = new PhotoLibrary(libraryPath);
        Check(committedRemoval.Count == 0 && !File.Exists(pendingPath), "committed removal finishes");

        string oversized = Path.Combine(root, "oversized.png");
        using (var stream = new FileStream(oversized, FileMode.CreateNew, FileAccess.Write))
            stream.SetLength(50L * 1024 * 1024 + 1);
        Reject(() => committedRemoval.Import(new[] { oversized }), "oversized source rejected");
        Check(committedRemoval.Count == 0, "oversize rejection leaves library empty");
        string corruptDir = Path.Combine(root, "corrupt");
        Directory.CreateDirectory(corruptDir);
        string corrupt = Path.Combine(corruptDir, "manifest.json");
        File.WriteAllText(corrupt, "{not valid json");
        Reject(() => _ = new PhotoLibrary(corruptDir), "corrupt manifest rejected");
        Check(File.ReadAllText(corrupt) == "{not valid json", "corrupt manifest preserved");
        File.WriteAllText(corrupt, JsonSerializer.Serialize(new { version = 1, ids = new[] { Guid.Empty } }));
        Reject(() => _ = new PhotoLibrary(corruptDir), "empty identifier rejected");
        File.WriteAllText(corrupt, "{\"version\":1,\"ids\":[\"../outside\"]}");
        Reject(() => _ = new PhotoLibrary(corruptDir), "unsafe identifier rejected");
        Check(File.ReadAllBytes(source).SequenceEqual(original), "original remains untouched after recovery");

        // TIFF rotation metadata uses the TIFF IFD path rather than JPEG APP1.
        string rotated = Path.Combine(root, "rotated.tiff");
        var metadata = new BitmapMetadata("tiff");
        metadata.SetQuery("/ifd/{ushort=274}", (ushort)6);
        var tiff = new TiffBitmapEncoder();
        tiff.Frames.Add(BitmapFrame.Create(SyntheticBitmap(), null, metadata, null));
        using (var stream = new FileStream(rotated, FileMode.CreateNew, FileAccess.Write)) tiff.Save(stream);
        committedRemoval.Import(new[] { rotated });
        BitmapSource rotatedCopy = committedRemoval.Image(0);
        Check(rotatedCopy.PixelWidth == 12 && rotatedCopy.PixelHeight == 16, "TIFF orientation is applied");
    }

    private static void WriteJournal(string path, string operation, Guid id) =>
        File.WriteAllText(path, JsonSerializer.Serialize(new { version = 1, operation, ids = new[] { id } }));

    private static BitmapSource SyntheticBitmap()
    {
        const int width = 16, height = 12, stride = width * 4;
        var pixels = new byte[stride * height];
        for (int i = 0; i < pixels.Length; i += 4)
        {
            pixels[i] = 60; pixels[i + 1] = 130; pixels[i + 2] = 180; pixels[i + 3] = 255;
        }
        var bitmap = BitmapSource.Create(width, height, 96, 96, PixelFormats.Bgra32, null, pixels, stride);
        bitmap.Freeze();
        return bitmap;
    }

    // Insert a valid PNG tEXt chunk to verify that the source metadata is stripped.
    private static byte[] PngWithText(string marker)
    {
        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(SyntheticBitmap()));
        using var output = new MemoryStream();
        encoder.Save(output);
        byte[] png = output.ToArray();
        byte[] payload = Encoding.ASCII.GetBytes("Comment\0" + marker);
        byte[] kind = Encoding.ASCII.GetBytes("tEXt");
        using var result = new MemoryStream();
        result.Write(png, 0, png.Length - 12); // The last PNG chunk is IEND.
        WriteBigEndian(result, (uint)payload.Length);
        result.Write(kind, 0, kind.Length);
        result.Write(payload, 0, payload.Length);
        WriteBigEndian(result, Crc32(kind.Concat(payload)));
        result.Write(png, png.Length - 12, 12);
        return result.ToArray();
    }

    private static void WriteBigEndian(Stream stream, uint value)
    {
        stream.WriteByte((byte)(value >> 24));
        stream.WriteByte((byte)(value >> 16));
        stream.WriteByte((byte)(value >> 8));
        stream.WriteByte((byte)value);
    }

    private static uint Crc32(IEnumerable<byte> bytes)
    {
        uint value = 0xffffffff;
        foreach (byte item in bytes)
        {
            value ^= item;
            for (int bit = 0; bit < 8; bit++) value = (value & 1) != 0 ? (value >> 1) ^ 0xedb88320 : value >> 1;
        }
        return value ^ 0xffffffff;
    }
}
