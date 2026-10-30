//
//  TouchInjector.cs
//  TouchMapper Windows 端
//
//  Win32 多点触控注入。
//  关键差异（相对原版）：坐标只映射到用户选中的那块显示器，而不是整块虚拟桌面。
//

using System;
using System.Collections.Generic;
using System.Drawing;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading;

namespace TouchMapper.Input;

public sealed class TouchInjector
{
    private const uint InRange = 2u;
    private const uint InContact = 4u;
    private const uint Canceled = 0x8000u;
    private const uint Down = 0x10000u;
    private const uint Update = 0x20000u;
    private const uint Up = 0x40000u;

    private const uint TouchMaskContactArea = 0x1u;
    private const uint TouchMaskPressure = 0x4u;

    private const int ErrorNotReady = 21;
    private const int MaxContacts = 10;
    private const int HeartbeatMs = 50;

    private sealed class Contact
    {
        public int Slot;
        public int X;
        public int Y;
        public uint Flags;
    }

    private readonly object gate = new();
    private readonly Dictionary<int, Contact> contacts = new();
    private readonly Timer heartbeat;

    private bool initialized;
    private bool disposed;
    private Rectangle targetBounds;

    public string LastError { get; private set; } = "";
    public int LastErrorCode { get; private set; }
    public int ActiveContacts { get { lock (gate) return contacts.Count; } }

    /// <summary>当前注入目标矩形（选中显示器的像素边界）</summary>
    public Rectangle TargetBounds
    {
        get { lock (gate) return targetBounds; }
        set { lock (gate) targetBounds = value; }
    }

    public TouchInjector()
    {
        heartbeat = new Timer(_ => SendHeartbeat(), null, -1, -1);
    }

    public bool Initialize()
    {
        if (initialized) return true;
        if (InitializeTouchInjection(MaxContacts, 1))
        {
            initialized = true;
            Clear();
            return true;
        }
        Record("InitializeTouchInjection", Marshal.GetLastWin32Error());
        return false;
    }

    /// <summary>
    /// 处理一个触点事件。x/y 是归一化坐标 0..1，相对当前目标显示器。
    /// </summary>
    public bool Apply(string phase, float x, float y, int contactId)
    {
        lock (gate)
        {
            var p = (phase ?? "").ToLowerInvariant();
            if (p != "down" && p != "move" && p != "up" && p != "cancel")
            {
                LastError = "未知触摸阶段：" + phase;
                return false;
            }

            if (p == "up" || p == "cancel")
            {
                if (!contacts.TryGetValue(contactId, out var c))
                    return true;

                c.Flags = Up | InContact | InRange | (p == "cancel" ? Canceled : 0);
                if (!InjectFrame()) return false;

                contacts.Remove(contactId);
                if (contacts.Count == 0) StopHeartbeat();
                return true;
            }

            if (!float.IsFinite(x) || !float.IsFinite(y))
            {
                LastError = "坐标不是有限数值";
                return false;
            }

            if (!initialized && !Initialize()) return false;

            // 其它触点降为 UPDATE
            foreach (var other in contacts.Values) other.Flags = Update | InContact | InRange;

            if (p == "down")
            {
                if (contacts.ContainsKey(contactId))
                    contacts.Remove(contactId);

                if (contacts.Count >= MaxContacts)
                {
                    LastError = $"触点数超过 {MaxContacts}";
                    return false;
                }

                var (px, py) = Map(x, y);
                contacts[contactId] = new Contact
                {
                    Slot = FindSlot(),
                    X = px,
                    Y = py,
                    Flags = Down | InContact | InRange,
                };
            }
            else // move
            {
                if (!contacts.TryGetValue(contactId, out var c))
                    return true;

                var (px, py) = Map(x, y);
                c.X = px;
                c.Y = py;
                c.Flags = Update | InContact | InRange;
            }

            if (!InjectFrame()) return false;

            if (p == "down") StartHeartbeat();
            return true;
        }
    }

    /// <summary>释放所有触点（断连、退出、切模式时调用）</summary>
    public bool ReleaseAll()
    {
        lock (gate)
        {
            if (contacts.Count == 0)
            {
                StopHeartbeat();
                return true;
            }
            foreach (var c in contacts.Values) c.Flags = Up | InContact | InRange | Canceled;
            var ok = InjectFrame();
            contacts.Clear();
            StopHeartbeat();
            return ok;
        }
    }

