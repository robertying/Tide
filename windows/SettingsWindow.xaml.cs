using System;
using System.Windows;

namespace Tide;

/// The Settings window, laid out like the Display pane of the macOS app. Every change is saved and
/// applied immediately; there is no OK or Apply button.
public partial class SettingsWindow : Window {
    readonly Settings settings;
    readonly Dimmer dimmer;
    bool loading;

    internal SettingsWindow(Settings settings, Dimmer dimmer) {
        this.settings = settings;
        this.dimmer = dimmer;
        InitializeComponent();
        Load();

        EnabledBox.Click += (_, _) => Change(() => settings.Enabled = EnabledBox.IsChecked == true);
        AfterField.ValueChanged += v => Change(() => settings.DimAfter = (int)v);
        LevelSlider.ValueChanged += (_, _) => Change(() => settings.DimLevel = Math.Round(LevelSlider.Value) / 100);
        FadeOutField.ValueChanged += v => Change(() => settings.FadeOut = v);
        FadeInField.ValueChanged += v => Change(() => settings.FadeIn = v);
        PreviewButton.Click += (_, _) => dimmer.Preview();
        ResetButton.Click += (_, _) => {
            Change(() => {
                settings.DimAfter = Settings.DefaultDimAfter;
                settings.DimLevel = Settings.DefaultDimLevel;
                settings.FadeOut = Settings.DefaultFadeOut;
                settings.FadeIn = Settings.DefaultFadeIn;
            });
            Load();
        };

        // Keep up with changes made from the tray menu while the window is open.
        dimmer.StatusChanged += Refresh;
        Closed += (_, _) => dimmer.StatusChanged -= Refresh;
        // A number typed but not yet confirmed would otherwise be lost when the window closes.
        Closing += (_, _) => { AfterField.Commit(); FadeOutField.Commit(); FadeInField.Commit(); };
        Refresh();
    }

    void Load() {
        loading = true;
        EnabledBox.IsChecked = settings.Enabled;
        AfterField.Value = settings.DimAfter;
        LevelSlider.Value = Math.Round(settings.DimLevel * 100);
        FadeOutField.Value = settings.FadeOut;
        FadeInField.Value = settings.FadeIn;
        UpdateLabels();
        loading = false;
    }

    void Change(Action apply) {
        if (loading) return;
        apply();
        settings.Clamp();
        settings.Save();
        dimmer.SettingsChanged();
        UpdateLabels();
    }

    void UpdateLabels() {
        LevelText.Text = $"{LevelSlider.Value:0}%";
        Timing.IsEnabled = settings.Enabled;
    }

    void Refresh() {
        if (EnabledBox.IsChecked != settings.Enabled) {
            EnabledBox.IsChecked = settings.Enabled;
            UpdateLabels();
        }
        PreviewButton.Content = dimmer.Previewing ? "Previewing…" : "Preview Dimming";
        PreviewButton.IsEnabled = !dimmer.Previewing;
    }
}
