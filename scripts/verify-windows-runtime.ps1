param(
    [Parameter(Mandatory = $true)]
    [string]$RuntimeDirectory,
    [Parameter(Mandatory = $true)]
    [string]$FixturePath
)

$ErrorActionPreference = "Stop"
$runtime = (Resolve-Path -LiteralPath $RuntimeDirectory).Path
$fixture = (Resolve-Path -LiteralPath $FixturePath).Path
$required = @("libmpv-2.dll", "ffmpeg.exe", "ffprobe.exe", "runtime.json", "NOTICE.md")
foreach ($name in $required) {
    $file = Join-Path $runtime $name
    if (-not (Test-Path -LiteralPath $file)) {
        throw "Runtime is missing $name"
    }
}
$agplLicense = Join-Path $runtime "licenses\librempeg\COPYING.AGPLv3"
if (-not (Test-Path -LiteralPath $agplLicense)) {
    throw "Runtime is missing the AGPL license text"
}
foreach ($forbidden in @("mpv.exe", "libmpv.dll.a", "include")) {
    if (Test-Path -LiteralPath (Join-Path $runtime $forbidden)) {
        throw "Runtime contains forbidden SDK/player entry: $forbidden"
    }
}

$ffmpeg = Join-Path $runtime "ffmpeg.exe"
$decoders = (& $ffmpeg -hide_banner -decoders 2>&1 | Out-String)
if ($LASTEXITCODE -ne 0 -or $decoders -notmatch "\bac4\b") {
    throw "LibreMPEG AC-4 decoder is missing"
}
& $ffmpeg -hide_banner -v error -i $fixture -t 2 -f null -
if ($LASTEXITCODE -ne 0) {
    throw "LibreMPEG failed to decode the AC-4 fixture"
}
$license = (& $ffmpeg -hide_banner -L 2>&1 | Out-String)
if ($license -notmatch "(?s)General Public License.*version 3") {
    throw "Unexpected runtime license output"
}

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class MpvLibreProbe {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool SetDllDirectory(string path);

    [DllImport("libmpv-2.dll", CallingConvention = CallingConvention.Cdecl)]
    public static extern IntPtr mpv_create();

    [DllImport("libmpv-2.dll", CallingConvention = CallingConvention.Cdecl)]
    public static extern int mpv_set_option_string(IntPtr handle, string name, string value);

    [DllImport("libmpv-2.dll", CallingConvention = CallingConvention.Cdecl)]
    public static extern int mpv_initialize(IntPtr handle);

    [DllImport("libmpv-2.dll", CallingConvention = CallingConvention.Cdecl)]
    public static extern IntPtr mpv_get_property_string(IntPtr handle, string name);

    [DllImport("libmpv-2.dll", CallingConvention = CallingConvention.Cdecl)]
    public static extern UInt32 mpv_client_api_version();

    [DllImport("libmpv-2.dll", CallingConvention = CallingConvention.Cdecl)]
    public static extern void mpv_free(IntPtr value);

    [DllImport("libmpv-2.dll", CallingConvention = CallingConvention.Cdecl)]
    public static extern void mpv_terminate_destroy(IntPtr handle);
}
"@

[MpvLibreProbe]::SetDllDirectory($runtime) | Out-Null
$player = [MpvLibreProbe]::mpv_create()
if ($player -eq [IntPtr]::Zero) {
    throw "mpv_create failed"
}
try {
    [MpvLibreProbe]::mpv_set_option_string($player, "config", "no") | Out-Null
    [MpvLibreProbe]::mpv_set_option_string($player, "audio", "no") | Out-Null
    [MpvLibreProbe]::mpv_set_option_string($player, "video", "no") | Out-Null
    if ([MpvLibreProbe]::mpv_initialize($player) -lt 0) {
        throw "mpv_initialize failed"
    }
    $value = [MpvLibreProbe]::mpv_get_property_string($player, "decoder-list")
    if ($value -eq [IntPtr]::Zero) {
        throw "libmpv decoder-list is unavailable"
    }
    try {
        $decoderList = [Runtime.InteropServices.Marshal]::PtrToStringUTF8($value)
    } finally {
        [MpvLibreProbe]::mpv_free($value)
    }
    if ($decoderList -notmatch '"codec":"ac4"') {
        throw "libmpv decoder-list does not contain AC-4"
    }
    $api = [MpvLibreProbe]::mpv_client_api_version()
    $major = ($api -shr 16) -band 0xffff
    $minor = $api -band 0xffff
    Write-Output "libmpv client API $major.$minor; LibreMPEG AC-4 verified."
} finally {
    [MpvLibreProbe]::mpv_terminate_destroy($player)
}
