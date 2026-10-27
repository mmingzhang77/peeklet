using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;
using Microsoft.Win32;
using Forms = System.Windows.Forms;

namespace Peeklet;

// Hold state is independent of the window so it can be exercised without a display.
internal sealed class PeekState
{
    private long startedAt;
    public bool Held { get; private set; }
    public void Begin(long now) { startedAt = now; Held = true; }
    public void End() => Held = false;
    public bool ShouldHide(long now, bool buttonDown, bool pointerInside, bool sameForeground) =>
        !Held || !buttonDown || !pointerInside || !sameForeground || now < startedAt || now - startedAt >= 10_000;
    public bool ShouldReveal(long now) => Held && now >= startedAt && now - startedAt >= 160 && now - startedAt < 10_000;
}

internal sealed class PeekWindow : Window
{
    private readonly PhotoLibrary library;
    private readonly PreviewWindow preview = new();
    private readonly DispatcherTimer timer = new() { Interval = TimeSpan.FromMilliseconds(25) };
    private readonly Forms.NotifyIcon tray;
    private readonly Border button;
    private readonly PeekState state = new();
    private Point start;
    private IntPtr foreground;
    private int selected;
    private int size;
    private int entrance = 1;
    private bool bright = true;
    private readonly double[] entranceSizes = { 24, 36, 44 };
    private readonly Size[] previewSizes = { new(150, 225), new(180, 270), new(230, 345) };

    public PeekWindow(PhotoLibrary library)
    {
        this.library = library;
        Width = Height = 36;
        WindowStyle = WindowStyle.None;
        ResizeMode = ResizeMode.NoResize;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        Topmost = true;
        ShowInTaskbar = false;
        ShowActivated = false;
        WindowStartupLocation = WindowStartupLocation.Manual;
        Title = "Peeklet";
        button = new Border
        {
            CornerRadius = new CornerRadius(7),
            Background = new SolidColorBrush(Color.FromArgb(240, 40, 40, 40)),
            Child = new Border
            {
                Width = 12, Height = 3, CornerRadius = new CornerRadius(1.5),
                Background = Brushes.White, HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center
            }
        };
        Content = button;
        SourceInitialized += (_, _) => Native.MakeNonActivating(this);
        PreviewMouseLeftButtonDown += Down;
        PreviewMouseMove += Move;
        PreviewMouseLeftButtonUp += (_, _) => EndPeek();
        MouseLeave += (_, _) => EndPeek();
        LostMouseCapture += (_, _) => EndPeek();
        MouseWheel += (_, e) => { Cycle(); e.Handled = true; };
        // A nonempty menu must exist before the first ContextMenuOpening event.
        ContextMenu = MakeContextMenu();
        ContextMenuOpening += (_, _) => { EndPeek(); RebuildContextMenu(ContextMenu!); };
        timer.Tick += (_, _) => UpdatePeek();

        tray = new Forms.NotifyIcon { Text = "Peeklet", Icon = System.Drawing.SystemIcons.Application, Visible = true };
        tray.MouseClick += (_, e) => { if (e.Button == Forms.MouseButtons.Left) FindEntrance(); };
        var trayMenu = new Forms.ContextMenuStrip();
        trayMenu.Opening += (_, _) => RebuildTrayMenu(trayMenu);
        tray.ContextMenuStrip = trayMenu;
        Application.Current.Exit += (_, _) => { tray.Visible = false; tray.Dispose(); };
        ResetPosition();
    }

    private void Down(object sender, MouseButtonEventArgs e)
    {
        state.Begin(Environment.TickCount64);
        start = PointToScreen(e.GetPosition(this));
        foreground = Native.GetForegroundWindow();
        CaptureMouse();
        timer.Start();
        e.Handled = true;
    }

    private void Move(object sender, MouseEventArgs e)
    {
        if (!state.Held || e.LeftButton != MouseButtonState.Pressed) return;
        Point now = PointToScreen(e.GetPosition(this));
        if (Math.Abs(now.X - start.X) < 5 && Math.Abs(now.Y - start.Y) < 5) return;
        EndPeek();
        try { DragMove(); } catch (InvalidOperationException) { }
    }

