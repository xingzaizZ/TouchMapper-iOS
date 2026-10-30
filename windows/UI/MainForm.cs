//
//  MainForm.cs
//  TouchMapper Windows 端
//
//  主界面：显示器选择（带预览）、启动/停止、连接状态、日志。
//

using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Linq;
using System.Windows.Forms;
using TouchMapper.Input;
using TouchMapper.Network;
using TouchMapper.Screens;

namespace TouchMapper.UI;

public sealed class MainForm : Form
{
    private readonly TouchServer server;
    private readonly TouchInjector injector = new();
    private readonly List<ScreenTarget> screens;

    private ComboBox screenCombo;
    private ScreenPreviewPanel previewPanel;
    private Label statusLabel;
    private Label modeLabel;
    private Button startButton;
    private Button refreshButton;
    private RichTextBox logBox;
    private NotifyIcon trayIcon;

    private bool running;

    public MainForm(int port = TouchServer.DefaultPort, bool autoStart = false)
    {
        screens = ScreenEnumerator.All();
        server = new TouchServer(port);

        server.StatusChanged += OnServerStatus;
        server.TouchReceived += OnTouch;

        BuildUi(port);
        ApplyScreenSelection(0);

        if (autoStart)
        {
            Shown += (_, _) => StartServer();
        }
    }

    // ---------------- UI ----------------

    private void BuildUi(int port)
    {
        Text = $"TouchMapper · 端口 {port}";
        MinimumSize = new Size(720, 560);
        Size = new Size(780, 620);
        StartPosition = FormStartPosition.CenterScreen;
        BackColor = Color.FromArgb(24, 26, 32);
        ForeColor = Color.FromArgb(230, 233, 240);
        Font = new Font("Microsoft YaHei UI", 9F);

        // 顶部标题
        var title = new Label
        {
            Text = "触控映射",
            Font = new Font("Microsoft YaHei UI", 18F, FontStyle.Bold),
            AutoSize = true,
            Location = new Point(20, 16),
        };

        var subtitle = new Label
        {
            Text = $"Wi-Fi 局域网 · 端口 {port} · 支持 10 点触控",
            ForeColor = Color.FromArgb(150, 157, 172),
            AutoSize = true,
            Location = new Point(22, 52),
        };

        // 显示器选择
        var screenLabel = new Label
        {
            Text = "注入目标显示器",
            AutoSize = true,
            Location = new Point(20, 88),
        };

        screenCombo = new ComboBox
        {
            DropDownStyle = ComboBoxStyle.DropDownList,
            Location = new Point(20, 112),
            Width = 360,
            FlatStyle = FlatStyle.Flat,
            BackColor = Color.FromArgb(38, 41, 50),
            ForeColor = Color.FromArgb(230, 233, 240),
        };
        foreach (var s in screens) screenCombo.Items.Add(s.ShortLabel);
        if (screenCombo.Items.Count > 0) screenCombo.SelectedIndex = 0;
        screenCombo.SelectedIndexChanged += (_, _) => ApplyScreenSelection(screenCombo.SelectedIndex);

        refreshButton = MakeButton("刷新", 390, 111, 70);
        refreshButton.Click += (_, _) => RefreshScreens();

        // 预览
        previewPanel = new ScreenPreviewPanel(screens)
        {
            Location = new Point(20, 152),
            Size = new Size(440, 180),
        };

        // 状态卡
        var statusCard = new Panel
        {
            Location = new Point(480, 88),
            Size = new Size(264, 244),
            BackColor = Color.FromArgb(34, 37, 46),
        };

        modeLabel = new Label
        {
            Text = "未启动",
            Font = new Font("Microsoft YaHei UI", 12F, FontStyle.Bold),
            ForeColor = Color.FromArgb(120, 200, 255),
            AutoSize = true,
            Location = new Point(16, 16),
        };

        statusLabel = new Label
        {
            Text = "点下方按钮开始监听",
            ForeColor = Color.FromArgb(160, 168, 182),
            AutoSize = false,
            Size = new Size(232, 60),
            Location = new Point(16, 48),
        };

        startButton = MakeButton("启动服务", 16, 120, 232);
        startButton.Height = 40;
        startButton.Font = new Font("Microsoft YaHei UI", 10F, FontStyle.Bold);
        startButton.Click += (_, _) => ToggleServer();

        var hint = new Label
        {
            Text = "手机与电脑需在同一 Wi-Fi，\n首次运行请在防火墙允许专用网络。",
            ForeColor = Color.FromArgb(130, 138, 152),
            AutoSize = false,
            Size = new Size(232, 60),
            Location = new Point(16, 172),
        };

        statusCard.Controls.AddRange(new Control[] { modeLabel, statusLabel, startButton, hint });

        // 日志
        var logLabel = new Label
        {
            Text = "运行日志",
            AutoSize = true,
            Location = new Point(20, 348),
        };

        logBox = new RichTextBox
        {
            Location = new Point(20, 372),
            Size = new Size(724, 180),
            ReadOnly = true,
            BackColor = Color.FromArgb(18, 20, 24),
            ForeColor = Color.FromArgb(170, 180, 200),
            BorderStyle = BorderStyle.None,
            Font = new Font("Consolas", 9F),
            ScrollBars = RichTextBoxScrollBars.Vertical,
        };

        Controls.AddRange(new Control[]
        {
            title, subtitle, screenLabel, screenCombo, refreshButton,
            previewPanel, statusCard, logLabel, logBox,
        });

        Log($"检测到 {screens.Count} 台显示器");
        foreach (var s in screens) Log("  " + s.DisplayLabel);

        SetTray();
        FormClosing += OnFormClosing;
    }

