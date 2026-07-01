using System.IO;
using System.Windows;
using System.Windows.Input;
using System.Windows.Media.Imaging;
using Windows.Media.Control;
using Windows.Storage.Streams;

namespace AudibleRemote;

/// <summary>
/// A minimal "now playing" card that mirrors and controls whatever media session
/// Windows currently considers active (Audible in a browser, the Audible app, etc.)
/// via the System Media Transport Controls (SMTC) API. It never touches DRM — it
/// only reads the OS-provided cover/title/chapter and sends standard transport
/// commands, exactly like the keyboard media keys.
/// </summary>
public partial class MainWindow : Window
{
    private GlobalSystemMediaTransportControlsSessionManager? _manager;
    private GlobalSystemMediaTransportControlsSession? _session;

    // Segoe MDL2 Assets glyphs
    private const string GlyphPlay = "";
    private const string GlyphPause = "";

    public MainWindow()
    {
        InitializeComponent();
        Loaded += OnLoaded;
    }

    private async void OnLoaded(object sender, RoutedEventArgs e)
    {
        try
        {
            _manager = await GlobalSystemMediaTransportControlsSessionManager.RequestAsync();
            _manager.CurrentSessionChanged += OnCurrentSessionChanged;
            HookCurrentSession();
        }
        catch (Exception ex)
        {
            SetStatus("Media control unavailable", ex.Message);
        }
    }

    // ---- Session wiring ---------------------------------------------------

    private void OnCurrentSessionChanged(
        GlobalSystemMediaTransportControlsSessionManager sender,
        CurrentSessionChangedEventArgs args)
        => Dispatcher.Invoke(HookCurrentSession);

    private void HookCurrentSession()
    {
        if (_session != null)
        {
            _session.MediaPropertiesChanged -= OnMediaPropertiesChanged;
            _session.PlaybackInfoChanged -= OnPlaybackInfoChanged;
        }

        _session = _manager?.GetCurrentSession();

        if (_session != null)
        {
            _session.MediaPropertiesChanged += OnMediaPropertiesChanged;
            _session.PlaybackInfoChanged += OnPlaybackInfoChanged;
        }

        RefreshPlayback();
        _ = RefreshMediaAsync();
    }

    private void OnMediaPropertiesChanged(
        GlobalSystemMediaTransportControlsSession sender,
        MediaPropertiesChangedEventArgs args)
        => Dispatcher.Invoke(() => _ = RefreshMediaAsync());

    private void OnPlaybackInfoChanged(
        GlobalSystemMediaTransportControlsSession sender,
        PlaybackInfoChangedEventArgs args)
        => Dispatcher.Invoke(RefreshPlayback);

    // ---- Rendering --------------------------------------------------------

    private void RefreshPlayback()
    {
        if (_session == null)
        {
            PlayPauseGlyph.Text = GlyphPlay;
            return;
        }

        try
        {
            var info = _session.GetPlaybackInfo();
            bool playing = info.PlaybackStatus
                == GlobalSystemMediaTransportControlsSessionPlaybackStatus.Playing;
            PlayPauseGlyph.Text = playing ? GlyphPause : GlyphPlay;
        }
        catch
        {
            // Session can vanish between the null check and the call; ignore.
        }
    }

    private async Task RefreshMediaAsync()
    {
        if (_session == null)
        {
            SetStatus("Nothing playing", "Start an audiobook to see it here");
            CoverBrush.ImageSource = null;
            return;
        }

        try
        {
            var props = await _session.TryGetMediaPropertiesAsync();
            TitleText.Text = string.IsNullOrWhiteSpace(props.Title) ? "(unknown title)" : props.Title;
            ChapterText.Text = props.Artist ?? props.AlbumTitle ?? "";
            await LoadThumbnailAsync(props.Thumbnail);
        }
        catch
        {
            // Transient WinRT/session errors — leave the last good frame on screen.
        }
    }

    private async Task LoadThumbnailAsync(IRandomAccessStreamReference? thumbRef)
    {
        if (thumbRef == null)
        {
            CoverBrush.ImageSource = null;
            return;
        }

        try
        {
            using var ras = await thumbRef.OpenReadAsync();
            if (ras is null || ras.Size == 0)
            {
                CoverBrush.ImageSource = null;
                return;
            }

            using var reader = new DataReader(ras);
            await reader.LoadAsync((uint)ras.Size);
            var bytes = new byte[ras.Size];
            reader.ReadBytes(bytes);

            var bmp = new BitmapImage();
            bmp.BeginInit();
            bmp.CacheOption = BitmapCacheOption.OnLoad;
            bmp.StreamSource = new MemoryStream(bytes);
            bmp.EndInit();
            bmp.Freeze();
            CoverBrush.ImageSource = bmp;
        }
        catch
        {
            CoverBrush.ImageSource = null;
        }
    }

    private void SetStatus(string title, string subtitle)
    {
        TitleText.Text = title;
        ChapterText.Text = subtitle;
    }

    // ---- Transport --------------------------------------------------------

    private async void PlayPause_Click(object sender, RoutedEventArgs e)
    {
        if (_session is null) return;
        try { await _session.TryTogglePlayPauseAsync(); } catch { }
    }

    private async void Next_Click(object sender, RoutedEventArgs e)
    {
        if (_session is null) return;
        try { await _session.TrySkipNextAsync(); } catch { }
    }

    private async void Prev_Click(object sender, RoutedEventArgs e)
    {
        if (_session is null) return;
        try { await _session.TrySkipPreviousAsync(); } catch { }
    }

    // ---- Window chrome ----------------------------------------------------

    private void Root_MouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        if (e.ChangedButton == MouseButton.Left)
        {
            try { DragMove(); } catch { }
        }
    }

    private void Pin_Click(object sender, RoutedEventArgs e)
    {
        Topmost = !Topmost;
        PinGlyph.Opacity = Topmost ? 1.0 : 0.45;
    }

    private void Close_Click(object sender, RoutedEventArgs e) => Close();
}