    /// <summary>
    /// 归一化坐标 → 目标显示器像素坐标。
    /// 这是与原版唯一的实质差别：用 targetBounds 而不是虚拟桌面。
    /// </summary>
    private (int X, int Y) Map(float x, float y)
    {
        var b = targetBounds;
        if (b.Width <= 0 || b.Height <= 0)
        {
            b = System.Windows.Forms.Screen.PrimaryScreen?.Bounds
                ?? new Rectangle(0, 0, 1920, 1080);
        }

        var cx = Math.Clamp(x, 0f, 1f);
        var cy = Math.Clamp(y, 0f, 1f);
        var px = b.Left + (int)Math.Round(cx * Math.Max(0, b.Width - 1));
        var py = b.Top + (int)Math.Round(cy * Math.Max(0, b.Height - 1));
        return (px, py);
    }

    private bool InjectFrame()
    {
        var frame = contacts.Values
            .OrderBy(c => c.Slot)
            .Select(ToPointerInfo)
            .ToArray();
        if (frame.Length == 0) return true;

        for (var attempt = 0; attempt < 4; attempt++)
        {
            if (InjectTouchInput((uint)frame.Length, frame))
            {
                Clear();
                return true;
            }
            var err = Marshal.GetLastWin32Error();
            if (err != ErrorNotReady || attempt == 3)
            {
                Record("InjectTouchInput", err);
                return false;
            }
            Thread.Sleep(1);
        }
        return false;
    }

    private static POINTER_TOUCH_INFO ToPointerInfo(Contact c)
    {
        var info = new POINTER_TOUCH_INFO
        {
            pointerInfo = new POINTER_INFO
            {
                pointerType = 2,          // PT_TOUCH
                pointerId = (uint)c.Slot,
                pointerFlags = c.Flags,
                ptPixelLocation = new POINT { x = c.X, y = c.Y },
            },
            touchMask = TouchMaskContactArea | TouchMaskPressure,
            rcContact = new RECT
            {
                left = c.X - 2,
                top = c.Y - 2,
                right = c.X + 2,
                bottom = c.Y + 2,
            },
            pressure = 512,
        };
        return info;
    }

    private void StartHeartbeat()
    {
        if (!disposed) heartbeat.Change(HeartbeatMs, HeartbeatMs);
    }

    private void StopHeartbeat()
    {
        heartbeat.Change(Timeout.Infinite, Timeout.Infinite);
    }

    /// <summary>心跳：Windows 需要定期刷新，否则判定触点失效</summary>
    private void SendHeartbeat()
    {
        lock (gate)
        {
            if (disposed || contacts.Count == 0)
            {
                StopHeartbeat();
                return;
            }
            foreach (var c in contacts.Values) c.Flags = Update | InContact | InRange;
            InjectFrame();
        }
    }

    private int FindSlot()
    {
        for (var slot = 0; slot < MaxContacts; slot++)
        {
            if (contacts.Values.All(c => c.Slot != slot)) return slot;
        }
        return 0;
    }

    private void Record(string op, int code)
    {
        LastErrorCode = code;
        LastError = code == 0
            ? $"{op} 失败，系统未返回错误码"
            : $"{op} 失败 · Win32 {code}：{new System.ComponentModel.Win32Exception(code).Message}";
    }

    private void Clear()
    {
        LastErrorCode = 0;
        LastError = "";
    }

    public void Dispose()
    {
        lock (gate)
        {
            disposed = true;
            StopHeartbeat();
            contacts.Clear();
        }
        heartbeat.Dispose();
    }

    // ---------- P/Invoke ----------

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool InitializeTouchInjection(uint maxCount, uint feedbackMode);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool InjectTouchInput(uint count, [In] POINTER_TOUCH_INFO[] contacts);

    [StructLayout(LayoutKind.Sequential)]
    private struct POINT
    {
        public int x;
        public int y;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct RECT
    {
        public int left;
        public int top;
        public int right;
        public int bottom;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct POINTER_INFO
    {
        public uint pointerType;
        public uint pointerId;
        public uint frameId;
        public uint pointerFlags;
        public IntPtr sourceDevice;
        public IntPtr hwndTarget;
        public POINT ptPixelLocation;
        public POINT ptHimetricLocation;
        public POINT ptPixelLocationRaw;
        public POINT ptHimetricLocationRaw;
        public uint dwTime;
        public uint historyCount;
        public int InputState;
        public uint dwKeyStates;
        public ulong PerformanceCount;
        public int ButtonChangeType;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct POINTER_TOUCH_INFO
    {
        public POINTER_INFO pointerInfo;
        public uint touchFlags;
        public uint touchMask;
        public RECT rcContact;
        public RECT rcContactRaw;
        public uint orientation;
        public uint pressure;
    }
}
