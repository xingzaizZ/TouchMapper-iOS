//
//  TouchServer.cs
//  TouchMapper Windows 端
//
//  轻量 WebSocket 服务端：TcpListener + 手写 RFC6455 握手与帧解析。
//  协议与原版完全一致：ws://<ip>:17890/touch，UTF-8 JSON 文本帧。
//
//  为什么不用 HttpListener：
//    HttpListener 绑定 http://+:port/ 需要管理员权限或 urlacl 预留，
//    普通用户双击 exe 就会 503。TcpListener 直接监听端口，无此限制。
//

using System;
using System.Buffers;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace TouchMapper.Network;

public sealed class TouchServer : IDisposable
{
    public const int DefaultPort = 17890;

    private const string WebSocketGuid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

    private readonly int port;
    private readonly object gate = new();

    private TcpListener listener;
    private CancellationTokenSource cts;
    private TcpClient client;
    private NetworkStream clientStream;
    private Task acceptTask;

    /// <summary>(phase, x, y, contactId)</summary>
    public event Action<string, float, float, int> TouchReceived;
    public event Action<string> StatusChanged;

    public bool IsClientConnected { get; private set; }
    public int Port => port;

    public TouchServer(int port = DefaultPort)
    {
        this.port = port;
    }

    public void Start()
    {
        if (listener != null) return;

        var l = new TcpListener(IPAddress.Any, port);
        l.Server.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true);
        try
        {
            l.Start();
        }
        catch (SocketException ex)
        {
            throw new InvalidOperationException(
                $"端口 {port} 无法监听（{ex.SocketErrorCode}）。该端口可能已被其它程序占用。", ex);
        }

