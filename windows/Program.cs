//
//  Program.cs
//  TouchMapper Windows 端
//
//  支持命令行参数：
//    --autostart   启动后自动开始监听（不弹窗点按钮）
//    --port <n>    指定端口
//

using System;
using System.Linq;
using System.Windows.Forms;

namespace TouchMapper;

internal static class Program
{
    [STAThread]
    private static void Main(string[] args)
    {
        ApplicationConfiguration.Initialize();
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);

        var autoStart = args.Any(a => a.Equals("--autostart", StringComparison.OrdinalIgnoreCase));

        var port = 17890;
        var portIdx = Array.FindIndex(args, a => a.Equals("--port", StringComparison.OrdinalIgnoreCase));
        if (portIdx >= 0 && portIdx + 1 < args.Length && int.TryParse(args[portIdx + 1], out var p))
            port = p;

        // 只允许一个实例
        using var mutex = new System.Threading.Mutex(true, "TouchMapper.SingleInstance", out var isNew);
        if (!isNew)
        {
            MessageBox.Show("TouchMapper 已经在运行了。", "TouchMapper",
                MessageBoxButtons.OK, MessageBoxIcon.Information);
            return;
        }

        Application.Run(new UI.MainForm(port, autoStart));
    }
}