    private void UpdatePeek()
    {
        long now = Environment.TickCount64;
        Point pointer = Mouse.GetPosition(this);
        bool inside = pointer.X >= 0 && pointer.Y >= 0 && pointer.X < ActualWidth && pointer.Y < ActualHeight;
        if (state.ShouldHide(now, Mouse.LeftButton == MouseButtonState.Pressed, inside,
                             Native.GetForegroundWindow() == foreground))
        {
            EndPeek();
            return;
        }
        if (!state.ShouldReveal(now) || preview.IsVisible || library.Count == 0) return;
        try
        {
            preview.SetImage(library.Image(selected));
            PlacePreview();
            preview.Show();
            bright = false;
            UpdateAppearance();
        }
        catch { EndPeek(); ShowError("The selected photo could not be opened."); }
    }

    private void EndPeek()
    {
        state.End();
        timer.Stop();
        if (IsMouseCaptured) ReleaseMouseCapture();
        preview.Hide();
        preview.ClearImage();
    }

    private void Cycle()
    {
        if (library.Count == 0) return;
        selected = (selected + 1) % library.Count;
        if (preview.IsVisible)
        {
            try { preview.SetImage(library.Image(selected)); }
            catch { EndPeek(); ShowError("The selected photo could not be opened."); }
        }
    }

    private void PlacePreview()
    {
        var display = PresentationSource.FromVisual(this)?.CompositionTarget;
        double scaleX = display?.TransformToDevice.M11 ?? 1, scaleY = display?.TransformToDevice.M22 ?? 1;
        var center = new System.Drawing.Point((int)((Left + Width / 2) * scaleX), (int)((Top + Height / 2) * scaleY));
        var area = Forms.Screen.FromPoint(center).WorkingArea;
        double left = area.Left / scaleX, top = area.Top / scaleY;
        double right = area.Right / scaleX, bottom = area.Bottom / scaleY;
        preview.Width = previewSizes[size].Width;
        preview.Height = previewSizes[size].Height;
        double x = Left + Width + 10;
        if (x + preview.Width > right) x = Left - preview.Width - 10;
        preview.Left = Math.Max(left, Math.Min(x, right - preview.Width));
        preview.Top = Math.Max(top, Math.Min(Top + Height / 2 - preview.Height / 2, bottom - preview.Height));
    }

    private void AddPhotos()
    {
        EndPeek();
        var picker = new OpenFileDialog
        {
            Title = "Add Photos to Peeklet",
            Filter = "Images (*.jpg;*.jpeg;*.png;*.tif;*.tiff)|*.jpg;*.jpeg;*.png;*.tif;*.tiff",
            Multiselect = true, CheckFileExists = true
        };
        if (picker.ShowDialog() != true) return;
        try { int before = library.Count; library.Import(picker.FileNames); if (library.Count > before) selected = before; }
        catch { ShowError("Could not add these photos. Select supported images within the stated size and count limits."); }
    }

    private void Remove(bool all)
    {
        EndPeek();
        if (library.Count == 0) return;
        string title = all ? "Remove all imported photos?" : "Remove the current imported photo?";
        if (MessageBox.Show("This removes only Peeklet's imported copies. Original files will not be changed.",
            title, MessageBoxButton.YesNo, MessageBoxImage.Question, MessageBoxResult.No) != MessageBoxResult.Yes) return;
        try { if (all) library.RemoveAll(); else library.Remove(selected); }
        catch { ShowError("The imported copies could not be removed completely."); }
        selected = Math.Max(0, Math.Min(selected, library.Count - 1));
    }

    private void SetEntrance(int index)
    {
        EndPeek();
        entrance = index;
        Width = Height = entranceSizes[entrance];
    }
    private void ResetPosition()
    {
        Rect area = SystemParameters.WorkArea;
        Left = area.Right - Width - 12;
        Top = area.Top + 12;
    }
    private void FindEntrance() { EndPeek(); ResetPosition(); bright = true; UpdateAppearance(); Show(); }
    private void UpdateAppearance()
    {
        button.Background = new SolidColorBrush(Color.FromArgb(bright ? (byte)240 : (byte)25, 40, 40, 40));
        if (button.Child is Border mark)
            mark.Background = new SolidColorBrush(Color.FromArgb(bright ? (byte)230 : (byte)100, 245, 245, 245));
    }
    private static void ShowError(string text) => MessageBox.Show(text, "Peeklet", MessageBoxButton.OK, MessageBoxImage.Warning);
    private void Quit() { EndPeek(); tray.Visible = false; preview.Close(); Application.Current.Shutdown(); }

    private sealed record MenuEntry(string Title, Action? Action = null, bool Enabled = true,
                                    bool Checked = false, List<MenuEntry>? Children = null);

