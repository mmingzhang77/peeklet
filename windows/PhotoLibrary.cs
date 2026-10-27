using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace Peeklet;

// Only the generated IDs and resized PNG copies are persisted. The caller
// chooses source files; this class never modifies or stores their paths.
internal sealed class PhotoLibrary
{
    private const int MaxCount = 30;
    private const int MaxBytes = 50 * 1024 * 1024;
    private const long MaxPixels = 100_000_000;
    private readonly string directory;
    private readonly string manifestPath;
    private readonly string journalPath;
    private readonly JsonSerializerOptions json = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase };
    private List<Guid> ids = new();

    private sealed class Manifest
    {
        public Manifest() { }
        public int Version { get; set; }
        public List<Guid>? Ids { get; set; }
    }
    private sealed class Journal
    {
        public Journal() { }
        public int Version { get; set; }
        public string? Operation { get; set; }
        public List<Guid>? Ids { get; set; }
    }

    public int Count => ids.Count;
    public IReadOnlyList<Guid> Ids => ids.AsReadOnly();

    public PhotoLibrary(string path)
    {
        directory = Path.GetFullPath(path);
        Directory.CreateDirectory(directory);
        if ((File.GetAttributes(directory) & FileAttributes.ReparsePoint) != 0) throw InvalidLibrary();
        manifestPath = Path.Combine(directory, "manifest.json");
        journalPath = Path.Combine(directory, ".transaction.json");
        ids = ReadManifest();
        Recover();
        ValidateCopies();
    }

    public void Import(IReadOnlyList<string> sources)
    {
        if (sources.Count == 0) return;
        if (sources.Count > MaxCount - Count) throw new InvalidDataException("The photo limit is 30.");
        var additions = sources.Select(_ => Guid.NewGuid()).ToList();
        foreach (var id in additions)
            if (File.Exists(CopyPath(id)) || File.Exists(PendingPath(id))) throw InvalidLibrary();
        WriteJournal("importing", additions);
        try
        {
            for (int i = 0; i < additions.Count; i++)
                WriteNew(CopyPath(additions[i]), ConvertToPng(sources[i]));
            var updated = new List<Guid>(ids);
            updated.AddRange(additions);
            WriteManifest(updated);
            ids = updated;
            DeleteRegular(journalPath);
        }
        catch
        {
            ids = ReadManifest();
            Recover();
            throw;
        }
    }

    public BitmapSource Image(int index)
    {
        if (index < 0 || index >= Count) throw InvalidLibrary();
        string path = CopyPath(ids[index]);
        RequireRegular(path);
        byte[] bytes = ReadBounded(path);
        using var stream = new MemoryStream(bytes, writable: false);
        var decoder = BitmapDecoder.Create(stream, BitmapCreateOptions.IgnoreColorProfile, BitmapCacheOption.OnLoad);
        var frame = decoder.Frames[0];
        if (frame.PixelWidth <= 0 || frame.PixelHeight <= 0 || frame.PixelWidth > 2048 || frame.PixelHeight > 2048)
            throw InvalidLibrary();
        frame.Freeze();
        return frame;
    }

    public void Remove(int index)
    {
        if (index < 0 || index >= Count) throw InvalidLibrary();
        RemoveIds(new List<Guid> { ids[index] });
    }

    public void RemoveAll() { if (Count > 0) RemoveIds(new List<Guid>(ids)); }

    private void RemoveIds(List<Guid> removal)
    {
        foreach (var id in removal)
        {
            RequireRegular(CopyPath(id));
            if (File.Exists(PendingPath(id))) throw InvalidLibrary();
        }
        WriteJournal("removing", removal);
        try
        {
            foreach (var id in removal) File.Move(CopyPath(id), PendingPath(id));
            var removalSet = new HashSet<Guid>(removal);
            var updated = ids.Where(id => !removalSet.Contains(id)).ToList();
            WriteManifest(updated);
            ids = updated;
            foreach (var id in removal) DeleteRegular(PendingPath(id));
            DeleteRegular(journalPath);
        }
        catch
        {
            ids = ReadManifest();
            Recover();
            throw;
        }
    }

    private void Recover()
    {
        if (!File.Exists(journalPath)) return;
        RequireRegular(journalPath);
        var journal = ReadJson<Journal>(journalPath);
        if (journal.Version != 1 || journal.Ids is null || journal.Ids.Count == 0 ||
            journal.Ids.Count > MaxCount || journal.Ids.Distinct().Count() != journal.Ids.Count)
            throw InvalidLibrary();
        int present = journal.Ids.Count(ids.Contains);
        if (present != 0 && present != journal.Ids.Count) throw InvalidLibrary();
        if (journal.Operation == "importing")
        {
            if (present == 0) foreach (var id in journal.Ids) DeleteRegular(CopyPath(id));
            else foreach (var id in journal.Ids) RequireRegular(CopyPath(id));
        }
        else if (journal.Operation == "removing")
        {
            foreach (var id in journal.Ids)
            {
                string copy = CopyPath(id), pending = PendingPath(id);
                if (File.Exists(copy)) RequireRegular(copy);
                if (File.Exists(pending)) RequireRegular(pending);
                if (present == journal.Ids.Count)
                {
                    if (File.Exists(copy) == File.Exists(pending)) throw InvalidLibrary();
                    if (File.Exists(pending)) File.Move(pending, copy);
                }
                else
                {
                    if (File.Exists(copy)) throw InvalidLibrary();
                    DeleteRegular(pending);
                }
            }
        }
        else throw InvalidLibrary();
        DeleteRegular(journalPath);
    }

    private List<Guid> ReadManifest()
    {
        if (!File.Exists(manifestPath)) return new List<Guid>();
        RequireRegular(manifestPath);
        var value = ReadJson<Manifest>(manifestPath);
        if (value.Version != 1 || value.Ids is null || value.Ids.Count > MaxCount ||
            value.Ids.Any(x => x == Guid.Empty) || value.Ids.Distinct().Count() != value.Ids.Count)
            throw InvalidLibrary();
        return value.Ids;
    }
    private void ValidateCopies() { foreach (var id in ids) RequireRegular(CopyPath(id)); }
    private void WriteManifest(List<Guid> value) => WriteAtomic(manifestPath, JsonSerializer.SerializeToUtf8Bytes(new Manifest { Version = 1, Ids = value }, json));
    private void WriteJournal(string op, List<Guid> value)
    {
        if (File.Exists(journalPath)) throw InvalidLibrary();
        WriteAtomic(journalPath, JsonSerializer.SerializeToUtf8Bytes(new Journal { Version = 1, Operation = op, Ids = value }, json));
    }
    private T ReadJson<T>(string path) where T : class
    {
        var info = new FileInfo(path);
        if (info.Length > 16384) throw InvalidLibrary();
        try { return JsonSerializer.Deserialize<T>(File.ReadAllBytes(path), json) ?? throw InvalidLibrary(); }
        catch (JsonException) { throw InvalidLibrary(); }
    }
    private void WriteAtomic(string path, byte[] data)
    {
        if (File.Exists(path)) RequireRegular(path);
        string temporary = Path.Combine(directory, ".tmp-" + Guid.NewGuid().ToString("N"));
        try
        {
            WriteNew(temporary, data);
            File.Move(temporary, path, overwrite: true);
        }
        finally { DeleteRegular(temporary); }
    }
    private static void WriteNew(string path, byte[] data)
    {
        using var output = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None);
        output.Write(data, 0, data.Length);
        output.Flush(flushToDisk: true);
    }
    private string CopyPath(Guid id) => Path.Combine(directory, id.ToString("N") + ".png");
    private string PendingPath(Guid id) => Path.Combine(directory, ".pending-" + id.ToString("N") + ".png");
    private static Exception InvalidLibrary() => new InvalidDataException("The photo library could not be read safely.");
    private static void RequireRegular(string path)
    {
        var attr = File.GetAttributes(path);
        if ((attr & (FileAttributes.Directory | FileAttributes.ReparsePoint)) != 0) throw InvalidLibrary();
    }
    private static void DeleteRegular(string path)
    {
        if (!File.Exists(path)) return;
        RequireRegular(path);
        File.Delete(path);
    }

    private static byte[] ReadBounded(string path)
    {
        RequireRegular(path);
        using var input = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
        if (input.Length <= 0 || input.Length > MaxBytes) throw new InvalidDataException("Image exceeds the size limit.");
        byte[] bytes = new byte[(int)input.Length];
        input.ReadExactly(bytes);
        if (input.ReadByte() != -1) throw new InvalidDataException("Image exceeds the size limit.");
        return bytes;
    }

    private static byte[] ConvertToPng(string path)
    {
        byte[] source = ReadBounded(path);
        bool jpeg = source.Length > 3 && source[0] == 0xff && source[1] == 0xd8 && source[2] == 0xff;
        bool png = source.Length > 8 && source.AsSpan(0, 8).SequenceEqual(new byte[] { 137, 80, 78, 71, 13, 10, 26, 10 });
        bool tiff = source.Length > 4 && ((source[0] == 0x49 && source[1] == 0x49 && source[2] == 42 && source[3] == 0) ||
                    (source[0] == 0x4d && source[1] == 0x4d && source[2] == 0 && source[3] == 42));
        if (!jpeg && !png && !tiff) throw new InvalidDataException("Unsupported image.");
        using var inspection = new MemoryStream(source, writable: false);
        var header = BitmapDecoder.Create(inspection, BitmapCreateOptions.DelayCreation, BitmapCacheOption.OnDemand).Frames[0];
        int width = header.PixelWidth, height = header.PixelHeight;
        if (width <= 0 || height <= 0 || (long)width * height > MaxPixels)
            throw new InvalidDataException("Image exceeds the size limit.");
        int orientation = 1;
        if (header.Metadata is BitmapMetadata metadata)
        {
            foreach (string query in new[] { "/app1/ifd/{ushort=274}", "/ifd/{ushort=274}" })
            {
                try
                {
                    object? value = metadata.GetQuery(query);
                    if (value is ushort n && n >= 1 && n <= 8) { orientation = n; break; }
                }
                catch (NotSupportedException) { }
                catch (ArgumentException) { }
                catch (COMException) { }
            }
        }
        using var imageStream = new MemoryStream(source, writable: false);
        var image = new BitmapImage();
        image.BeginInit();
        image.CacheOption = BitmapCacheOption.OnLoad;
        image.CreateOptions = BitmapCreateOptions.IgnoreColorProfile;
        image.StreamSource = imageStream;
        if (width >= height && width > 2048) image.DecodePixelWidth = 2048;
        if (height > width && height > 2048) image.DecodePixelHeight = 2048;
        image.EndInit();
        image.Freeze();
        BitmapSource raster = image;
        if (orientation != 1)
        {
            var transform = new TransformGroup();
            if (orientation == 2 || orientation == 4 || orientation == 5 || orientation == 7)
                transform.Children.Add(new ScaleTransform(orientation == 4 ? 1 : -1, orientation == 4 ? -1 : 1));
            if (orientation == 3) transform.Children.Add(new RotateTransform(180));
            if (orientation == 5 || orientation == 8) transform.Children.Add(new RotateTransform(270));
            if (orientation == 6 || orientation == 7) transform.Children.Add(new RotateTransform(90));
            raster = new TransformedBitmap(raster, transform);
        }
        // A new pixel-only frame does not carry the selected file's metadata.
        var pixels = new FormatConvertedBitmap(raster, PixelFormats.Pbgra32, null, 0);
        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(pixels));
        using var result = new MemoryStream();
        encoder.Save(result);
        return result.ToArray();
    }
}
