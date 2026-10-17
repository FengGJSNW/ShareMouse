using System;
using System.Collections.Generic;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Interop;
using System.Windows.Data;
using System.Runtime.InteropServices;
using Microsoft.Win32;

namespace ShareMouse;

// Presentation-only preferences; deliberately separate from connection and input settings.
internal static class Theme
{
    private static readonly Dictionary<string, SolidColorBrush> brushes = new();
    // A binding prevents WPF from freezing a shared palette brush when a template or
    // Drawing uses it. Keep brush identity stable for code-created utility windows too.
    private sealed class PaletteColor : DependencyObject
    {
        public static readonly DependencyProperty ValueProperty = DependencyProperty.Register(nameof(Value), typeof(Color), typeof(PaletteColor));
        public Color Value
        {
            get => (Color)GetValue(ValueProperty); set => SetValue(ValueProperty, value);
        }
    }
    private static readonly Dictionary<string, PaletteColor> colorsByName = new();
    public static string Mode { get; private set; } = "system";
    public static SolidColorBrush Brush(string name) => brushes[name];
    public static bool Motion => SystemParameters.ClientAreaAnimation && !SystemParameters.HighContrast;
    public static void Install()
    {
        using (var key = Registry.CurrentUser.OpenSubKey(@"Software\ShareMouse\Appearance"))
            Mode = key?.GetValue("Theme") is string saved && saved is "light" or "dark" ? saved : "system";
        Apply();
        EventManager.RegisterClassHandler(typeof(TabControl), Selector.SelectionChangedEvent, new SelectionChangedEventHandler((sender, e) =>
        {
            if (ReferenceEquals(sender, e.OriginalSource) && sender is TabControl tabs && tabs.Name == "MainNavigation" && tabs.SelectedIndex >= 0)
            {
                selectedModule = tabs.SelectedIndex;
                Apply();
            }
        }));
        SystemEvents.UserPreferenceChanged += (_, _) => Application.Current.Dispatcher.BeginInvoke(new Action(Apply));
        EventManager.RegisterClassHandler(typeof(Window), FrameworkElement.LoadedEvent, new RoutedEventHandler((sender, e) =>
        {
            if (!ReferenceEquals(sender, e.OriginalSource))
                return;
            var window = (Window)sender;
            if (window.Tag as string is "MCP presentation" or "notification")
                return;
            if (!window.AllowsTransparency)
                window.SetResourceReference(Control.BackgroundProperty, "CanvasBrush");
            window.SetResourceReference(Control.ForegroundProperty, "TextBrush");
            window.FontFamily = new FontFamily("Segoe UI Variable Text, Segoe UI, Microsoft YaHei UI");
            window.FontSize = 13;
            window.UseLayoutRounding = true;
            TitleBar(window);
            if (window.Content is FrameworkElement content)
                Reveal(content);
        }));
        EventManager.RegisterClassHandler(typeof(CheckBox), ToggleButton.CheckedEvent, new RoutedEventHandler(SwitchChanged));
        EventManager.RegisterClassHandler(typeof(CheckBox), ToggleButton.UncheckedEvent, new RoutedEventHandler(SwitchChanged));
        EventManager.RegisterClassHandler(typeof(ButtonBase), UIElement.PreviewMouseLeftButtonDownEvent, new MouseButtonEventHandler((s, _) => Press((ButtonBase)s, .97)), true);
        EventManager.RegisterClassHandler(typeof(ButtonBase), UIElement.PreviewMouseLeftButtonUpEvent, new MouseButtonEventHandler((s, _) => Press((ButtonBase)s, 1)), true);
        EventManager.RegisterClassHandler(typeof(ButtonBase), UIElement.LostMouseCaptureEvent, new MouseEventHandler((s, _) => Press((ButtonBase)s, 1)), true);
    }
    public static void SetMode(string value)
    {
        var mode = value is "light" or "dark" ? value : "system";
        if (Mode == mode)
            return;
        Mode = mode;
        try
        {
            using var key = Registry.CurrentUser.CreateSubKey(@"Software\ShareMouse\Appearance");
            key.SetValue("Theme", Mode);
        }
        catch (System.Security.SecurityException) { }
        catch (UnauthorizedAccessException) { }
        Apply();
    }
    private static int selectedModule;
    private static bool darkTitle;
    private static (bool Dark, bool HighContrast, int Module)? appliedPalette;
    [DllImport("dwmapi.dll")] private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);
    private static void TitleBar(Window window)
    {
        if (window.WindowStyle == WindowStyle.None)
            return;
        var handle = new WindowInteropHelper(window).Handle;
        if (handle == IntPtr.Zero)
            return;
        var dark = darkTitle ? 1 : 0;
        _ = DwmSetWindowAttribute(handle, 20, ref dark, sizeof(int));
    }
    private static void Apply()
    {
        using var system = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
        var dark = Mode == "dark" || Mode == "system" && system?.GetValue("AppsUseLightTheme") is int value && value == 0;
        var palette = (dark, SystemParameters.HighContrast, selectedModule);
        if (appliedPalette == palette)
            return;
        appliedPalette = palette;
        darkTitle = dark && !SystemParameters.HighContrast;
        var colors = new Dictionary<string, string>
        {
            ["Elevation"] = dark ? "#344452" : "#FFF9EF",
            ["Well"] = dark ? "#18242D" : "#DDD9CE",
            ["KeyEdge"] = dark ? "#101820" : "#ACB6B8",
            ["Highlight"] = dark ? "#587082" : "#FFF9EE",
            ["Canvas"] = dark ? "#323232" : "#ECECEC",
            ["Sidebar"] = dark ? "#282828" : "#F2F2F2",
            ["Surface"] = dark ? "#1E1E1E" : "#FFFFFF",
            ["Border"] = dark ? "#19FFFFFF" : "#19000000",
            ["KeyFace"] = dark ? "#25313D" : "#F3F3F3",
            ["Text"] = dark ? "#D8FFFFFF" : "#D8000000",
            ["Muted"] = dark ? "#8CFFFFFF" : "#7F000000",
            ["Accent"] = dark ? "#8CBDDD" : "#315F7D",
            ["Selection"] = dark ? "#284C67" : "#D2E2E9",
            ["Hover"] = dark ? "#354957" : "#DBE5E7",
            ["Danger"] = dark ? "#FFAAA5" : "#B42318",
            ["Good"] = dark ? "#90D5B3" : "#22734E",
            ["Warning"] = dark ? "#F1C27B" : "#935900"
        };
        var modules = dark ? new[] { "#8AB7DD", "#72C8B8", "#BF9FD2", "#D9B579", "#A8B9D0" } : new[] { "#356D98", "#287A74", "#785483", "#9E6D2B", "#5E6C7F" };
        colors["Module"] = modules[Math.Clamp(selectedModule, 0, 4)];
        var accent = (Color)ColorConverter.ConvertFromString(colors["Module"]);
        var surface = (Color)ColorConverter.ConvertFromString(colors["Surface"]);
        colors["ModuleSurface"] = $"#{(byte)(surface.R * .88 + accent.R * .12):X2}{(byte)(surface.G * .88 + accent.G * .12):X2}{(byte)(surface.B * .88 + accent.B * .12):X2}";
        var sidebar = (Color)ColorConverter.ConvertFromString(colors["Sidebar"]);
        colors["ModuleSelection"] = $"#{(byte)(sidebar.R * .84 + accent.R * .16):X2}{(byte)(sidebar.G * .84 + accent.G * .16):X2}{(byte)(sidebar.B * .84 + accent.B * .16):X2}";
        foreach (var item in colors)
        {
            var color = (Color)ColorConverter.ConvertFromString(item.Value);
            if (SystemParameters.HighContrast)
                color = item.Key switch
                {
                    "Text" or "Muted" => SystemColors.WindowTextColor,
                    "Accent" or "Selection" => SystemColors.HighlightColor,
                    "Border" => SystemColors.WindowTextColor,
                    _ => SystemColors.WindowColor
                };
            Application.Current.Resources[item.Key + "Color"] = color;
            if (!colorsByName.TryGetValue(item.Key, out var entry))
            {
                entry = new PaletteColor { Value = color };
                colorsByName[item.Key] = entry;
                var brush = new SolidColorBrush();
                BindingOperations.SetBinding(brush, SolidColorBrush.ColorProperty, new Binding(nameof(PaletteColor.Value)) { Source = entry, Mode = BindingMode.OneWay });
                brushes[item.Key] = brush;
                Application.Current.Resources[item.Key + "Brush"] = brush;
            }
            else
                entry.Value = color;
        }
        Application.Current.Resources["ControlMaterial"] = Material();
        // Native template fallbacks must follow the app palette, not the OS theme.
        foreach (var item in new (ResourceKey Key, string Color)[]{
            (SystemColors.ControlBrushKey,"Surface"),(SystemColors.WindowBrushKey,"Surface"),
            (SystemColors.ControlTextBrushKey,"Text"),(SystemColors.WindowTextBrushKey,"Text"),
            (SystemColors.GrayTextBrushKey,"Muted"),(SystemColors.ControlDarkBrushKey,"Border"),
            (SystemColors.ControlLightBrushKey,"Elevation"),(SystemColors.ControlLightLightBrushKey,"Highlight"),
            (SystemColors.HighlightBrushKey,"Selection"),(SystemColors.HighlightTextBrushKey,"Text")
        })
            Application.Current.Resources[item.Key] = Brush(item.Color);
        foreach (Window window in Application.Current.Windows)
            TitleBar(window);
    }

    private static void SwitchChanged(object sender, RoutedEventArgs e)
    {
        var check = (CheckBox)sender;
        if (!ReferenceEquals(sender, e.OriginalSource))
            return;
        if (check.Template?.FindName("Knob", check) is FrameworkElement knob)
        {
            var transform = new TranslateTransform(check.IsChecked == true ? 18 : 0, 0);
            knob.RenderTransform = transform;
            if (Motion)
                transform.BeginAnimation(TranslateTransform.XProperty, new DoubleAnimation(check.IsChecked == true ? 0 : 18, check.IsChecked == true ? 18 : 0, TimeSpan.FromMilliseconds(180)) { EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut }, FillBehavior = FillBehavior.Stop });
        }
    }
    private static readonly Dictionary<(string, string), LinearGradientBrush> materials = new();
    public static LinearGradientBrush Material(string top = "Elevation", string bottom = "KeyFace")
    {
        if (materials.TryGetValue((top, bottom), out var cached))
            return cached;
        var result = new LinearGradientBrush { StartPoint = new Point(0, 0), EndPoint = new Point(0, 1) };
        foreach (var name in new[] { top, bottom })
        {
            var stop = new GradientStop { Offset = result.GradientStops.Count };
            BindingOperations.SetBinding(stop, GradientStop.ColorProperty, new Binding(nameof(SolidColorBrush.Color)) { Source = Brush(name) });
            result.GradientStops.Add(stop);
        }
        materials[(top, bottom)] = result;
        return result;
    }
    public static void Keycap(Border key)
    {
        var face = key.Child;
        key.Child = null;
        key.CornerRadius = new CornerRadius(7);
        key.Padding = new Thickness(0, 0, 0, 3);
        key.Background = Brush("KeyEdge");
        key.Child = new Border { CornerRadius = new CornerRadius(6), Background = Material(), BorderBrush = Brush("Highlight"), BorderThickness = new Thickness(0, 1, 0, 0), Child = face };
        // The dark base supplies depth without a blur surface per key.
        key.RenderTransform = new TranslateTransform();
        void Lift(double y)
        {
            if (Motion)
                ((TranslateTransform)key.RenderTransform).BeginAnimation(TranslateTransform.YProperty, new DoubleAnimation(y, TimeSpan.FromMilliseconds(y > 0 ? 80 : 170)) { EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut } });
        }
        key.MouseEnter += (_, _) => Lift(-1.5);
        key.MouseLeave += (_, _) => Lift(0);
        key.PreviewMouseLeftButtonDown += (_, _) => Lift(1.5);
        key.PreviewMouseLeftButtonUp += (_, _) => Lift(key.IsMouseOver ? -1.5 : 0);
        key.LostMouseCapture += (_, _) => Lift(0);
    }
    public static void KeycapSelection(Border key, bool selected)
    {
        if (key.Child is Border face)
            face.Background = selected ? Brush("Selection") : Material();
    }
    public static void Reveal(FrameworkElement content)
    {
        content.BeginAnimation(UIElement.OpacityProperty, null);
        if (!Motion)
            return;
        content.BeginAnimation(UIElement.OpacityProperty, new DoubleAnimation(.3, 1, TimeSpan.FromMilliseconds(220)) { EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut }, FillBehavior = FillBehavior.Stop });
    }
    private static void Press(ButtonBase button, double to)
    {
        if (!Motion || !button.IsEnabled)
            return;
        if (button.RenderTransform is not ScaleTransform || button.RenderTransform.IsFrozen)
        {
            button.RenderTransformOrigin = new Point(.5, .5);
            button.RenderTransform = new ScaleTransform(1, 1);
        }
        var transform = (ScaleTransform)button.RenderTransform;
        var animation = new DoubleAnimation(to, TimeSpan.FromMilliseconds(to < 1 ? 90 : 180)) { EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut } };
        transform.BeginAnimation(ScaleTransform.ScaleXProperty, animation);
        transform.BeginAnimation(ScaleTransform.ScaleYProperty, animation);
    }
}