    private Button MakeButton(string text, int x, int y, int w)
    {
        var b = new Button
        {
            Text = text,
            Location = new Point(x, y),
            Size = new Size(w, 28),
            FlatStyle = FlatStyle.Flat,
            BackColor = Color.FromArgb(56, 96, 180),
            ForeColor = Color.White,
            Cursor = Cursors.Hand,
        };
        b.FlatAppearance.BorderSize = 0;
        return b;
    }

    private void SetTray()
    {
        trayIcon = new NotifyIcon
        {
            Text = "TouchMapper",
            Visible = true,
            Icon = SystemIcons.Application,
        };
        trayIcon.DoubleClick += (_, _) =>
        {
            Show();
            WindowState = FormWindowState.Normal;
            Activate();
        };
        var menu = new ContextMenuStrip();
        menu.Items.Add("显示窗口", null, (_, _) => { Show(); WindowState = FormWindowState.Normal; });
        menu.Items.Add("退出", null, (_, _) => { Close(); });
        trayIcon.ContextMenuStrip = menu;
    }

    // ---------------- 显示器 ----------------

    private void RefreshScreens()
    {
        var fresh = ScreenEnumerator.All();
        screens.Clear();
        screens.AddRange(fresh);

        screenCombo.Items.Clear();
        foreach (var s in screens) screenCombo.Items.Add(s.ShortLabel);
        if (screenCombo.Items.Count > 0) screenCombo.SelectedIndex = 0;

        previewPanel.Invalidate();
        Log($"刷新显示器列表：{screens.Count} 台");
        foreach (var s in screens) Log("  " + s.DisplayLabel);
    }

    private void ApplyScreenSelection(int index)
    {
        if (index < 0 || index >= screens.Count) return;
        var target = screens[index];
        injector.TargetBounds = target.Bounds;
        previewPanel.Selected = target;
        previewPanel.Invalidate();
        Log($"注入目标 → {target.DisplayLabel}");
    }

    // ---------------- 服务 ----------------

    private void ToggleServer()
    {
        if (running) StopServer();
        else StartServer();
    }

