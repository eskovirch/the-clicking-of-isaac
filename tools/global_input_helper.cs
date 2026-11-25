using System;
using System.Diagnostics;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

internal static class GlobalInputHelper
{
    [DllImport("user32.dll")]
    private static extern short GetAsyncKeyState(int vKey);

    private static readonly int[] MouseVKs = { 0x01, 0x02, 0x04, 0x05, 0x06 };

    private static void Main(string[] args)
    {
        if (args.Length < 2)
        {
            return;
        }

        int port;
        int parentPid;
        if (!int.TryParse(args[0], out port) || !int.TryParse(args[1], out parentPid))
        {
            return;
        }

        bool[] wasDown = new bool[256];
        for (int vk = 0; vk < 256; vk++)
        {
            wasDown[vk] = (GetAsyncKeyState(vk) & 0x8000) != 0;
        }

        byte[] mousePayload = Encoding.ASCII.GetBytes("M");
        byte[] keyPayload = Encoding.ASCII.GetBytes("K");

        using (UdpClient udp = new UdpClient())
        {
            udp.Connect("127.0.0.1", port);
            int parentCheckCounter = 0;

            while (true)
            {
                for (int i = 0; i < MouseVKs.Length; i++)
                {
                    int vk = MouseVKs[i];
                    bool isDown = (GetAsyncKeyState(vk) & 0x8000) != 0;
                    if (isDown && !wasDown[vk])
                    {
                        try
                        {
                            udp.Send(mousePayload, mousePayload.Length);
                        }
                        catch
                        {
                            return;
                        }
                    }
                    wasDown[vk] = isDown;
                }

                for (int vk = 0x08; vk <= 0xFE; vk++)
                {
                    if (vk == 0x10 || vk == 0x11 || vk == 0x12)
                    {
                        continue;
                    }
                    bool isDown = (GetAsyncKeyState(vk) & 0x8000) != 0;
                    if (isDown && !wasDown[vk])
                    {
                        try
                        {
                            udp.Send(keyPayload, keyPayload.Length);
                        }
                        catch
                        {
                            return;
                        }
                    }
                    wasDown[vk] = isDown;
                }

                parentCheckCounter++;
                if (parentCheckCounter >= 50)
                {
                    parentCheckCounter = 0;
                    try
                    {
                        using (Process parent = Process.GetProcessById(parentPid))
                        {
                            if (parent.HasExited)
                            {
                                return;
                            }
                        }
                    }
                    catch (ArgumentException)
                    {
                        return;
                    }
                    catch (InvalidOperationException)
                    {
                        return;
                    }
                }

                Thread.Sleep(10);
            }
        }
    }
}
