#Requires -Version 5.1
<#
.SYNOPSIS
    Report the time zone database a host carries and prove what a zone actually
    does in a given autumn.

.DESCRIPTION
    PowerShell counterpart of tz/tzcheck.sh, for Windows hosts and for PowerShell 7
    on any platform. Nothing about the rules is hardcoded: transitions are found by
    bisecting the host's own TimeZoneInfo data, so the script stays correct when the
    rules change again.

    Written for the Alberta / America/Edmonton change: from IANA tzdata 2026c the zone
    stops observing the autumn change and stays on -06:00 (as CST) instead of falling
    back to MST -07:00. Windows carries its own registry-based zone data updated
    through Windows Update, so a Windows box can disagree with a Linux box next to it.

.PARAMETER Zone
    IANA zone id to inspect (default America/Edmonton). On Windows PowerShell 5.1,
    which cannot resolve IANA ids, a small IANA -> Windows fallback map is used and
    the report says so.

.PARAMETER WindowsZone
    Force a Windows zone id (e.g. 'Mountain Standard Time') instead of resolving Zone.

.PARAMETER Year
    Year to inspect (default 2026).

.PARAMETER NoRuntimes
    Skip the java / node / python / mysql cross-checks.

.PARAMETER MySql
    Arguments passed verbatim to the mysql client to also check CONVERT_TZ,
    e.g. -MySql "-h db1 -u root -psecret".

.PARAMETER ExpectNoFallback
    Exit 1 if the zone still falls back that autumn (CI mode).

.PARAMETER Quiet
    Print the verdict only.

.PARAMETER EmitResult
    Print the machine-readable TZCHECK-RESULT line (used when collecting from many hosts).

.EXAMPLE
    .\tzcheck.ps1

.EXAMPLE
    .\tzcheck.ps1 -Zone Europe/Dublin -Year 2027

.EXAMPLE
    Invoke-Command -ComputerName app1,app2 -FilePath .\tzcheck.ps1

.NOTES
    Exit codes: 0 as expected, 1 still falls back / zone not found, 2 usage error.
