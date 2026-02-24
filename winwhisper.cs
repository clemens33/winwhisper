using System;
using System.Linq;
using System.Linq.Expressions;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

/// <summary>
/// WinWhisper v0.9.0 — Push-to-talk voice dictation for Windows 11.
/// Pure Win32 API (no WinForms) — WinRT speech + tray icon + live overlay + SendInput.
/// Compile with /target:winexe for no console. Use -debug for console logging.
/// </summary>
class WinWhisper
{
    const string VERSION = "0.9.0";
    const int VK_OEM_PLUS = 0xBB;
    const int VK_ADD = 0x6B;       // Numpad +
    const int VK_SHIFT = 0x10;
    const int VK_ESCAPE = 0x1B;
    const int DEBOUNCE_MS = 200;

    // --- Win32 constants ---
    const uint PM_REMOVE = 0x0001;
    const uint WM_COMMAND = 0x0111;
    const uint WM_DESTROY = 0x0002;
    const uint WM_RBUTTONUP = 0x0205;
    const uint WM_LBUTTONDBLCLK = 0x0203;
    const uint WM_APP = 0x8000;
    const uint WM_TRAYICON = WM_APP + 1;
    const uint NIM_ADD = 0x00;
    const uint NIM_MODIFY = 0x01;
    const uint NIM_DELETE = 0x02;
    const uint NIF_MESSAGE = 0x01;
    const uint NIF_ICON = 0x02;
    const uint NIF_TIP = 0x04;
    const uint NIF_INFO = 0x10;
    const uint NIIF_NONE = 0x00;
    const uint MF_STRING = 0x0000;
    const uint MF_SEPARATOR = 0x0800;
    const uint MF_GRAYED = 0x0001;
    const uint TPM_BOTTOMALIGN = 0x0020;
    const uint TPM_RIGHTALIGN = 0x0008;
    const int MENU_EXIT = 1001;

    // Overlay window constants
    const uint WS_POPUP = 0x80000000;
    const uint WS_EX_LAYERED = 0x80000;
    const uint WS_EX_TOPMOST = 0x00000008;
    const uint WS_EX_TRANSPARENT = 0x00000020;
    const uint WS_EX_NOACTIVATE = 0x08000000;
    const uint WS_EX_TOOLWINDOW = 0x00000080;
    const uint WM_PAINT = 0x000F;
    const uint WM_TIMER = 0x0113;
    const int OVERLAY_TIMER_ID = 42;
    const int OVERLAY_WIDTH = 340;
    const int OVERLAY_HEIGHT = 44;

    // Overlay dot colors (BGR format)
    const uint DOT_RED = 0x004444EF;      // Recording
    const uint DOT_AMBER = 0x0008B3EA;    // Processing
    const uint DOT_GREEN = 0x005EC522;    // Success
    const uint DOT_GRAY = 0x00808080;     // No speech
    const uint DOT_ERROR = 0x000000FF;    // Error

    // --- P/Invoke: message pump + keyboard ---

    [DllImport("user32.dll")]
    static extern short GetAsyncKeyState(int vKey);

    [DllImport("user32.dll")]
    static extern bool PeekMessage(out MSG lpMsg, IntPtr hWnd, uint wMsgFilterMin, uint wMsgFilterMax, uint wRemoveMsg);

    [DllImport("user32.dll")]
    static extern bool TranslateMessage(ref MSG lpMsg);

    [DllImport("user32.dll")]
    static extern IntPtr DispatchMessage(ref MSG lpMsg);

    // --- P/Invoke: console (for -debug mode with /target:winexe) ---

    [DllImport("kernel32.dll")]
    static extern bool AllocConsole();

    // --- P/Invoke: SendInput ---

