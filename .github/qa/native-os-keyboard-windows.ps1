[CmdletBinding(DefaultParameterSetName='Run')]
param(
    [Parameter(Mandatory,ParameterSetName='Run')][string]$Executable,
    [Parameter(Mandatory,ParameterSetName='Run')][string]$Target,
    [Parameter(Mandatory)][string]$Output,
    [Parameter(ParameterSetName='Run')][switch]$SendDown,
    [Parameter(Mandatory,ParameterSetName='Preflight')][switch]$PreflightOnly
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted' -or $env:RUNNER_OS -ne 'Windows') {
    throw 'This prototype is restricted to a disposable GitHub-hosted Windows VM.'
}
if ($SendDown -and $env:FERAIL_OS_INPUT_AUTHORIZED -ne 'windows-disposable-vm') { throw 'Explicit authorization for Windows disposable-VM OS input is missing.' }
if (Test-Path $Output) { throw 'Output must be a fresh directory.' }
New-Item -ItemType Directory $Output | Out-Null
Add-Type @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class NativeKeyboardQA {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int left,top,right,bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct KEYBDINPUT {
        public ushort vk,scan; public uint flags,time; public UIntPtr extra;
    }
    [StructLayout(LayoutKind.Sequential)] public struct MOUSEINPUT {
        public int dx,dy; public uint data,flags,time; public UIntPtr extra;
    }
    [StructLayout(LayoutKind.Explicit)] public struct UNION {
        [FieldOffset(0)] public KEYBDINPUT keyboard;
        [FieldOffset(0)] public MOUSEINPUT mouse;
    }
    [StructLayout(LayoutKind.Sequential)] public struct INPUT { public uint type; public UNION data; }
    public delegate bool EnumProc(IntPtr hwnd, IntPtr param);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc fn,IntPtr p);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h,out uint p);
    [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h,StringBuilder b,int n);
    [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h,StringBuilder b,int n);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h,out RECT r);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h,IntPtr after,int x,int y,int w,int hgt,uint flags);
    [DllImport("user32.dll")] public static extern int GetSystemMetrics(int n);
    [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int key);
    [DllImport("user32.dll",SetLastError=true)] public static extern uint SendInput(uint n,INPUT[] inputs,int size);
    [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr c);
    [DllImport("user32.dll",SetLastError=true)] public static extern IntPtr OpenInputDesktop(uint f,bool inherit,uint access);
    [DllImport("user32.dll")] public static extern bool CloseDesktop(IntPtr d);
    [DllImport("user32.dll")] public static extern IntPtr GetThreadDesktop(uint thread);
    [DllImport("user32.dll")] public static extern IntPtr GetProcessWindowStation();
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
    [DllImport("user32.dll",CharSet=CharSet.Unicode,SetLastError=true)]
    public static extern bool GetUserObjectInformation(IntPtr h,int index,StringBuilder b,uint bytes,out uint needed);
    [DllImport("wtsapi32.dll",SetLastError=true)] public static extern bool WTSQuerySessionInformation(IntPtr server,int id,int cls,out IntPtr data,out uint bytes);
    [DllImport("wtsapi32.dll")] public static extern void WTSFreeMemory(IntPtr data);
    public static string ObjectName(IntPtr h) {
        var b=new StringBuilder(256); uint n;
        if(h==IntPtr.Zero || !GetUserObjectInformation(h,2,b,512,out n)) throw new Exception("Cannot read desktop/window-station name");
        return b.ToString();
    }
    public static IntPtr[] Windows(uint pid) {
        var hs=new System.Collections.Generic.List<IntPtr>();
        EnumWindows((h,p)=>{uint owner;GetWindowThreadProcessId(h,out owner);if(owner==pid && IsWindowVisible(h))hs.Add(h);return true;},IntPtr.Zero);
        return hs.ToArray();
    }
    public static uint Down() {
        var a=new INPUT[2];
        a[0].type=1; a[0].data.keyboard.vk=0x28; a[0].data.keyboard.flags=1;
        a[1]=a[0]; a[1].data.keyboard.flags=3;
        return SendInput(2,a,Marshal.SizeOf(typeof(INPUT)));
    }
    public static uint ReleaseDown() {
        var a=new INPUT[1]; a[0].type=1;
        a[0].data.keyboard.vk=0x28; a[0].data.keyboard.flags=3;
        return SendInput(1,a,Marshal.SizeOf(typeof(INPUT)));
    }
}
'@
$session = (Get-Process -Id $PID).SessionId
if ($session -eq 0) { throw 'Session 0 cannot qualify interactive input.' }
$data = [IntPtr]::Zero; $bytes = [uint32]0
if (-not [NativeKeyboardQA]::WTSQuerySessionInformation([IntPtr]::Zero,$session,8,[ref]$data,[ref]$bytes)) { throw 'Cannot query session state.' }
try { if ([Runtime.InteropServices.Marshal]::ReadInt32($data) -ne 0) { throw 'Session is not WTSActive.' } }
finally { [NativeKeyboardQA]::WTSFreeMemory($data) }
$station = [NativeKeyboardQA]::ObjectName([NativeKeyboardQA]::GetProcessWindowStation())
$desktop = [NativeKeyboardQA]::ObjectName([NativeKeyboardQA]::GetThreadDesktop([NativeKeyboardQA]::GetCurrentThreadId()))
$inputDesktop = [NativeKeyboardQA]::OpenInputDesktop(0,$false,1)
try { $inputName = [NativeKeyboardQA]::ObjectName($inputDesktop) }
finally { if ($inputDesktop -ne [IntPtr]::Zero) { [void][NativeKeyboardQA]::CloseDesktop($inputDesktop) } }
if ($station -ne 'WinSta0' -or $desktop -ne $inputName) { throw 'Not on the active interactive desktop.' }
$oldDpi = [NativeKeyboardQA]::SetThreadDpiAwarenessContext([IntPtr](-4))
if ($oldDpi -eq [IntPtr]::Zero) { throw 'Cannot obtain physical-pixel geometry.' }
$app = $null
$record = [ordered]@{ status='blocked'; session=$session; station=$station; desktop=$desktop; input_desktop=$inputName; input_requested=[bool]$SendDown; preflight_only=[bool]$PreflightOnly; previous_dpi_context=$oldDpi.ToInt64() }
try {
    $screenW=[NativeKeyboardQA]::GetSystemMetrics(0); $screenH=[NativeKeyboardQA]::GetSystemMetrics(1)
    $record.screen_pixels=@($screenW,$screenH)
    if ($screenW -lt 1000 -or $screenH -lt 700) { throw "Screen is too small: ${screenW}x${screenH}." }
    if ($PreflightOnly) { $record.status='interactive desktop preflight passed; no app launched or input sent'; return }
    $fixture=[IO.Path]::GetFullPath((Join-Path $env:RUNNER_TEMP 'ferail-native-os-keyboard'))
    $expectedTarget=Join-Path $fixture 'target'
    $initial=Join-Path $fixture 'initial'
    $Target=[IO.Path]::GetFullPath($Target)
    if ($Target -ne $expectedTarget) { throw 'Target must be the dedicated RUNNER_TEMP synthetic fixture.' }
    foreach ($path in @($fixture,$Target,$initial)) {
        $item=Get-Item -LiteralPath $path -Force
        if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "Fixture is not an ordinary directory: $path" }
    }
    if (@(Get-ChildItem -LiteralPath $initial -Force).Count -ne 0) { throw 'Initial startup directory must be empty.' }
    $names=@('01-first.txt','02-second.txt','03-third.txt')
    $files=@(Get-ChildItem -LiteralPath $Target -Force | Sort-Object Name)
    if ($files.Count -ne 3 -or (@($files.Name) -join '|') -ne ($names -join '|')) { throw 'Target must contain exactly the three synthetic files.' }
    foreach ($file in $files) {
        if ($file.PSIsContainer -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -or [IO.File]::ReadAllText($file.FullName).Replace("`r`n","`n") -ne "Synthetic qualification file: $($file.Name)`n") { throw "Unexpected fixture contents: $($file.Name)" }
    }
    $statePath=Join-Path $env:APPDATA 'Ferail/gpui-state.txt'
    $state=[IO.File]::ReadAllText($statePath)
    $lastDirs=@($state -split "`r?`n" | Where-Object { $_.StartsWith('last_dir=') })
    if ($lastDirs.Count -ne 1 -or $lastDirs[0] -ne "last_dir=$initial" -or $state -match '(?m)^tab=') { throw 'Seed must start in the empty initial fixture without restored tabs.' }
    Copy-Item -LiteralPath $statePath -Destination "$Output/seed-state.txt"
    $record.binary_sha256=(Get-FileHash $Executable -Algorithm SHA256).Hash
    $record.target=$Target; $record.initial_directory=$initial
    $record.fixture_files=@($files | ForEach-Object { @{name=$_.Name; sha256=(Get-FileHash $_.FullName -Algorithm SHA256).Hash} })
    $arguments="--navigate `"$Target`" --view list"
    $record.arguments=$arguments
    Add-Type -AssemblyName System.Drawing
    $app = Start-Process -FilePath $Executable -ArgumentList $arguments -NoNewWindow -PassThru -RedirectStandardOutput "$Output/stdout.log" -RedirectStandardError "$Output/stderr.log"
    $record.pid = $app.Id
    $deadline = [DateTime]::UtcNow.AddSeconds(40)
    do {
        if ($app.HasExited) { throw "Application exited before opening its window: $($app.ExitCode)" }
        $windows = @([NativeKeyboardQA]::Windows($app.Id))
        if ($windows.Count -eq 1) { break }
        Start-Sleep -Milliseconds 200
    } while ([DateTime]::UtcNow -lt $deadline)
    if ($windows.Count -ne 1) { throw "Expected exactly one visible application window; got $($windows.Count)." }
    $hwnd = $windows[0]
    $owner=[uint32]0
    $windowThread=[NativeKeyboardQA]::GetWindowThreadProcessId($hwnd,[ref]$owner)
    if ($owner -ne $app.Id -or $app.SessionId -ne $session -or [NativeKeyboardQA]::ObjectName([NativeKeyboardQA]::GetThreadDesktop($windowThread)) -ne $inputName) { throw 'Application identity/session/desktop mismatch.' }
    $cls = [Text.StringBuilder]::new(256); $title = [Text.StringBuilder]::new(512)
    [void][NativeKeyboardQA]::GetClassName($hwnd,$cls,256)
    [void][NativeKeyboardQA]::GetWindowText($hwnd,$title,512)
    $record.hwnd=$hwnd.ToInt64(); $record.window_class=$cls.ToString(); $record.title=$title.ToString()
    if (-not [NativeKeyboardQA]::SetWindowPos($hwnd,[IntPtr]::Zero,10,10,[Math]::Min(1400,$screenW-20),[Math]::Min(900,$screenH-20),0x14)) { throw 'Cannot size own application window.' }
    [void][NativeKeyboardQA]::SetForegroundWindow($hwnd)
    Start-Sleep -Seconds 5
    function Capture([string]$Name) {
        if ([NativeKeyboardQA]::GetForegroundWindow() -ne $hwnd -or [NativeKeyboardQA]::IsIconic($hwnd)) { throw 'Application lost foreground; no input or capture allowed.' }
        $r=[NativeKeyboardQA+RECT]::new()
        if (-not [NativeKeyboardQA]::GetWindowRect($hwnd,[ref]$r)) { throw 'Cannot get application bounds.' }
        if ($r.left -lt 0 -or $r.top -lt 0 -or $r.right -gt $screenW -or $r.bottom -gt $screenH) { throw 'Window extends off screen.' }
        $bitmap=[Drawing.Bitmap]::new($r.right-$r.left,$r.bottom-$r.top)
        $graphics=[Drawing.Graphics]::FromImage($bitmap)
        try {
            $graphics.CopyFromScreen($r.left,$r.top,0,0,$bitmap.Size,[Drawing.CopyPixelOperation]::SourceCopy)
            $bitmap.Save("$Output/$Name.png",[Drawing.Imaging.ImageFormat]::Png)
        } finally { $graphics.Dispose(); $bitmap.Dispose() }
        return @{image="$Name.png"; sha256=(Get-FileHash "$Output/$Name.png" -Algorithm SHA256).Hash; rect=@($r.left,$r.top,$r.right,$r.bottom); foreground=$hwnd.ToInt64()}
    }
    $record.initial=Capture 'initial'
    if ($SendDown) {
        foreach ($key in @(0x10,0x11,0x12,0x5B,0x5C,0x28)) {
            if (([int][NativeKeyboardQA]::GetAsyncKeyState($key) -band 0x8000) -ne 0) { throw "Key already held: $key" }
        }
        if ([NativeKeyboardQA]::GetForegroundWindow() -ne $hwnd) { throw 'Foreground changed before SendInput.' }
        $record.send_input_count=[NativeKeyboardQA]::Down()
        $record.send_input_last_error=[Runtime.InteropServices.Marshal]::GetLastWin32Error()
        if ($record.send_input_count -eq 1 -and [NativeKeyboardQA]::GetForegroundWindow() -eq $hwnd) {
            $releaseOwner=[uint32]0
            [void][NativeKeyboardQA]::GetWindowThreadProcessId($hwnd,[ref]$releaseOwner)
            if ($releaseOwner -eq $app.Id -and -not $app.HasExited) { $record.partial_send_release_count=[NativeKeyboardQA]::ReleaseDown() }
        }
        if ($record.send_input_count -ne 2) { throw 'SendInput did not insert both Down events; UIPI is one possible cause.' }
        Start-Sleep -Seconds 2
        if (([int][NativeKeyboardQA]::GetAsyncKeyState(0x28) -band 0x8000) -ne 0) { throw 'Down key remains held.' }
        $record.down=Capture 'down'
    }
    $record.status='captures pending independent visual review'
} catch { $record.error=$_.Exception.Message; throw }
finally {
    if ($null -ne $app -and -not $app.HasExited) {
        if (-not $app.CloseMainWindow() -or -not $app.WaitForExit(15000)) { $record.cleanup_error='Own app did not close normally; no forced termination attempted.' }
    }
    if ($null -ne $app -and $app.HasExited) {
        $record.app_exit_code=$app.ExitCode
        if ($app.ExitCode -ne 0) { $record.cleanup_error="Own app exited with code $($app.ExitCode)." }
    }
    $record | ConvertTo-Json -Depth 8 | Set-Content "$Output/manifest.json"
    [void][NativeKeyboardQA]::SetThreadDpiAwarenessContext($oldDpi)
    if ($record.Contains('cleanup_error')) { throw $record.cleanup_error }
}
