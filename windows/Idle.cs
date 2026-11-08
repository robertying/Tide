using System;
using System.Runtime.InteropServices;

namespace Tide;

/// Seconds since the last mouse, keyboard or game controller input.
static class Idle {
    public static int Seconds() => Math.Min(InputSeconds(), Pads.IdleSeconds());

    static uint? ignoreUntil;

    /// Tide's own pointer nudge (see Overlay.TakePointer) may register as input. Input up to a moment
    /// from now is treated as not having happened, until the next call to <see cref="StopIgnoring"/>.
    public static void IgnoreInputForNow() => ignoreUntil = unchecked((uint)Environment.TickCount + 250);
    public static void StopIgnoring() => ignoreUntil = null;

    static int InputSeconds() {
        var info = new Native.LASTINPUTINFO { cbSize = (uint)Marshal.SizeOf<Native.LASTINPUTINFO>() };
        if (!Native.GetLastInputInfo(ref info)) return 0;
        // Tide only nudges after the idle time has passed, so the user is still away.
        if (ignoreUntil is uint until && unchecked((int)(info.dwTime - until)) <= 0) return int.MaxValue;
        return (int)(unchecked((uint)Environment.TickCount - info.dwTime) / 1000);
    }

    /// Game controllers do not count as input for GetLastInputInfo, so XInput pads are checked separately.
    static class Pads {
        static bool available = true;
        static readonly bool[] connected = new bool[4];
        static readonly uint[] packet = new uint[4];
        static DateTime nextScan = DateTime.MinValue, lastInput = DateTime.MinValue;

        static bool Moved(short x, short y, int deadZone) => (long)x * x + (long)y * y > (long)deadZone * deadZone;

        public static int IdleSeconds() {
            if (!available) return int.MaxValue;
            try {
                var now = DateTime.UtcNow;
                // Asking an empty slot is slow, so look for newly connected pads only every few seconds.
                bool scan = now >= nextScan;
                if (scan) nextScan = now.AddSeconds(3);
                for (int i = 0; i < 4; i++) {
                    if (!connected[i] && !scan) continue;
                    connected[i] = Native.XInputGetState(i, out var s) == 0;
                    if (!connected[i]) continue;
                    bool changed = s.Packet != packet[i];
                    packet[i] = s.Packet;
                    // Ignore packets from stick drift: count buttons, triggers and sticks past the standard dead zones.
                    if (changed && (s.Buttons != 0 || s.LeftTrigger > 30 || s.RightTrigger > 30 ||
                                    Moved(s.LX, s.LY, 7849) || Moved(s.RX, s.RY, 8689)))
                        lastInput = now;
                }
                return lastInput == DateTime.MinValue ? int.MaxValue : (int)(now - lastInput).TotalSeconds;
            } catch (DllNotFoundException) {
                available = false;
                return int.MaxValue;
            }
        }
    }
}