    [DllImport("user32.dll", SetLastError = true)]
    static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);

    // --- P/Invoke: window class + message-only window ---

    delegate IntPtr WndProcDelegate(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern ushort RegisterClassEx(ref WNDCLASSEX lpWndClass);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr CreateWindowEx(uint dwExStyle, string lpClassName, string lpWindowName,
        uint dwStyle, int x, int y, int nWidth, int nHeight,
        IntPtr hWndParent, IntPtr hMenu, IntPtr hInstance, IntPtr lpParam);

    [DllImport("user32.dll")]
    static extern IntPtr DefWindowProc(IntPtr hWnd, uint uMsg, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll")]
    static extern bool DestroyWindow(IntPtr hWnd);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    static extern IntPtr GetModuleHandle(string lpModuleName);

    // --- P/Invoke: Shell_NotifyIcon ---

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    static extern bool Shell_NotifyIcon(uint dwMessage, ref NOTIFYICONDATA lpData);

    // --- P/Invoke: popup menu ---

    [DllImport("user32.dll")]
    static extern IntPtr CreatePopupMenu();

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern bool AppendMenu(IntPtr hMenu, uint uFlags, uint uIDNewItem, string lpNewItem);

    [DllImport("user32.dll")]
    static extern int TrackPopupMenu(IntPtr hMenu, uint uFlags, int x, int y,
        int nReserved, IntPtr hWnd, IntPtr prcRect);

    [DllImport("user32.dll")]
    static extern bool DestroyMenu(IntPtr hMenu);

    [DllImport("user32.dll")]
    static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    static extern bool GetCursorPos(out POINT lpPoint);

    [DllImport("user32.dll")]
    static extern bool PostMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);

    // --- P/Invoke: icon creation ---

    [DllImport("gdi32.dll")]
    static extern IntPtr CreateBitmap(int nWidth, int nHeight, uint cPlanes, uint cBitsPerPel, byte[] lpvBits);

    [DllImport("user32.dll")]
    static extern IntPtr CreateIconIndirect(ref ICONINFO piconinfo);

    [DllImport("gdi32.dll")]
    static extern bool DeleteObject(IntPtr hObject);

    [DllImport("user32.dll")]
    static extern bool DestroyIcon(IntPtr hIcon);

    // --- P/Invoke: overlay window (GDI painting) ---

    [DllImport("user32.dll")]
    static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll")]
    static extern bool InvalidateRect(IntPtr hWnd, IntPtr lpRect, bool bErase);

    [DllImport("user32.dll")]
    static extern IntPtr BeginPaint(IntPtr hWnd, out PAINTSTRUCT lpPaint);

    [DllImport("user32.dll")]
    static extern bool EndPaint(IntPtr hWnd, ref PAINTSTRUCT lpPaint);

    [DllImport("user32.dll")]
    static extern bool SetLayeredWindowAttributes(IntPtr hwnd, uint crKey, byte bAlpha, uint dwFlags);

    [DllImport("user32.dll")]
    static extern IntPtr SetTimer(IntPtr hWnd, IntPtr nIDEvent, uint uElapse, IntPtr lpTimerFunc);

    [DllImport("user32.dll")]
    static extern bool KillTimer(IntPtr hWnd, IntPtr uIDEvent);

    [DllImport("user32.dll")]
    static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

    [DllImport("user32.dll")]
    static extern bool MoveWindow(IntPtr hWnd, int X, int Y, int nWidth, int nHeight, bool bRepaint);

    [DllImport("gdi32.dll")]
    static extern IntPtr CreateSolidBrush(uint crColor);

    [DllImport("gdi32.dll", CharSet = CharSet.Unicode)]
    static extern IntPtr CreateFont(int nHeight, int nWidth, int nEscapement, int nOrientation,
        int fnWeight, uint fdwItalic, uint fdwUnderline, uint fdwStrikeOut, uint fdwCharSet,
        uint fdwOutputPrecision, uint fdwClipPrecision, uint fdwQuality, uint fdwPitchAndFamily,
        string lpszFace);

    [DllImport("gdi32.dll")]
    static extern IntPtr SelectObject(IntPtr hdc, IntPtr hgdiobj);

    [DllImport("gdi32.dll")]
    static extern uint SetTextColor(IntPtr hdc, uint crColor);

    [DllImport("gdi32.dll")]
    static extern int SetBkMode(IntPtr hdc, int mode);

    [DllImport("user32.dll")]
    static extern int FillRect(IntPtr hDC, ref RECT lprc, IntPtr hbr);

    [DllImport("gdi32.dll")]
    static extern bool Ellipse(IntPtr hdc, int nLeftRect, int nTopRect, int nRightRect, int nBottomRect);

    [DllImport("gdi32.dll")]
    static extern IntPtr CreatePen(int fnPenStyle, int nWidth, uint crColor);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern int DrawText(IntPtr hDC, string lpString, int nCount, ref RECT lpRect, uint uFormat);

    [DllImport("user32.dll")]
    static extern bool SystemParametersInfo(uint uiAction, uint uiParam, out RECT pvParam, uint fWinIni);

    const uint LWA_ALPHA = 0x02;
    const uint SPI_GETWORKAREA = 0x0030;
    const uint DT_LEFT = 0x0000;
    const uint DT_VCENTER = 0x0004;
    const uint DT_SINGLELINE = 0x0020;
    const uint DT_END_ELLIPSIS = 0x8000;
    const int TRANSPARENT = 1;

    // --- Structs ---

    [StructLayout(LayoutKind.Sequential)]
    struct MSG
    {
        public IntPtr hwnd;
        public uint message;
        public IntPtr wParam;
        public IntPtr lParam;
        public uint time;
        public int pt_x;
        public int pt_y;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct POINT
    {
        public int x;
        public int y;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct RECT
    {
        public int left;
        public int top;
        public int right;
        public int bottom;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct PAINTSTRUCT
    {
        public IntPtr hdc;
        public bool fErase;
        public RECT rcPaint;
        public bool fRestore;
        public bool fIncUpdate;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 32)]
        public byte[] rgbReserved;
    }

    const uint INPUT_KEYBOARD = 1;
    const uint KEYEVENTF_UNICODE = 0x0004;
    const uint KEYEVENTF_KEYUP = 0x0002;

    [StructLayout(LayoutKind.Sequential)]
    struct INPUT
    {
        public uint type;
        public INPUTUNION union;
    }

    [StructLayout(LayoutKind.Explicit)]
    struct INPUTUNION
    {
        [FieldOffset(0)]
        public KEYBDINPUT ki;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct KEYBDINPUT
    {
        public ushort wVk;
        public ushort wScan;
        public uint dwFlags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct WNDCLASSEX
    {
        public uint cbSize;
        public uint style;
        public IntPtr lpfnWndProc;
        public int cbClsExtra;
        public int cbWndExtra;
        public IntPtr hInstance;
        public IntPtr hIcon;
        public IntPtr hCursor;
        public IntPtr hbrBackground;
        public string lpszMenuName;
        public string lpszClassName;
        public IntPtr hIconSm;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct NOTIFYICONDATA
    {
        public int cbSize;
        public IntPtr hWnd;
        public uint uID;
        public uint uFlags;
        public uint uCallbackMessage;
        public IntPtr hIcon;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
        public string szTip;
        public uint dwState;
        public uint dwStateMask;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)]
        public string szInfo;
        public uint uTimeoutOrVersion;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)]
        public string szInfoTitle;
        public uint dwInfoFlags;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct ICONINFO
    {
        public int fIcon;
        public int xHotspot;
        public int yHotspot;
        public IntPtr hbmMask;
        public IntPtr hbmColor;
    }

    // --- WinRT reflection ---
    static MethodInfo asTaskAction;
    static MethodInfo asTaskOperation;
    static Type compileResultType;
    static object recognizer;
    static object session;

    // --- Speech state (accessed from background threads) ---
    static readonly object accLock = new object();
    static StringBuilder accumulated = new StringBuilder();
    static int resultCount = 0;
    static bool isListening = false;
    static bool isStopping = false;
    static bool sessionCompleted = false;
    static string currentHypothesis = "";
    static int hypothesisVersion = 0;

    // --- App state ---
    static bool running = true;
    static bool debugMode = false;
    static IntPtr trayHwnd = IntPtr.Zero;
    static IntPtr iconIdle = IntPtr.Zero;
    static IntPtr iconRecording = IntPtr.Zero;
    static WndProcDelegate wndProcDelegate;
    static DateTime lastHotkeyTime = DateTime.MinValue;

    // --- Overlay state ---
    static IntPtr overlayHwnd = IntPtr.Zero;
    static WndProcDelegate overlayWndProcDelegate;
    static string overlayText = "";
    static uint overlayDotColor = DOT_RED;
    static IntPtr overlayFont = IntPtr.Zero;

    // =======================================================================
    //  ENTRY POINT
    // =======================================================================

    static void Main(string[] args)
    {
        debugMode = Array.Exists(args, a =>
            a.Equals("-debug", StringComparison.OrdinalIgnoreCase) ||
            a.Equals("--debug", StringComparison.OrdinalIgnoreCase));

        if (debugMode) AllocConsole();

        bool created;
        var mutex = new Mutex(false, "WinWhisper_SingleInstance", out created);
        if (!mutex.WaitOne(0, false))
        {
            Log("WinWhisper is already running.", "ERROR");
            return;
        }

        try
        {
            Log("Starting WinWhisper v" + VERSION);

            InitializeSpeech();
            Log("Speech engine initialized", "OK");

            InitializeTray();
            Log("Tray icon ready", "OK");

            InitializeOverlay();
            Log("Overlay ready", "OK");

            if (debugMode)
            {
                Console.WriteLine();
                Console.WriteLine("=== WinWhisper v" + VERSION + " ===");
                Console.WriteLine("  Hotkey:   Shift + = (the + key)");
                Console.WriteLine("  Quit:     Escape, Ctrl+C, or right-click tray > Exit");
                Console.WriteLine("  Engine:   WinRT cloud (pure Win32, no WinForms)");
                Console.WriteLine();
            }

            ShowBalloon("WinWhisper", "Press Shift+= (+) to start voice dictation.");

            // Main loop
            bool prevHotkey = false;
            bool prevEsc = false;
            int lastHypVer = 0;
            int lastResultVer = 0;

            while (running)
            {
                PumpMessages();
                Thread.Sleep(10);

                // Update overlay with live hypothesis during recording
                if (isListening)
                {
                    int hv = hypothesisVersion;
                    int rv = resultCount;
                    if (hv != lastHypVer || rv != lastResultVer)
                    {
                        lastHypVer = hv;
                        lastResultVer = rv;
                        string acc;
                        lock (accLock) { acc = accumulated.ToString(); }
                        string hyp = currentHypothesis;

                        string display;
                        if (acc.Length > 0 && hyp.Length > 0) display = acc + " " + hyp + "...";
                        else if (hyp.Length > 0) display = hyp + "...";
                        else if (acc.Length > 0) display = acc;
                        else display = "Listening...";

                        UpdateOverlayContent(display, DOT_RED);
                    }
                }

                // Poll + key: either Shift+= (keyboard +) or Numpad+
                bool shiftDown = (GetAsyncKeyState(VK_SHIFT) & 0x8000) != 0;
                bool oemPlusDown = (GetAsyncKeyState(VK_OEM_PLUS) & 0x8000) != 0;
                bool numpadPlusDown = (GetAsyncKeyState(VK_ADD) & 0x8000) != 0;
                bool hotkeyDown = (shiftDown && oemPlusDown) || numpadPlusDown;
                if (hotkeyDown && !prevHotkey)
                {
                    var now = DateTime.Now;
                    if ((now - lastHotkeyTime).TotalMilliseconds > DEBOUNCE_MS)
                    {
                        lastHotkeyTime = now;
                        HandleHotkey();
                    }
                }
                prevHotkey = hotkeyDown;

                // Poll Escape (debug mode only)
                if (debugMode)
                {
                    bool escDown = (GetAsyncKeyState(VK_ESCAPE) & 0x8000) != 0;
                    if (escDown && !prevEsc) running = false;
                    prevEsc = escDown;
                }
            }
        }
        catch (Exception ex)
        {
            Log("Fatal: " + ex.Message, "ERROR");
            if (debugMode) Console.WriteLine(ex.StackTrace);
        }
        finally
        {
            if (isListening) StopListening();
            try { ((dynamic)recognizer).Dispose(); } catch { }
            CleanupOverlay();
            CleanupTray();
            mutex.ReleaseMutex();
            Log("Goodbye!", "OK");
        }
    }

    static void HandleHotkey()
    {
        if (isStopping) return;

        if (isListening)
        {
            // STOP
            Log("Stopping...");
            UpdateTray(false, "WinWhisper - Processing...");
            ShowOverlayPersistent("Processing...", DOT_AMBER);
            StopListening();

            string text;
            lock (accLock) { text = accumulated.ToString(); }
            Log("Stopped: " + resultCount + " results, text='" + text + "'");
            UpdateTray(false, "WinWhisper - Ready");

            if (!string.IsNullOrEmpty(text))
            {
                ShowOverlayAutoHide(text, DOT_GREEN);
                TypeText(text);
                Log("Typed: '" + text + "'", "OK");
            }
            else
            {
                ShowOverlayAutoHide("No speech detected", DOT_GRAY);
                ResetSpeech();
            }
        }
        else
        {
            // START
            Log("Starting...");
            UpdateTray(true, "WinWhisper - Listening...");
            ShowOverlayPersistent("Listening...", DOT_RED);
            StartListening();
            if (!isListening)
            {
                // StartListening failed
                UpdateTray(false, "WinWhisper - Error");
                ShowOverlayAutoHide("Failed to start speech", DOT_ERROR);
            }
        }
    }

    static void PumpMessages()
    {
        MSG msg;
        while (PeekMessage(out msg, IntPtr.Zero, 0, 0, PM_REMOVE))
        {
            TranslateMessage(ref msg);
            DispatchMessage(ref msg);
        }
    }

    // =======================================================================
    //  TRAY ICON (pure Win32 Shell_NotifyIcon)
    // =======================================================================

    static void InitializeTray()
    {
        iconIdle = CreateCircleIcon(128, 128, 128);
        iconRecording = CreateCircleIcon(239, 68, 68);

        IntPtr hInstance = GetModuleHandle(null);
        wndProcDelegate = new WndProcDelegate(TrayWndProc);

        WNDCLASSEX wc = new WNDCLASSEX();
        wc.cbSize = (uint)Marshal.SizeOf(typeof(WNDCLASSEX));
        wc.lpfnWndProc = Marshal.GetFunctionPointerForDelegate(wndProcDelegate);
        wc.hInstance = hInstance;
        wc.lpszClassName = "WinWhisperTray";
        RegisterClassEx(ref wc);

        IntPtr HWND_MESSAGE = new IntPtr(-3);
        trayHwnd = CreateWindowEx(0, "WinWhisperTray", "WinWhisper", 0,
            0, 0, 0, 0, HWND_MESSAGE, IntPtr.Zero, hInstance, IntPtr.Zero);

        NOTIFYICONDATA nid = new NOTIFYICONDATA();
        nid.cbSize = Marshal.SizeOf(typeof(NOTIFYICONDATA));
        nid.hWnd = trayHwnd;
        nid.uID = 1;
        nid.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
        nid.uCallbackMessage = WM_TRAYICON;
        nid.hIcon = iconIdle;
        nid.szTip = "WinWhisper - Ready";
        Shell_NotifyIcon(NIM_ADD, ref nid);
    }

    static void UpdateTray(bool recording, string tooltip)
    {
        NOTIFYICONDATA nid = new NOTIFYICONDATA();
        nid.cbSize = Marshal.SizeOf(typeof(NOTIFYICONDATA));
        nid.hWnd = trayHwnd;
        nid.uID = 1;
        nid.uFlags = NIF_ICON | NIF_TIP;
        nid.hIcon = recording ? iconRecording : iconIdle;
        nid.szTip = tooltip != null && tooltip.Length > 127 ? tooltip.Substring(0, 127) : tooltip;
        Shell_NotifyIcon(NIM_MODIFY, ref nid);
    }

    static void ShowBalloon(string title, string message)
    {
        NOTIFYICONDATA nid = new NOTIFYICONDATA();
        nid.cbSize = Marshal.SizeOf(typeof(NOTIFYICONDATA));
        nid.hWnd = trayHwnd;
        nid.uID = 1;
        nid.uFlags = NIF_INFO;
        nid.szInfo = message;
        nid.szInfoTitle = title;
        nid.dwInfoFlags = NIIF_NONE;
        Shell_NotifyIcon(NIM_MODIFY, ref nid);
    }

    static void CleanupTray()
    {
        if (trayHwnd != IntPtr.Zero)
        {
            NOTIFYICONDATA nid = new NOTIFYICONDATA();
            nid.cbSize = Marshal.SizeOf(typeof(NOTIFYICONDATA));
            nid.hWnd = trayHwnd;
            nid.uID = 1;
            Shell_NotifyIcon(NIM_DELETE, ref nid);
            DestroyWindow(trayHwnd);
            trayHwnd = IntPtr.Zero;
        }
        if (iconIdle != IntPtr.Zero) { DestroyIcon(iconIdle); iconIdle = IntPtr.Zero; }
        if (iconRecording != IntPtr.Zero) { DestroyIcon(iconRecording); iconRecording = IntPtr.Zero; }
    }

    static IntPtr TrayWndProc(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam)
    {
        if (msg == WM_TRAYICON)
        {
            uint mouseMsg = (uint)(lParam.ToInt64() & 0xFFFF);
            if (mouseMsg == WM_RBUTTONUP)
            {
                ShowTrayMenu(hWnd);
                return IntPtr.Zero;
            }
        }
        else if (msg == WM_COMMAND)
        {
            int menuId = (int)(wParam.ToInt64() & 0xFFFF);
            if (menuId == MENU_EXIT)
            {
                running = false;
                return IntPtr.Zero;
            }
        }
        return DefWindowProc(hWnd, msg, wParam, lParam);
    }

    static void ShowTrayMenu(IntPtr hWnd)
    {
        POINT pt;
        GetCursorPos(out pt);

        IntPtr hMenu = CreatePopupMenu();
        AppendMenu(hMenu, MF_STRING | MF_GRAYED, 0, "WinWhisper v" + VERSION);
        AppendMenu(hMenu, MF_SEPARATOR, 0, null);
        AppendMenu(hMenu, MF_STRING, (uint)MENU_EXIT, "Exit");

        SetForegroundWindow(hWnd);
        TrackPopupMenu(hMenu, TPM_BOTTOMALIGN | TPM_RIGHTALIGN, pt.x, pt.y, 0, hWnd, IntPtr.Zero);
        PostMessage(hWnd, 0, IntPtr.Zero, IntPtr.Zero);

        DestroyMenu(hMenu);
    }

    // =======================================================================
    //  OVERLAY WINDOW (pure Win32 CreateWindowEx + GDI painting)
    // =======================================================================

    static void InitializeOverlay()
    {
        IntPtr hInstance = GetModuleHandle(null);
        overlayWndProcDelegate = new WndProcDelegate(OverlayWndProc);

        WNDCLASSEX wc = new WNDCLASSEX();
        wc.cbSize = (uint)Marshal.SizeOf(typeof(WNDCLASSEX));
        wc.lpfnWndProc = Marshal.GetFunctionPointerForDelegate(overlayWndProcDelegate);
        wc.hInstance = hInstance;
        wc.lpszClassName = "WinWhisperOverlay";
        RegisterClassEx(ref wc);

        RECT workArea;
        SystemParametersInfo(SPI_GETWORKAREA, 0, out workArea, 0);
        int ox = workArea.right - OVERLAY_WIDTH - 12;
        int oy = workArea.bottom - OVERLAY_HEIGHT - 12;

        uint exStyle = WS_EX_LAYERED | WS_EX_TOPMOST | WS_EX_TRANSPARENT | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW;
        overlayHwnd = CreateWindowEx(exStyle, "WinWhisperOverlay", "", WS_POPUP,
            ox, oy, OVERLAY_WIDTH, OVERLAY_HEIGHT, IntPtr.Zero, IntPtr.Zero, hInstance, IntPtr.Zero);

        SetLayeredWindowAttributes(overlayHwnd, 0, 235, LWA_ALPHA);
        overlayFont = CreateFont(-14, 0, 0, 0, 400, 0, 0, 0, 0, 0, 0, 5, 0, "Segoe UI");
    }

    static void UpdateOverlayContent(string text, uint dotColorBGR)
    {
        overlayText = text;
        overlayDotColor = dotColorBGR;
        InvalidateRect(overlayHwnd, IntPtr.Zero, true);
    }

    static void ShowOverlayPersistent(string text, uint dotColorBGR)
    {
        KillTimer(overlayHwnd, new IntPtr(OVERLAY_TIMER_ID));
        UpdateOverlayContent(text, dotColorBGR);
        ShowWindow(overlayHwnd, 8); // SW_SHOWNA
    }

    static void ShowOverlayAutoHide(string text, uint dotColorBGR)
    {
        UpdateOverlayContent(text, dotColorBGR);
        ShowWindow(overlayHwnd, 8); // SW_SHOWNA
        KillTimer(overlayHwnd, new IntPtr(OVERLAY_TIMER_ID));
        SetTimer(overlayHwnd, new IntPtr(OVERLAY_TIMER_ID), 2000, IntPtr.Zero);
    }

    static void HideOverlay()
    {
        KillTimer(overlayHwnd, new IntPtr(OVERLAY_TIMER_ID));
        ShowWindow(overlayHwnd, 0); // SW_HIDE
    }

    static void CleanupOverlay()
    {
        if (overlayHwnd != IntPtr.Zero) { DestroyWindow(overlayHwnd); overlayHwnd = IntPtr.Zero; }
        if (overlayFont != IntPtr.Zero) { DeleteObject(overlayFont); overlayFont = IntPtr.Zero; }
    }

    static IntPtr OverlayWndProc(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam)
    {
        if (msg == WM_PAINT)
        {
            PAINTSTRUCT ps;
            IntPtr hdc = BeginPaint(hWnd, out ps);

            IntPtr bgBrush = CreateSolidBrush(0x001E1E1E);
            RECT clientRect;
            clientRect.left = 0;
            clientRect.top = 0;
            clientRect.right = OVERLAY_WIDTH;
            clientRect.bottom = OVERLAY_HEIGHT;
            FillRect(hdc, ref clientRect, bgBrush);
            DeleteObject(bgBrush);

            IntPtr dotBrush = CreateSolidBrush(overlayDotColor);
            IntPtr dotPen = CreatePen(0, 1, overlayDotColor);
            IntPtr oldBrush = SelectObject(hdc, dotBrush);
            IntPtr oldPen = SelectObject(hdc, dotPen);
            Ellipse(hdc, 12, 15, 24, 27);
            SelectObject(hdc, oldBrush);
            SelectObject(hdc, oldPen);
            DeleteObject(dotBrush);
            DeleteObject(dotPen);

            IntPtr oldFont = SelectObject(hdc, overlayFont);
            SetTextColor(hdc, 0x00DCDCDC);
            SetBkMode(hdc, TRANSPARENT);
            RECT textRect;
            textRect.left = 32;
            textRect.top = 0;
            textRect.right = OVERLAY_WIDTH - 10;
            textRect.bottom = OVERLAY_HEIGHT;
            string displayText = overlayText ?? "";
            DrawText(hdc, displayText, displayText.Length, ref textRect,
                DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS);
            SelectObject(hdc, oldFont);

            EndPaint(hWnd, ref ps);
            return IntPtr.Zero;
        }
        else if (msg == WM_TIMER && wParam.ToInt64() == OVERLAY_TIMER_ID)
        {
            HideOverlay();
            return IntPtr.Zero;
        }
        return DefWindowProc(hWnd, msg, wParam, lParam);
    }

    // --- Icon creation (GDI) ---

    static IntPtr CreateCircleIcon(byte r, byte g, byte b)
    {
        int size = 16;
        byte[] pixels = new byte[size * size * 4];
        int maskStride = ((size + 31) / 32) * 4;
        byte[] mask = new byte[maskStride * size];

        int cx = size / 2, cy = size / 2;
        int rad = size / 2 - 1;

        for (int y = 0; y < size; y++)
        {
            int by = size - 1 - y;
            for (int x = 0; x < size; x++)
            {
                int dx = x - cx, dy = y - cy;
                if (dx * dx + dy * dy <= rad * rad)
                {
                    int pi = (by * size + x) * 4;
                    pixels[pi + 0] = b;
                    pixels[pi + 1] = g;
                    pixels[pi + 2] = r;
                    pixels[pi + 3] = 255;
                }
                else
                {
                    int mi = by * maskStride + x / 8;
                    mask[mi] |= (byte)(0x80 >> (x % 8));
                }
            }
        }

        IntPtr hbmColor = CreateBitmap(size, size, 1, 32, pixels);
        IntPtr hbmMask = CreateBitmap(size, size, 1, 1, mask);

        ICONINFO ii = new ICONINFO();
        ii.fIcon = 1;
        ii.hbmColor = hbmColor;
        ii.hbmMask = hbmMask;

        IntPtr hIcon = CreateIconIndirect(ref ii);

        DeleteObject(hbmColor);
        DeleteObject(hbmMask);

        return hIcon;
    }

    // =======================================================================
    //  SPEECH ENGINE (WinRT via reflection)
    // =======================================================================

    static void InitializeSpeech()
    {
        var recType = Type.GetType(
            "Windows.Media.SpeechRecognition.SpeechRecognizer, " +
            "Windows.Media.SpeechRecognition, ContentType=WindowsRuntime", true);
        var sessionType = Type.GetType(
            "Windows.Media.SpeechRecognition.SpeechContinuousRecognitionSession, " +
            "Windows.Media.SpeechRecognition, ContentType=WindowsRuntime", true);
        compileResultType = Type.GetType(
            "Windows.Media.SpeechRecognition.SpeechRecognitionCompilationResult, " +
            "Windows.Media.SpeechRecognition, ContentType=WindowsRuntime", true);
        var scenarioType = Type.GetType(
            "Windows.Media.SpeechRecognition.SpeechRecognitionScenario, " +
            "Windows.Media.SpeechRecognition, ContentType=WindowsRuntime", true);
        var topicConstraintType = Type.GetType(
            "Windows.Media.SpeechRecognition.SpeechRecognitionTopicConstraint, " +
            "Windows.Media.SpeechRecognition, ContentType=WindowsRuntime", true);

        var extType = typeof(WindowsRuntimeSystemExtensions);
        asTaskAction = extType.GetMethods().First(m =>
            m.Name == "AsTask" && !m.IsGenericMethod &&
            m.GetParameters().Length == 1 &&
            m.GetParameters()[0].ParameterType.ToString() == "Windows.Foundation.IAsyncAction");
        asTaskOperation = extType.GetMethods().First(m =>
            m.Name == "AsTask" && m.IsGenericMethodDefinition &&
            m.GetGenericArguments().Length == 1 &&
            m.GetParameters().Length == 1 &&
            m.GetParameters()[0].ParameterType.ToString().StartsWith("Windows.Foundation.IAsyncOperation`1"));

        recognizer = Activator.CreateInstance(recType);

        try
        {
            object dictationScenario = Enum.Parse(scenarioType, "Dictation");
            object dictation = Activator.CreateInstance(topicConstraintType, dictationScenario, "dictation");
            var ivectorOpen = Type.GetType(
                "Windows.Foundation.Collections.IVector`1, Windows.Foundation, ContentType=WindowsRuntime");
            var iconstraintType = Type.GetType(
                "Windows.Media.SpeechRecognition.ISpeechRecognitionConstraint, " +
                "Windows.Media.SpeechRecognition, ContentType=WindowsRuntime");
            if (ivectorOpen != null && iconstraintType != null)
            {
                var vectorType = ivectorOpen.MakeGenericType(iconstraintType);
                var appendMethod = vectorType.GetMethod("Append");
                if (appendMethod != null)
                    appendMethod.Invoke(((dynamic)recognizer).Constraints, new object[] { dictation });
            }
        }
        catch { }

        object compileOp = ((dynamic)recognizer).CompileConstraintsAsync();
        var compileTask = (Task)asTaskOperation
            .MakeGenericMethod(compileResultType)
            .Invoke(null, new object[] { compileOp });
        compileTask.Wait();
        dynamic compileResult = ((dynamic)compileTask).Result;
        if (compileResult.Status.ToString() != "Success")
            throw new Exception("CompileConstraintsAsync failed: " + compileResult.Status);

        session = ((dynamic)recognizer).ContinuousRecognitionSession;

        var resultEvent = sessionType.GetEvent("ResultGenerated");
        if (resultEvent != null)
        {
            var handler = CreateTypedHandler(resultEvent.EventHandlerType,
                new Action<object, object>(OnResultGenerated));
            ((dynamic)session).ResultGenerated += (dynamic)handler;
        }

        var hypothesisEvent = recType.GetEvent("HypothesisGenerated");
        if (hypothesisEvent != null)
        {
            var handler = CreateTypedHandler(hypothesisEvent.EventHandlerType,
                new Action<object, object>(OnHypothesisGenerated));
            ((dynamic)recognizer).HypothesisGenerated += (dynamic)handler;
        }

        var completedEvent = sessionType.GetEvent("Completed");
        if (completedEvent != null)
        {
            var handler = CreateTypedHandler(completedEvent.EventHandlerType,
                new Action<object, object>(OnSessionCompleted));
            ((dynamic)session).Completed += (dynamic)handler;
        }
    }

    static void StartListening()
    {
        if (isListening) return;
        if (isStopping)
        {
            int wait = 0;
            while (isStopping && wait < 8000) { PumpMessages(); Thread.Sleep(10); wait += 10; }
            if (isStopping) { isStopping = false; return; }
        }

        lock (accLock) { accumulated.Clear(); }
        resultCount = 0;
        sessionCompleted = false;
        currentHypothesis = "";
        hypothesisVersion = 0;

        for (int attempt = 0; attempt < 2; attempt++)
        {
            try
            {
                object startOp = ((dynamic)session).StartAsync();
                var startTask = (Task)asTaskAction.Invoke(null, new object[] { startOp });
                while (!startTask.IsCompleted) { PumpMessages(); Thread.Sleep(10); }
                if (startTask.IsFaulted)
                {
                    string msg = startTask.Exception != null && startTask.Exception.InnerException != null
                        ? startTask.Exception.InnerException.Message : "StartAsync failed";
                    Log("StartAsync: " + msg, "ERROR");
                    if (attempt == 0) { ResetSpeech(); continue; }
                    return;
                }
                isListening = true;
                Log("Listening started", "OK");
                return;
            }
            catch (Exception ex)
            {
                Log("Start: " + ex.Message, "ERROR");
                if (attempt == 0) { ResetSpeech(); continue; }
            }
        }
    }

    static void ResetSpeech()
    {
        Log("Resetting speech engine...");
        try { ((dynamic)recognizer).Dispose(); } catch { }
        isListening = false;
        isStopping = false;
        try { InitializeSpeech(); Log("Speech engine re-initialized", "OK"); }
        catch (Exception ex) { Log("ResetSpeech: " + ex.Message, "ERROR"); }
    }

    static void StopListening()
    {
        if (!isListening && !isStopping) return;
        isStopping = true;
        sessionCompleted = false;

        try
        {
            object stopOp = ((dynamic)session).StopAsync();
            var stopTask = (Task)asTaskAction.Invoke(null, new object[] { stopOp });
            int timeout = 800;
            while (!stopTask.IsCompleted && timeout > 0) { PumpMessages(); Thread.Sleep(10); timeout--; }

            int drain = 200;
            while (!sessionCompleted && drain > 0) { PumpMessages(); Thread.Sleep(10); drain--; }
        }
        catch (Exception ex) { Log("Stop: " + ex.Message, "ERROR"); }

        isListening = false;
        isStopping = false;
    }

    // --- WinRT event callbacks (called from background threads) ---

    static void OnResultGenerated(object sender, object eventArgs)
    {
        try
        {
            dynamic args = eventArgs;
            string text = args.Result.Text;
            if (!string.IsNullOrWhiteSpace(text))
            {
                lock (accLock)
                {
                    if (accumulated.Length > 0) accumulated.Append(" ");
                    accumulated.Append(text);
                }
                Interlocked.Increment(ref resultCount);
                currentHypothesis = "";
                Log("Result: " + text);
            }
        }
        catch { }
    }

    static void OnHypothesisGenerated(object sender, object eventArgs)
    {
        try
        {
            dynamic args = eventArgs;
            string text = args.Hypothesis.Text;
            currentHypothesis = text;
            Interlocked.Increment(ref hypothesisVersion);
            Log("Hypothesis: " + text);
        }
        catch { }
    }

    static void OnSessionCompleted(object sender, object eventArgs)
    {
        try
        {
            dynamic args = eventArgs;
            isListening = false;
            sessionCompleted = true;
            Log("Session completed: " + args.Status.ToString());
        }
        catch { }
    }

    static Delegate CreateTypedHandler(Type eventHandlerType, Action<object, object> callback)
    {
        var invokeMethod = eventHandlerType.GetMethod("Invoke");
        var parameters = invokeMethod.GetParameters();
        var senderParam = Expression.Parameter(parameters[0].ParameterType, "sender");
        var argsParam = Expression.Parameter(parameters[1].ParameterType, "args");
        var callExpr = Expression.Call(
            Expression.Constant(callback),
            typeof(Action<object, object>).GetMethod("Invoke"),
            Expression.Convert(senderParam, typeof(object)),
            Expression.Convert(argsParam, typeof(object)));
        var lambda = Expression.Lambda(eventHandlerType, callExpr, senderParam, argsParam);
        return lambda.Compile();
    }

    // =======================================================================
    //  TEXT INPUT (SendInput)
    // =======================================================================

    static void TypeText(string text)
    {
        if (string.IsNullOrEmpty(text)) return;
        INPUT[] inputs = new INPUT[text.Length * 2];
        for (int i = 0; i < text.Length; i++)
        {
            ushort ch = text[i];
            inputs[i * 2].type = INPUT_KEYBOARD;
            inputs[i * 2].union.ki.wScan = ch;
            inputs[i * 2].union.ki.dwFlags = KEYEVENTF_UNICODE;
            inputs[i * 2 + 1].type = INPUT_KEYBOARD;
            inputs[i * 2 + 1].union.ki.wScan = ch;
            inputs[i * 2 + 1].union.ki.dwFlags = KEYEVENTF_UNICODE | KEYEVENTF_KEYUP;
        }
        SendInput((uint)inputs.Length, inputs, Marshal.SizeOf(typeof(INPUT)));
    }

    // =======================================================================
    //  LOGGING
    // =======================================================================

    static void Log(string msg, string level)
    {
        if (!debugMode) return;
        string prefix = level == "OK" ? "[OK] " : level == "ERROR" ? "[ERROR] " : "[INFO] ";
        string time = DateTime.Now.ToString("HH:mm:ss.fff");
        Console.WriteLine("[" + time + "] " + prefix + msg);
    }

    static void Log(string msg) { Log(msg, "INFO"); }
}