    private void StartServer()
    {
        try
        {
            server.Start();
            running = true;
            startButton.Text = "停止服务";
            startButton.BackColor = Color.FromArgb(180, 60, 60);
            modeLabel.Text = "运行中";
            modeLabel.ForeColor = Color.FromArgb(120, 220, 150);
        }
        catch (Exception ex)
        {
            Log("启动失败：" + ex.Message);
            MessageBox.Show(ex.Message, "启动失败", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }

    private void StopServer()
    {
        injector.ReleaseAll();
        server.Stop();
        running = false;
        startButton.Text = "启动服务";
        startButton.BackColor = Color.FromArgb(56, 96, 180);
        modeLabel.Text = "未启动";
        modeLabel.ForeColor = Color.FromArgb(120, 200, 255);
        statusLabel.Text = "点下方按钮开始监听";
    }

    private void OnServerStatus(string text)
    {
        if (InvokeRequired)
        {
            BeginInvoke(new Action(() => OnServerStatus(text)));
            return;
        }
        statusLabel.Text = text;
        Log(text);
    }

    private void OnTouch(string phase, float x, float y, int contactId)
    {
        var ok = injector.Apply(phase, x, y, contactId);
        if (!ok && !string.IsNullOrEmpty(injector.LastError))
        {
            if (InvokeRequired)
                BeginInvoke(new Action(() => statusLabel.Text = "注入失败：" + injector.LastError));
            else
                statusLabel.Text = "注入失败：" + injector.LastError;
        }
    }

    private void Log(string message)
    {
        if (InvokeRequired)
        {
            BeginInvoke(new Action(() => Log(message)));
            return;
        }
        logBox.AppendText($"[{DateTime.Now:HH:mm:ss}] {message}\n");
        logBox.ScrollToCaret();
    }

    private void OnFormClosing(object sender, FormClosingEventArgs e)
    {
        injector.ReleaseAll();
        server.Stop();
        injector.Dispose();
        if (trayIcon != null)
        {
            trayIcon.Visible = false;
            trayIcon.Dispose();
        }
    }
}

/// <summary>
/// 显示器布局预览：按 Windows 显示设置的样子把每块屏画出来，
/// 选中的高亮为蓝色。
/// </summary>
public sealed class ScreenPreviewPanel : Panel
{
    private readonly List<ScreenTarget> screens;

    public ScreenTarget Selected { get; set; }

    public ScreenPreviewPanel(List<ScreenTarget> screens)
    {
        this.screens = screens;
        DoubleBuffered = true;
        BackColor = Color.FromArgb(20, 22, 28);
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        base.OnPaint(e);
        if (screens.Count == 0) return;

        var g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;

        // 所有显示器的包围盒
        int minX = screens.Min(s => s.Bounds.Left);
        int minY = screens.Min(s => s.Bounds.Top);
        int maxX = screens.Max(s => s.Bounds.Right);
        int maxY = screens.Max(s => s.Bounds.Bottom);

        int totalW = Math.Max(1, maxX - minX);
        int totalH = Math.Max(1, maxY - minY);

        const int pad = 24;
        float scale = Math.Min((float)(Width - pad * 2) / totalW,
                               (float)(Height - pad * 2) / totalH);

        float offsetX = (Width - totalW * scale) / 2f;
        float offsetY = (Height - totalH * scale) / 2f;

        foreach (var s in screens)
        {
            var r = new RectangleF(
                offsetX + (s.Bounds.Left - minX) * scale,
                offsetY + (s.Bounds.Top - minY) * scale,
                s.Bounds.Width * scale,
                s.Bounds.Height * scale);

            var isSelected = Selected != null && Selected.Index == s.Index;

            using var fill = new SolidBrush(isSelected
                ? Color.FromArgb(28, 128, 220)
                : Color.FromArgb(78, 82, 94));
            g.FillRectangle(fill, r);

            using var border = new Pen(isSelected ? Color.White : Color.FromArgb(120, 126, 140), 2f);
            g.DrawRectangle(border, r.X, r.Y, r.Width, r.Height);

            var label = s.Index.ToString();
            using var font = new Font("Microsoft YaHei UI", Math.Max(10f, r.Height / 5f), FontStyle.Bold);
            var size = g.MeasureString(label, font);
            using var textBrush = new SolidBrush(isSelected ? Color.White : Color.FromArgb(210, 214, 224));
            g.DrawString(label, font, textBrush,
                r.X + (r.Width - size.Width) / 2f,
                r.Y + (r.Height - size.Height) / 2f);
        }
    }

    protected override void OnResize(EventArgs eventargs)
    {
        base.OnResize(eventargs);
        Invalidate();
    }
}
