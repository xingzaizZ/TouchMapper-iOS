//
//  ScreenTarget.cs
//  TouchMapper Windows 端
//
//  显示器枚举与目标选择。
//  原版 TouchMapper 用 GetSystemMetrics(76..79) 拿整块虚拟桌面，多屏时坐标会跨屏跑偏。
//  这里改成：枚举每块显示器，用户选一块，坐标只映射到那块的矩形里。
//

using System;
using System.Collections.Generic;
using System.Drawing;
using System.Linq;
using System.Runtime.InteropServices;

namespace TouchMapper.Screens;

/// <summary>一块可选中的显示器</summary>
public sealed class ScreenTarget
{
    /// <summary>显示器序号，从 1 开始</summary>
    public int Index { get; init; }

    /// <summary>设备名，例如 \\.\DISPLAY1</summary>
    public string DeviceName { get; init; } = "";

    /// <summary>是否主显示器</summary>
    public bool IsPrimary { get; init; }

    /// <summary>像素边界</summary>
    public Rectangle Bounds { get; init; }

    /// <summary>友好名称（从 EnumDisplayDevices 拿到的适配器描述）</summary>
    public string FriendlyName { get; init; } = "";

    /// <summary>是否被 Windows 判定为可用</summary>
    public bool IsAttached { get; init; } = true;

    public string DisplayLabel
    {
        get
        {
            var name = string.IsNullOrWhiteSpace(FriendlyName) ? DeviceName : FriendlyName;
            var primary = IsPrimary ? " · 主屏" : "";
            return $"{Index}. {name}{primary}  ({Bounds.Width}×{Bounds.Height})";
        }
    }

    /// <summary>下拉框只显示型号，避免太长</summary>
    public string ShortLabel
    {
        get
        {
            var name = string.IsNullOrWhiteSpace(FriendlyName) ? DeviceName : FriendlyName;
            if (name.Length > 28) name = name[..28] + "…";
            var primary = IsPrimary ? " · 主" : "";
            return $"{Index}. {name}{primary}";
        }
    }

    public override string ToString() => DisplayLabel;
}

public static class ScreenEnumerator
{
    /// <summary>枚举所有显示器，按系统顺序排列</summary>
    public static List<ScreenTarget> All()
    {
        var result = new List<ScreenTarget>();
        var screens = System.Windows.Forms.Screen.AllScreens;
        var monitorNames = QueryDeviceNames();

        int index = 1;
        foreach (var screen in screens)
        {
            var friendly = monitorNames.TryGetValue(screen.DeviceName, out var n) ? n : "";
            result.Add(new ScreenTarget
            {
                Index = index,
                DeviceName = screen.DeviceName,
                IsPrimary = screen.Primary,
                Bounds = screen.Bounds,
                FriendlyName = string.IsNullOrWhiteSpace(friendly) ? SimplifyDeviceName(screen.DeviceName) : friendly,
            });
            index++;
        }
        return result;
    }

    /// <summary>整块虚拟桌面（所有显示器合并）</summary>
    public static Rectangle VirtualDesktopBounds()
    {
        var left = GetSystemMetrics(SM_XVIRTUALSCREEN);
        var top = GetSystemMetrics(SM_YVIRTUALSCREEN);
        var width = GetSystemMetrics(SM_CXVIRTUALSCREEN);
        var height = GetSystemMetrics(SM_CYVIRTUALSCREEN);
        if (width <= 0 || height <= 0)
        {
            // 退路
            int minX = int.MaxValue, minY = int.MaxValue, maxX = int.MinValue, maxY = int.MinValue;
            foreach (var s in System.Windows.Forms.Screen.AllScreens)
            {
                minX = Math.Min(minX, s.Bounds.Left);
                minY = Math.Min(minY, s.Bounds.Top);
                maxX = Math.Max(maxX, s.Bounds.Right);
                maxY = Math.Max(maxY, s.Bounds.Bottom);
            }
            if (minX == int.MaxValue)
                return new Rectangle(0, 0, GetSystemMetrics(SM_CXSCREEN), GetSystemMetrics(SM_CYSCREEN));
            return Rectangle.FromLTRB(minX, minY, maxX, maxY);
        }
        return new Rectangle(left, top, width, height);
    }

    /// <summary>取默认目标：主显示器</summary>
    public static ScreenTarget PrimaryOrDefault(List<ScreenTarget> screens)
    {
        if (screens == null || screens.Count == 0) return null;
        return screens.FirstOrDefault(s => s.IsPrimary) ?? screens[0];
    }

    private static string SimplifyDeviceName(string device)
    {
        if (string.IsNullOrEmpty(device)) return "显示器";
        var idx = device.LastIndexOf('\\');
        return idx >= 0 && idx < device.Length - 1 ? device[(idx + 1)..] : device;
    }

    /// <summary>用 EnumDisplayDevices 拿到每块显示器的真实型号</summary>
    private static Dictionary<string, string> QueryDeviceNames()
    {
        var map = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        try
        {
            foreach (var screen in System.Windows.Forms.Screen.AllScreens)
            {
                var device = new DISPLAY_DEVICE();
                device.cb = Marshal.SizeOf<DISPLAY_DEVICE>();

                // 一级：适配器
                if (!EnumDisplayDevices(screen.DeviceName, 0, ref device, 0))
                    continue;

                var adapterName = device.DeviceString?.Trim();

                // 二级：显示器（拿到真型号）
                var monitor = new DISPLAY_DEVICE();
                monitor.cb = Marshal.SizeOf<DISPLAY_DEVICE>();
                string monitorName = null;
                if (EnumDisplayDevices(screen.DeviceName, 0, ref monitor, EDD_GET_DEVICE_INTERFACE_NAME)
                    && !string.IsNullOrWhiteSpace(monitor.DeviceString))
                {
                    monitorName = monitor.DeviceString.Trim();
                }

                var best = monitorName ?? adapterName;
                if (!string.IsNullOrWhiteSpace(best) && !best.Contains("Generic", StringComparison.OrdinalIgnoreCase))
                    map[screen.DeviceName] = best;
                else if (!string.IsNullOrWhiteSpace(adapterName))
                    map[screen.DeviceName] = adapterName;
            }
        }
        catch { }
        return map;
    }

    private const int SM_CXSCREEN = 0;
    private const int SM_CYSCREEN = 1;
    private const int SM_XVIRTUALSCREEN = 76;
    private const int SM_YVIRTUALSCREEN = 77;
    private const int SM_CXVIRTUALSCREEN = 78;
    private const int SM_CYVIRTUALSCREEN = 79;
    private const int EDD_GET_DEVICE_INTERFACE_NAME = 0x00000001;

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct DISPLAY_DEVICE
    {
        public int cb;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
        public string DeviceName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
        public string DeviceString;
        public int StateFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
        public string DeviceID;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
        public string DeviceKey;
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern bool EnumDisplayDevices(string lpDevice, uint iDevNum, ref DISPLAY_DEVICE lpDisplayDevice, uint dwFlags);

    [DllImport("user32.dll")]
    private static extern int GetSystemMetrics(int index);
}
