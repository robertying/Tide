using System;
using System.Drawing.Text;

namespace Tide;

/// The Windows icon font, used for the tray icon and the number field arrows.
/// Segoe Fluent Icons ships with Windows 11; Segoe MDL2 Assets with Windows 10. Both share code points.
static class IconFont {
    static readonly Lazy<string> name = new(() => {
        using var installed = new InstalledFontCollection();
        foreach (var family in installed.Families)
            if (family.Name == "Segoe Fluent Icons") return family.Name;
        return "Segoe MDL2 Assets";
    });

    public static string Name => name.Value;

    public const string Brightness = "\uE706", ChevronUp = "\uE70E", ChevronDown = "\uE70D";
}
