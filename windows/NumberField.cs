using System;
using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;

namespace Tide;

/// Editable number with up/down buttons, the Windows counterpart of the Mac's text field + stepper.
sealed class NumberField : StackPanel {
    // Wide enough for four digits plus the clear (×) button the Fluent text box shows while editing.
    readonly TextBox box = new() {
        Width = 104,
        TextAlignment = TextAlignment.Right,
        VerticalContentAlignment = VerticalAlignment.Center,
    };
    double value;

    public double Minimum { get; set; }
    public double Maximum { get; set; } = 100;
    public double Step { get; set; } = 1;
    public int Decimals { get; set; }

    public event Action<double>? ValueChanged;

    public NumberField() {
        Orientation = Orientation.Horizontal;
        VerticalAlignment = VerticalAlignment.Center;
        Children.Add(box);
        Children.Add(Spin(IconFont.ChevronUp, +1));
        Children.Add(Spin(IconFont.ChevronDown, -1));

        box.LostKeyboardFocus += (_, _) => Commit();
        box.PreviewKeyDown += (_, e) => {
            if (e.Key == Key.Enter) { Commit(); e.Handled = true; }
            else if (e.Key == Key.Up) { Nudge(+1); e.Handled = true; }
            else if (e.Key == Key.Down) { Nudge(-1); e.Handled = true; }
        };
    }

    RepeatButton Spin(string glyph, int direction) {
        var b = new RepeatButton {
            Content = new TextBlock { Text = glyph, FontFamily = new FontFamily(IconFont.Name), FontSize = 10 },
            Width = 32,
            MinWidth = 0,
            Padding = new Thickness(0),
            Margin = new Thickness(4, 0, 0, 0),
            VerticalAlignment = VerticalAlignment.Stretch,
            Focusable = false,
        };
        b.Click += (_, _) => Nudge(direction);
        return b;
    }

    public double Value {
        get => value;
        set { this.value = Clean(value); box.Text = this.value.ToString(Format, CultureInfo.CurrentCulture); }
    }

    string Format => Decimals == 0 ? "0" : "0." + new string('#', Decimals);

    double Clean(double v) => Math.Round(Math.Clamp(v, Minimum, Maximum), Decimals);

    void Nudge(int direction) {
        Commit();
        Set(value + direction * Step);
    }

    /// Applies whatever is typed in the box. Also runs when the box loses focus or Enter is pressed.
    public void Commit() {
        if (double.TryParse(box.Text, NumberStyles.Float, CultureInfo.CurrentCulture, out var typed)) Set(typed);
        else Value = value;   // put back the last good value
    }

    void Set(double v) {
        double old = value;
        Value = v;
        if (value != old) ValueChanged?.Invoke(value);
    }
}