        listener = l;
        cts = new CancellationTokenSource();
        acceptTask = Task.Run(() => AcceptLoopAsync(cts.Token));
        StatusChanged?.Invoke($"等待手机连接 · 端口 {port}");
    }

    private async Task AcceptLoopAsync(CancellationToken token)
    {
        while (!token.IsCancellationRequested && listener != null)
        {
            TcpClient incoming;
            try
            {
                incoming = await listener.AcceptTcpClientAsync(token).ConfigureAwait(false);
            }
            catch (OperationCanceledException) { break; }
            catch (ObjectDisposedException) { break; }
            catch (SocketException) { continue; }

            try
            {
                incoming.NoDelay = true;
                var stream = incoming.GetStream();

                // 读 HTTP 升级请求并完成握手
                var request = await ReadHttpRequestAsync(stream, token).ConfigureAwait(false);
                if (request == null || !IsWebSocketUpgrade(request))
                {
                    CloseQuietly(incoming);
                    continue;
                }

                var key = GetHeader(request, "Sec-WebSocket-Key");
                if (string.IsNullOrEmpty(key))
                {
                    CloseQuietly(incoming);
                    continue;
                }

                await SendHandshakeAsync(stream, key, token).ConfigureAwait(false);

                // 只保留一个客户端，踢掉旧的
                TcpClient oldClient;
                lock (gate)
                {
                    oldClient = client;
                    client = incoming;
                    clientStream = stream;
                    IsClientConnected = true;
                }
                if (oldClient != null) CloseQuietly(oldClient);

                StatusChanged?.Invoke("手机已连接 · 可以操作");

                await ReadFramesAsync(stream, token).ConfigureAwait(false);
            }
            catch (Exception)
            {
                CloseQuietly(incoming);
            }
            finally
            {
                lock (gate)
                {
                    if (client == incoming)
                    {
                        client = null;
                        clientStream = null;
                        IsClientConnected = false;
                    }
                }
                StatusChanged?.Invoke("等待手机连接");
            }
        }
    }

    // ---------- HTTP 握手 ----------

    private static async Task<string> ReadHttpRequestAsync(NetworkStream stream, CancellationToken token)
    {
        var sb = new StringBuilder();
        var buf = new byte[1];
        var consecutiveNewlines = 0;

        // 逐字节读到 \r\n\r\n
        while (sb.Length < 16384)
        {
            var n = await stream.ReadAsync(buf.AsMemory(0, 1), token).ConfigureAwait(false);
            if (n == 0) return sb.Length > 0 ? sb.ToString() : null;

            var ch = (char)buf[0];
            sb.Append(ch);

            if (ch == '\r') consecutiveNewlines++;
            else if (ch == '\n' && consecutiveNewlines == 1) { }
            else consecutiveNewlines = 0;

            if (sb.Length >= 4 &&
                sb[^4] == '\r' && sb[^3] == '\n' && sb[^2] == '\r' && sb[^1] == '\n')
                break;
        }
        return sb.ToString();
    }

    private static bool IsWebSocketUpgrade(string request)
    {
        var upgrade = GetHeader(request, "Upgrade");
        return upgrade != null &&
               upgrade.Contains("websocket", StringComparison.OrdinalIgnoreCase) &&
               request.StartsWith("GET ", StringComparison.OrdinalIgnoreCase);
    }

    private static string GetHeader(string request, string name)
    {
        foreach (var line in request.Split("\r\n"))
        {
            var colon = line.IndexOf(':');
            if (colon <= 0) continue;
            if (line[..colon].Trim().Equals(name, StringComparison.OrdinalIgnoreCase))
                return line[(colon + 1)..].Trim();
        }
        return null;
    }

    private static async Task SendHandshakeAsync(NetworkStream stream, string clientKey, CancellationToken token)
    {
        var accept = Convert.ToBase64String(
            SHA1.HashData(Encoding.UTF8.GetBytes(clientKey + WebSocketGuid)));

        var response =
            "HTTP/1.1 101 Switching Protocols\r\n" +
            "Upgrade: websocket\r\n" +
            "Connection: Upgrade\r\n" +
            $"Sec-WebSocket-Accept: {accept}\r\n" +
            "\r\n";

        var bytes = Encoding.ASCII.GetBytes(response);
        await stream.WriteAsync(bytes.AsMemory(), token).ConfigureAwait(false);
        await stream.FlushAsync(token).ConfigureAwait(false);
    }

    // ---------- WebSocket 帧 ----------

    private async Task ReadFramesAsync(NetworkStream stream, CancellationToken token)
    {
        var header = new byte[2];
        var payloadBuffer = ArrayPool<byte>.Shared.Rent(65536);

        try
        {
            while (!token.IsCancellationRequested)
            {
                if (!await ReadExactAsync(stream, header, 2, token).ConfigureAwait(false))
                    return;

                var opcode = header[0] & 0x0F;
                var masked = (header[1] & 0x80) != 0;
                long length = header[1] & 0x7F;

                if (length == 126)
                {
                    var ext = new byte[2];
                    if (!await ReadExactAsync(stream, ext, 2, token).ConfigureAwait(false)) return;
                    length = (ext[0] << 8) | ext[1];
                }
                else if (length == 127)
                {
                    var ext = new byte[8];
                    if (!await ReadExactAsync(stream, ext, 8, token).ConfigureAwait(false)) return;
                    length = 0;
                    for (var i = 0; i < 8; i++) length = (length << 8) | ext[i];
                }

                if (length < 0 || length > 1_000_000) return;

                var maskKey = new byte[4];
                if (masked && !await ReadExactAsync(stream, maskKey, 4, token).ConfigureAwait(false))
                    return;

                var len = (int)length;
                if (len > payloadBuffer.Length)
                {
                    ArrayPool<byte>.Shared.Return(payloadBuffer);
                    payloadBuffer = ArrayPool<byte>.Shared.Rent(len);
                }

                if (len > 0 && !await ReadExactAsync(stream, payloadBuffer, len, token).ConfigureAwait(false))
                    return;

                if (masked)
                {
                    for (var i = 0; i < len; i++)
                        payloadBuffer[i] ^= maskKey[i & 3];
                }

                switch (opcode)
                {
                    case 0x1: // text
                    case 0x0: // continuation
                        Dispatch(Encoding.UTF8.GetString(payloadBuffer, 0, len));
                        break;

                    case 0x8: // close
                        await SendFrameAsync(stream, 0x8, Array.Empty<byte>(), token).ConfigureAwait(false);
                        return;

                    case 0x9: // ping
                        await SendFrameAsync(stream, 0xA, payloadBuffer[..len], token).ConfigureAwait(false);
                        break;

                    default:
                        break;
                }
            }
        }
        catch (Exception) { }
        finally
        {
            ArrayPool<byte>.Shared.Return(payloadBuffer);
        }
    }

    private static async Task<bool> ReadExactAsync(NetworkStream stream, byte[] buffer, int count, CancellationToken token)
    {
        var offset = 0;
        while (offset < count)
        {
            var n = await stream.ReadAsync(buffer.AsMemory(offset, count - offset), token).ConfigureAwait(false);
            if (n == 0) return false;
            offset += n;
        }
        return true;
    }

    private static async Task SendFrameAsync(NetworkStream stream, byte opcode, byte[] payload, CancellationToken token)
    {
        var len = payload.Length;
        var header = new List<byte> { (byte)(0x80 | opcode) };

        if (len < 126) header.Add((byte)len);
        else if (len < 65536)
        {
            header.Add(126);
            header.Add((byte)(len >> 8));
            header.Add((byte)(len & 0xFF));
        }
        else
        {
            header.Add(127);
            for (var i = 7; i >= 0; i--) header.Add((byte)((long)len >> (8 * i) & 0xFF));
        }

        await stream.WriteAsync(header.ToArray().AsMemory(), token).ConfigureAwait(false);
        if (len > 0) await stream.WriteAsync(payload.AsMemory(), token).ConfigureAwait(false);
        await stream.FlushAsync(token).ConfigureAwait(false);
    }

    /// <summary>解析一条 JSON 消息并派发</summary>
    private void Dispatch(string json)
    {
        try
        {
            using var doc = JsonDocument.Parse(json);
            var root = doc.RootElement;

            if (!root.TryGetProperty("type", out var typeEl)) return;
            if (!string.Equals(typeEl.GetString(), "screen-touch", StringComparison.OrdinalIgnoreCase))
                return;

            var phase = root.TryGetProperty("phase", out var pe) ? pe.GetString() : "";
            var x = root.TryGetProperty("x", out var xe) ? xe.GetSingle() : 0f;
            var y = root.TryGetProperty("y", out var ye) ? ye.GetSingle() : 0f;
            var cid = root.TryGetProperty("contactId", out var ce) ? ce.GetInt32() : 0;

            TouchReceived?.Invoke(phase ?? "", x, y, cid);
        }
        catch { }
    }

    // ---------- 关闭 ----------

    private static void CloseQuietly(TcpClient c)
    {
        try { c?.Close(); } catch { }
    }

    public void Stop()
    {
        cts?.Cancel();
        lock (gate)
        {
            CloseQuietly(client);
            client = null;
            clientStream = null;
            IsClientConnected = false;
        }
        try
        {
            listener?.Stop();
        }
        catch { }
        listener = null;
        cts?.Dispose();
        cts = null;
        StatusChanged?.Invoke("服务已停止");
    }

    public void Dispose() => Stop();
}