#>
[CmdletBinding()]
param(
    [string] $Zone = 'America/Edmonton',
    [string] $WindowsZone,
    [int]    $Year = 2026,
    [switch] $NoRuntimes,
    [string] $MySql,
    [switch] $ExpectNoFallback,
    [switch] $Quiet,
    [switch] $EmitResult
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Continue'

$script:Version = '1.0.0'

# ---------------------------------------------------------------------------
# output helpers
# ---------------------------------------------------------------------------
function Write-Head { param([string] $Text)
    if (-not $Quiet) { Write-Host ''; Write-Host $Text -ForegroundColor Cyan }
}
function Write-Kv { param([string] $Key, [string] $Value)
    if (-not $Quiet) { Write-Host ('  {0,-26} {1}' -f $Key, $Value) }
}
function Write-Line { param([string] $Text)
    if (-not $Quiet) { Write-Host $Text }
}
function Test-Cmd { param([string] $Name)
    [bool] (Get-Command $Name -ErrorAction SilentlyContinue)
}

$script:IsWindowsHost = $true
if (Test-Path Variable:\IsWindows) { $script:IsWindowsHost = $IsWindows }   # PS 6+ automatic variable

# ---------------------------------------------------------------------------
# zone resolution
# ---------------------------------------------------------------------------
# Windows PowerShell 5.1 has no ICU and cannot look up IANA ids. The map covers the
# zones this toolkit is normally pointed at; anything else needs -WindowsZone.
$script:IanaToWindows = @{
    'America/Edmonton'    = 'Mountain Standard Time'
    'America/Denver'      = 'Mountain Standard Time'
    'America/Winnipeg'    = 'Central Standard Time'
    'America/Chicago'     = 'Central Standard Time'
    'America/Toronto'     = 'Eastern Standard Time'
    'America/New_York'    = 'Eastern Standard Time'
    'America/Vancouver'   = 'Pacific Standard Time'
    'America/Los_Angeles' = 'Pacific Standard Time'
    'Europe/London'       = 'GMT Standard Time'
    'Europe/Dublin'       = 'GMT Standard Time'
    'Europe/Paris'        = 'W. Europe Standard Time'
    'Asia/Shanghai'       = 'China Standard Time'
    'Asia/Tokyo'          = 'Tokyo Standard Time'
    'UTC'                 = 'UTC'
}

$script:ZoneSource = 'direct'

function Resolve-Zone {
    param([string] $Id, [string] $Forced)

    if ($Forced) {
        try {
            $script:ZoneSource = 'forced Windows id'
            return [TimeZoneInfo]::FindSystemTimeZoneById($Forced)
        } catch {
            return $null
        }
    }
    try {
        $script:ZoneSource = 'direct'
        return [TimeZoneInfo]::FindSystemTimeZoneById($Id)
    } catch {
        # fall through to the map
    }
    if ($script:IanaToWindows.ContainsKey($Id)) {
        $win = $script:IanaToWindows[$Id]
        try {
            $script:ZoneSource = "IANA->Windows map ($Id -> $win)"
            return [TimeZoneInfo]::FindSystemTimeZoneById($win)
        } catch {
            return $null
        }
    }
    return $null
}

# ---------------------------------------------------------------------------
# offset primitives - everything is computed from TimeZoneInfo, never assumed
# ---------------------------------------------------------------------------
function Get-OffsetSeconds {
    param([TimeZoneInfo] $Tz, [datetime] $Utc)
    [int] $Tz.GetUtcOffset([datetime]::SpecifyKind($Utc, 'Utc')).TotalSeconds
}

function Get-ZoneState {
    param([TimeZoneInfo] $Tz, [datetime] $Utc)
    $u = [datetime]::SpecifyKind($Utc, 'Utc')
    $off = [int] $Tz.GetUtcOffset($u).TotalSeconds
    $dst = $Tz.IsDaylightSavingTime([System.DateTimeOffset]::new($u))
    '{0}|{1}' -f $off, $dst
}

function Format-Offset {
    param([int] $Seconds)
    $sign = '+'
    if ($Seconds -lt 0) { $sign = '-'; $Seconds = -$Seconds }
    $h = [int] [math]::Floor($Seconds / 3600)
    $m = [int] [math]::Floor(($Seconds % 3600) / 60)
    '{0}{1:d2}:{2:d2}' -f $sign, $h, $m
}

function Get-LocalStamp {
    param([TimeZoneInfo] $Tz, [datetime] $Utc)
    $u = [datetime]::SpecifyKind($Utc, 'Utc')
    $local = [TimeZoneInfo]::ConvertTimeFromUtc($u, $Tz)
    $off = Get-OffsetSeconds -Tz $Tz -Utc $u
    $name = if ($Tz.IsDaylightSavingTime([System.DateTimeOffset]::new($u))) { $Tz.DaylightName } else { $Tz.StandardName }
    '{0:yyyy-MM-dd HH:mm:ss} {1} {2}' -f $local, (Format-Offset $off), $name
}

# bisect for the first instant whose state differs from the state at $Lo
function Find-Transition {
    param([TimeZoneInfo] $Tz, [datetime] $Lo, [datetime] $Hi)
    $stateLo = Get-ZoneState -Tz $Tz -Utc $Lo
    while (($Hi - $Lo).TotalSeconds -gt 1) {
        $mid = $Lo.AddSeconds([math]::Floor((($Hi - $Lo).TotalSeconds) / 2))
        if ((Get-ZoneState -Tz $Tz -Utc $mid) -eq $stateLo) { $Lo = $mid } else { $Hi = $mid }
    }
    $Hi
}

# ---------------------------------------------------------------------------
# host facts
# ---------------------------------------------------------------------------
function Get-HostLine {
    $os = 'unknown'
    if ($script:IsWindowsHost) {
        try {
            $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
            $ubr = ''
            if ($cv.PSObject.Properties.Name -contains 'UBR') { $ubr = '.' + $cv.UBR }
            $disp = ''
            if ($cv.PSObject.Properties.Name -contains 'DisplayVersion') { $disp = ' ' + $cv.DisplayVersion }
            $os = '{0}{1} (build {2}{3})' -f $cv.ProductName, $disp, $cv.CurrentBuildNumber, $ubr
        } catch {
            $os = 'Windows ' + [System.Environment]::OSVersion.Version
        }
    } else {
        try { $os = (uname -s) + ' ' + (uname -r) } catch { $os = 'non-Windows' }
    }
    '{0} - {1} - PowerShell {2}' -f [System.Environment]::MachineName, $os, $PSVersionTable.PSVersion
}

function Get-TzDataInfo {
    # returns @{ Version = ...; Source = ... }
    if ($script:IsWindowsHost) {
        # Windows has no IANA-style version string. Recent builds expose a TzVersion
        # DWORD under the Time Zones key; otherwise fall back to the OS build number,
        # since zone data arrives with the cumulative update.
        $v = 'unknown'
        $src = 'HKLM\...\Time Zones'
        $key = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Time Zones'
        try {
            $tzk = Get-ItemProperty $key -ErrorAction Stop
            if ($tzk.PSObject.Properties.Name -contains 'TzVersion') {
                $v = 'TzVersion 0x{0:X}' -f $tzk.TzVersion
                $src = "$key\TzVersion"
            } else {
                $count = @(Get-ChildItem $key -ErrorAction Stop).Count
                $v = "$count zones (no TzVersion value)"
                $src = $key
            }
        } catch { }
        try {
            $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
            $ubr = ''
            if ($cv.PSObject.Properties.Name -contains 'UBR') { $ubr = '.' + $cv.UBR }
            $v = '{0} / build {1}{2}' -f $v, $cv.CurrentBuildNumber, $ubr
        } catch { }
        return @{ Version = $v; Source = $src }
    }
    foreach ($f in @('/usr/share/zoneinfo/+VERSION', '/usr/share/zoneinfo/tzdata.zi')) {
        if (Test-Path $f) {
            $line = (Get-Content $f -TotalCount 3 | Where-Object { $_ -match '^\s*(#\s*version\s+)?[0-9]{4}[a-z]' } | Select-Object -First 1)
            if ($line) {
                $ver = ($line -replace '^#\s*version\s+', '').Trim()
                return @{ Version = $ver; Source = $f }
            }
        }
    }
    return @{ Version = 'unknown'; Source = 'none' }
}

# Windows keeps per-year rules ("Dynamic DST"); .NET exposes them as adjustment rules
# on every platform, so this is the authoritative "what will this box do" view.
function Show-AdjustmentRules {
    param([TimeZoneInfo] $Tz, [int] $Year)
    $rules = $Tz.GetAdjustmentRules()
    if (-not $rules -or $rules.Count -eq 0) {
        Write-Line '  no adjustment rules at all - this zone never observes DST on this host'
        return
    }
    $hit = $false
    foreach ($r in $rules) {
        if ($r.DateStart.Year -le $Year -and $r.DateEnd.Year -ge $Year) {
            $hit = $true
            Write-Line ('  rule {0:yyyy-MM-dd} .. {1:yyyy-MM-dd}  delta {2}' -f $r.DateStart, $r.DateEnd, $r.DaylightDelta)
            Write-Line ('    start {0}' -f (Format-TransitionTime $r.DaylightTransitionStart))
            Write-Line ('    end   {0}' -f (Format-TransitionTime $r.DaylightTransitionEnd))
        }
    }
    if (-not $hit) {
        Write-Line ("  no adjustment rule covers {0} - this host applies no DST that year" -f $Year)
    }
}

function Format-TransitionTime {
    param($T)
    if ($T.IsFixedDateRule) {
        '{0:d2}-{1:d2} at {2:HH:mm}' -f $T.Month, $T.Day, $T.TimeOfDay
    } else {
        'month {0}, week {1}, {2}, at {3:HH:mm}' -f $T.Month, $T.Week, $T.DayOfWeek, $T.TimeOfDay
    }
}

# ---------------------------------------------------------------------------
# runtime cross-checks - these carry their own copy of the tz database
# ---------------------------------------------------------------------------
function Invoke-RuntimeChecks {
    param([string] $ZoneId, [int] $Year)
    if ($NoRuntimes) { return }
    Write-Head 'Runtime cross-checks (each carries its own tz copy)'

    if (Test-Cmd 'java') {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("tzprobe_" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        $java = @'
import java.time.*;
import java.time.zone.ZoneRulesProvider;
public class TzProbe {
  public static void main(String[] a) {
    String zone = a[0];
    int year = Integer.parseInt(a[1]);
    ZoneId z = ZoneId.of(zone);
    ZoneOffset oct = ZonedDateTime.of(year, 10, 15, 12, 0, 0, 0, z).getOffset();
    ZoneOffset nov = ZonedDateTime.of(year, 11, 15, 12, 0, 0, 0, z).getOffset();
    String db;
    try { db = ZoneRulesProvider.getVersions(zone).lastKey(); } catch (Exception e) { db = "?"; }
    System.out.println(db + "|" + nov + "|" + (oct.equals(nov) ? "no autumn change" : "falls back"));
  }
}
'@
        $file = Join-Path $tmp 'TzProbe.java'
        Set-Content -Path $file -Value $java -Encoding ASCII
        $out = & java $file $ZoneId $Year 2>$null | Select-Object -Last 1
        $jv = (& java -version 2>&1 | Select-Object -First 1)
        if ($out) {
            $p = $out -split '\|'
            Write-Kv 'java' ('{0} | tzdb {1} - Nov 15 {2} ({3})' -f $jv, $p[0], $p[1], $p[2])
        } else {
            Write-Kv 'java' "$jv - probe failed (JRE without the single-file launcher?)"
        }
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }

    if (Test-Cmd 'node') {
        $js = 'const z=process.argv[1],y=Number(process.argv[2]);' +
              'const f=d=>new Intl.DateTimeFormat("en-US",{timeZone:z,timeZoneName:"longOffset"})' +
              '.formatToParts(d).find(p=>p.type==="timeZoneName").value;' +
              'const o=new Date(Date.UTC(y,9,15,18)),n=new Date(Date.UTC(y,10,15,19));' +
              'console.log(f(n)+"|"+(f(o)===f(n)?"no autumn change":"falls back"));'
        $out = & node -e $js $ZoneId $Year 2>$null
        if ($out) {
            $p = $out -split '\|'
            Write-Kv ('node ' + (& node --version)) ('Nov 15 {0} ({1})' -f $p[0], $p[1])
        }
    }

    $py = if (Test-Cmd 'python3') { 'python3' } elseif (Test-Cmd 'python') { 'python' } else { $null }
    if ($py) {
        $code = @'
import sys, datetime
zone, year = sys.argv[1], int(sys.argv[2])
try:
    from zoneinfo import ZoneInfo
    tz = ZoneInfo(zone)
    nov = datetime.datetime(year, 11, 15, 12, tzinfo=tz)
    oct_ = datetime.datetime(year, 10, 15, 12, tzinfo=tz)
    src = "OS db"
    try:
        import tzdata
        src = "tzdata module %s (shadows OS db)" % tzdata.IANA_VERSION
    except ImportError:
        pass
    print("%s|%s|%s|%s" % (nov.strftime("%z"), nov.tzname(),
          "no autumn change" if nov.utcoffset() == oct_.utcoffset() else "falls back", src))
except Exception as e:
    print("error|%s||" % e)
'@
        $tmpPy = Join-Path ([System.IO.Path]::GetTempPath()) ("tzprobe_" + [guid]::NewGuid().ToString('N') + '.py')
        Set-Content -Path $tmpPy -Value $code -Encoding ASCII
        $out = & $py $tmpPy $ZoneId $Year 2>$null
        Remove-Item $tmpPy -Force -ErrorAction SilentlyContinue
        if ($out) {
            $p = $out -split '\|'
            Write-Kv $py ('Nov 15 {0} {1} ({2})' -f $p[0], $p[1], $p[2])
            if ($p.Count -ge 4 -and $p[3]) { Write-Kv "$py tz source" $p[3] }
        }
    }

    if ($MySql -and (Test-Cmd 'mysql')) {
        $q = "SELECT @@system_time_zone, (SELECT COUNT(*) FROM mysql.time_zone_name), " +
             "CONVERT_TZ('$Year-10-15 18:00:00','UTC','$ZoneId'), " +
             "CONVERT_TZ('$Year-11-15 19:00:00','UTC','$ZoneId');"
        $mysqlArgs = ($MySql -split '\s+') + @('-N', '-B', '-e', $q)
        $out = & mysql @mysqlArgs 2>&1 | Select-Object -Last 1
        if ($out) {
            $p = $out -split "`t"
            Write-Kv 'mysql system_time_zone' $p[0]
            if ($p.Count -ge 4) {
                Write-Kv 'mysql tz tables loaded' ("{0} rows in mysql.time_zone_name" -f $p[1])
                Write-Kv 'mysql CONVERT_TZ oct'   $p[2]
                Write-Kv 'mysql CONVERT_TZ nov'   $p[3]
                if ($out -match 'NULL') {
                    Write-Host '  mysql returned NULL - the zoneinfo tables are not loaded; CONVERT_TZ cannot work' -ForegroundColor Yellow
                }
            }
        }
    }
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
$tz = Resolve-Zone -Id $Zone -Forced $WindowsZone
$tzdata = Get-TzDataInfo

if (-not $Quiet) {
    Write-Host ''
    Write-Host ('================ {0} ================' -f (Get-HostLine)) -ForegroundColor Cyan
}

Write-Head 'tz database'
Write-Kv 'tz data'          ('{0}  (from {1})' -f $tzdata.Version, $tzdata.Source)
Write-Kv 'requested zone'   $Zone
if ($tz) {
    Write-Kv 'resolved zone'  ('{0}  [{1}]' -f $tz.Id, $script:ZoneSource)
    Write-Kv 'standard name'  $tz.StandardName
    Write-Kv 'daylight name'  $tz.DaylightName
} else {
    Write-Kv 'resolved zone'  'NOT FOUND'
}
Write-Kv 'system time zone' ([TimeZoneInfo]::Local).Id
Write-Kv 'now'              ((Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + ' ' + (Format-Offset ([int]([TimeZoneInfo]::Local.GetUtcOffset((Get-Date).ToUniversalTime())).TotalSeconds)))

$verdict = 'ERROR'
$verdictText = ''
$novOffset = '?'

if (-not $tz) {
    $verdict = 'NO-ZONE'
    $verdictText = "zone '$Zone' could not be resolved on this host"
    if ($PSVersionTable.PSVersion.Major -lt 6 -and $script:IsWindowsHost) {
        $verdictText += ' (Windows PowerShell 5.1 cannot resolve IANA ids; pass -WindowsZone or use PowerShell 7)'
    }
} else {
    if ($script:ZoneSource -like 'IANA->Windows map*') {
        Write-Host ''
        Write-Host ('  NOTE: resolved through the fallback map. Windows zone rules are grouped ' +
                    'differently from IANA zones, so this describes the Windows zone, which may ' +
                    'no longer match ' + $Zone + '.') -ForegroundColor Yellow
    }

    Write-Head ("Adjustment rules covering {0} (as this host has them)" -f $Year)
    Show-AdjustmentRules -Tz $tz -Year $Year

    Write-Head ("{0} - transitions in {1} (bisected from this host's own data)" -f $tz.Id, $Year)
    $start = [datetime]::SpecifyKind([datetime]::new($Year, 1, 1, 0, 0, 0), 'Utc')
    $end   = [datetime]::SpecifyKind([datetime]::new($Year + 1, 1, 1, 0, 0, 0), 'Utc')
    $prev = $start
    $prevState = Get-ZoneState -Tz $tz -Utc $prev
    $n = 0
    for ($m = 1; $m -le 12; $m++) {
        $probe = if ($m -eq 12) { $end } else { [datetime]::SpecifyKind([datetime]::new($Year, $m + 1, 1, 0, 0, 0), 'Utc') }
        $state = Get-ZoneState -Tz $tz -Utc $probe
        if ($state -ne $prevState) {
            $tr = Find-Transition -Tz $tz -Lo $prev -Hi $probe
            $n++
            $before = $tr.AddSeconds(-1)
            $delta = (Get-OffsetSeconds -Tz $tz -Utc $tr) - (Get-OffsetSeconds -Tz $tz -Utc $before)
            Write-Line ('  #{0}      last: {1}' -f $n, (Get-LocalStamp -Tz $tz -Utc $before))
            Write-Line ('          next: {0}' -f (Get-LocalStamp -Tz $tz -Utc $tr))
            if ($delta -eq 0) {
                Write-Line ('          UTC : {0:yyyy-MM-dd HH:mm:ss} UTC   clocks do NOT move - DST flag / name only' -f $tr)
            } else {
                Write-Line ('          UTC : {0:yyyy-MM-dd HH:mm:ss} UTC   clocks move {1:+#;-#;0}min' -f $tr, ($delta / 60))
            }
        }
        $prev = $probe
        $prevState = $state
    }
    if ($n -eq 0) { Write-Line ("  no transitions at all in {0}" -f $Year) }

    # offsets around the autumn window, plus a fixed UTC instant rendered locally
    $uOct = [datetime]::SpecifyKind([datetime]::new($Year, 10, 15, 18, 0, 0), 'Utc')
    $uNov = [datetime]::SpecifyKind([datetime]::new($Year, 11, 15, 19, 0, 0), 'Utc')
    $uDec = [datetime]::SpecifyKind([datetime]::new($Year, 12, 15, 19, 0, 0), 'Utc')
    $uJan = [datetime]::SpecifyKind([datetime]::new($Year + 1, 1, 15, 19, 0, 0), 'Utc')
    $oOct = Get-OffsetSeconds -Tz $tz -Utc $uOct
    $oNov = Get-OffsetSeconds -Tz $tz -Utc $uNov
    $novOffset = Format-Offset $oNov

    Write-Head ("Offsets around the {0} autumn window" -f $Year)
    Write-Kv ("{0}-10-15 18:00 UTC" -f $Year)       ('-> ' + (Get-LocalStamp -Tz $tz -Utc $uOct))
    Write-Kv ("{0}-11-15 19:00 UTC" -f $Year)       ('-> ' + (Get-LocalStamp -Tz $tz -Utc $uNov))
    Write-Kv ("{0}-12-15 19:00 UTC" -f $Year)       ('-> ' + (Get-LocalStamp -Tz $tz -Utc $uDec))
    Write-Kv ("{0}-01-15 19:00 UTC" -f ($Year + 1)) ('-> ' + (Get-LocalStamp -Tz $tz -Utc $uJan))

    if ($oNov -eq $oOct) {
        $verdict = 'NO-FALLBACK'
        $verdictText = "no autumn clock change in $Year - stays on $novOffset through November"
    } else {
        $verdict = 'FALLBACK'
        $verdictText = ("clocks still move {0:+#;-#;0}min that autumn - November sits at {1}" -f (($oNov - $oOct) / 60), $novOffset)
    }

    Invoke-RuntimeChecks -ZoneId $tz.Id -Year $Year
}

Write-Head 'Verdict'
switch ($verdict) {
    'NO-FALLBACK' { Write-Host ('  [NO-FALLBACK] ' + $verdictText) -ForegroundColor Green }
    'FALLBACK'    {
        Write-Host ('  [FALLBACK]    ' + $verdictText) -ForegroundColor Yellow
        Write-Host '  Correct for a zone that still observes DST. If you expected no change, this' -ForegroundColor DarkGray
        if ($script:IsWindowsHost) {
            Write-Host '  host tz data is behind: Windows zone data ships with the cumulative update.' -ForegroundColor DarkGray
        } else {
            Write-Host '  host tz data is behind (America/Edmonton: IANA 2026b = old, 2026c = new).' -ForegroundColor DarkGray
        }
    }
    default       { Write-Host ('  [' + $verdict + '] ' + $verdictText) -ForegroundColor Red }
}

if ($EmitResult) {
    $tzver = ($tzdata.Version -replace '\s+', ' ')
    Write-Output ('TZCHECK-RESULT|{0}|{1}|{2}|{3}|{4}|{5}' -f `
        [System.Environment]::MachineName, $tzver, $Zone, $Year, $verdict, $novOffset)
}

if ($verdict -eq 'NO-ZONE' -or $verdict -eq 'ERROR') { exit 2 }
if ($ExpectNoFallback -and $verdict -ne 'NO-FALLBACK') { exit 1 }
exit 0