    private List<MenuEntry> MenuEntries()
    {
        var entries = new List<MenuEntry>
        {
            new("Add Photos…", AddPhotos, library.Count < 30)
        };
        for (int i = 0; i < library.Count; i++)
        {
            int index = i;
            entries.Add(new($"Photo {i + 1}", () => { EndPeek(); selected = index; }, true, selected == i));
        }
        entries.Add(new("Remove Current Photo…", () => Remove(false), library.Count > 0));
        entries.Add(new("Remove All Photos…", () => Remove(true), library.Count > 0));
        var previews = new List<MenuEntry>
        {
            new("Small (150 × 225)", () => { EndPeek(); size = 0; }, true, size == 0),
            new("Medium (180 × 270)", () => { EndPeek(); size = 1; }, true, size == 1),
            new("Large (230 × 345)", () => { EndPeek(); size = 2; }, true, size == 2)
        };
        entries.Add(new("Preview Size", Children: previews));
        var entrances = new List<MenuEntry>();
        for (int i = 0; i < entranceSizes.Length; i++)
        {
            int index = i;
            entrances.Add(new($"{entranceSizes[i]} × {entranceSizes[i]}", () => SetEntrance(index), true, entrance == i));
        }
        entries.Add(new("Entrance Size", Children: entrances));
        entries.Add(new(bright ? "Use Subtle Appearance" : "Use Bright Appearance", () => { bright = !bright; UpdateAppearance(); }));
        entries.Add(new("Quit Peeklet", Quit));
        return entries;
    }

    private ContextMenu MakeContextMenu()
    {
        var menu = new ContextMenu();
        RebuildContextMenu(menu);
        return menu;
    }
    private void RebuildContextMenu(ContextMenu menu)
    {
        menu.Items.Clear();
        foreach (var entry in MenuEntries())
            menu.Items.Add(MakeMenuItem(entry));
    }
    private static MenuItem MakeMenuItem(MenuEntry entry)
    {
        var item = new MenuItem { Header = entry.Title, IsEnabled = entry.Enabled, IsCheckable = entry.Checked, IsChecked = entry.Checked };
        if (entry.Children != null)
            foreach (var child in entry.Children) item.Items.Add(MakeMenuItem(child));
        if (entry.Action != null) item.Click += (_, e) => { e.Handled = true; entry.Action(); };
        return item;
    }
    private static Forms.ToolStripMenuItem MakeTrayItem(MenuEntry entry)
    {
        var item = new Forms.ToolStripMenuItem(entry.Title) { Enabled = entry.Enabled, Checked = entry.Checked };
        if (entry.Children != null)
            foreach (var child in entry.Children) item.DropDownItems.Add(MakeTrayItem(child));
        if (entry.Action != null) item.Click += (_, _) => entry.Action();
        return item;
    }
    private void RebuildTrayMenu(Forms.ContextMenuStrip menu)
    {
        EndPeek();
        menu.Items.Clear();
        foreach (var entry in MenuEntries()) menu.Items.Add(MakeTrayItem(entry));
    }
}

internal sealed class PreviewWindow : Window
{
    private readonly Image image;
    public PreviewWindow()
    {
        WindowStyle = WindowStyle.None;
        ResizeMode = ResizeMode.NoResize;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        Topmost = true;
        ShowInTaskbar = false;
        ShowActivated = false;
        IsHitTestVisible = false;
        image = new Image { Stretch = Stretch.Uniform, Margin = new Thickness(4) };
        Content = new Border { Background = new SolidColorBrush(Color.FromArgb(240, 18, 18, 18)),
            CornerRadius = new CornerRadius(8), Child = image };
        SourceInitialized += (_, _) => Native.MakeNonActivating(this);
    }
    public void SetImage(System.Windows.Media.Imaging.BitmapSource value) => image.Source = value;
    public void ClearImage() => image.Source = null;
}

internal static class Native
{
    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")]
    private static extern IntPtr GetWindowLongPtr(IntPtr handle, int index);
    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW")]
    private static extern IntPtr SetWindowLongPtr(IntPtr handle, int index, IntPtr value);
    [DllImport("user32.dll")]
    internal static extern IntPtr GetForegroundWindow();
    internal static void MakeNonActivating(Window window)
    {
        IntPtr handle = new WindowInteropHelper(window).Handle;
        long style = GetWindowLongPtr(handle, -20).ToInt64();
        SetWindowLongPtr(handle, -20, new IntPtr(style | 0x08000000L | 0x00000080L));
    }
}
