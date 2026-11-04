@echo off
setlocal
set "NK_SELF=%~f0"
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -Command "$t=[IO.File]::ReadAllText($env:NK_SELF,[Text.Encoding]::UTF8);$i=$t.IndexOf('#'+'PS_BEGIN',[StringComparison]::Ordinal);& ([scriptblock]::Create($t.Substring($i)))"
echo.
pause
exit /b
#PS_BEGIN
# =====================================================================
#  니케(NIKKE) PC 런처 감염 검사 - 읽기 전용
#   * 파일과 레지스트리를 "읽기만" 합니다. 아무것도 지우거나 바꾸지 않습니다.
#   * 인터넷에 접속하지 않습니다.
#   * 판정 기준: MotherSphere 공개 분석 (2026-11-04 기준)
#     https://gist.github.com/MotherSphere/d6c049a09ba8ac3085c51ee9df24a4e5
#  메모장으로 열어서 내용을 직접 확인할 수 있습니다.
# =====================================================================
$ErrorActionPreference = 'SilentlyContinue'
try { $Host.UI.RawUI.WindowTitle = 'NIKKE 런처 감염 검사 (읽기 전용)' } catch {}

function Say([string]$Text = '', [string]$Color = 'Gray') { Write-Host $Text -ForegroundColor $Color }

$Infected  = New-Object 'System.Collections.Generic.List[string]'
$Suspect   = New-Object 'System.Collections.Generic.List[string]'
$Checked   = New-Object 'System.Collections.Generic.List[string]'
$LogFiles  = @{}
$NikkeSeen = $false
$MaxBytes  = 52428800   # 50MB 넘는 파일은 건너뜀
$Share     = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete

# ---------------------------------------------------------------------
#  도우미 함수
# ---------------------------------------------------------------------
function Read-Shared([string]$Path) {
    # 다른 프로그램이 쓰고 있는 파일도 읽기 전용으로 엽니다
    $fs = $null
    try {
        $fs = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, $Share)
        [int]$len = [Math]::Min([long]$fs.Length, [long]$MaxBytes)
        $buf = New-Object byte[] $len
        $read = 0
        while ($read -lt $len) {
            $n = $fs.Read($buf, $read, $len - $read)
            if ($n -le 0) { break }
            $read += $n
        }
        if ($read -lt $len) {
            $tmp = New-Object byte[] $read
            [Array]::Copy($buf, $tmp, $read)
            $buf = $tmp
        }
        return ,$buf
    } catch {
        return ,(New-Object byte[] 0)
    } finally {
        if ($fs) { $fs.Close() }
    }
}

function Test-FileHas([string]$Path, [string[]]$Needles) {
    # 일반 문자열(ASCII)과 UTF-16 문자열 양쪽으로 찾습니다
    $b = Read-Shared $Path
    if ($null -eq $b -or $b.Length -eq 0) { return $false }
    $texts = @(
        [Text.Encoding]::GetEncoding(28591).GetString($b),
        [Text.Encoding]::Unicode.GetString($b)
    )
    if ($b.Length -gt 2) { $texts += [Text.Encoding]::Unicode.GetString($b, 1, $b.Length - 1) }
    foreach ($t in $texts) {
        foreach ($nd in $Needles) {
            if ($t.IndexOf($nd, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $true }
        }
    }
    return $false
}

function Get-K2fLines([string]$Path) {
    $hits = New-Object 'System.Collections.Generic.List[string]'
    $fs = $null
    $sr = $null
    try {
        $fs = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, $Share)
        $sr = New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8)
        while ($null -ne ($line = $sr.ReadLine())) {
            if ($line.IndexOf('k2f_chan', [StringComparison]::OrdinalIgnoreCase) -ge 0) { $hits.Add($line) }
        }
    } catch {
    } finally {
        if ($sr) { $sr.Close() } elseif ($fs) { $fs.Close() }
    }
    return ,$hits
}

function Format-LogTime([string]$Line) {
    # 로그 줄 앞의 [MMDD/HHMMSS.mmm ...] 를 "11월 1일 23:02" 형태로
    if ($Line -match '^\[(\d{2})(\d{2})/(\d{2})(\d{2})(\d{2})') {
        return ('{0}월 {1}일 {2}:{3}' -f [int]$Matches[1], [int]$Matches[2], $Matches[3], $Matches[4])
    }
    return '시각 불명'
}

function Test-NikkeDir([string]$Dir) {
    if ([string]::IsNullOrWhiteSpace($Dir)) { return }
    try {
        $log = [IO.Path]::Combine($Dir, 'Launcher', 'intl_service', 'debug.log')
        if ([IO.File]::Exists($log)) {
            $full = [IO.Path]::GetFullPath($log)
            $LogFiles[$full.ToLowerInvariant()] = $full
        }
    } catch {}
}

function Add-InstallDir([string]$Path) {
    # 폴더, 하위 폴더, 실행 파일 위치 어느 것을 받아도 위로 3단계까지 확인
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    $p = $Path.Trim().Trim('"').TrimEnd('\')
    if (-not $p) { return }
    Test-NikkeDir $p
    Test-NikkeDir ([IO.Path]::Combine($p, 'NIKKE'))
    for ($k = 0; $k -lt 3; $k++) {
        try { $p = [IO.Path]::GetDirectoryName($p) } catch { $p = $null }
        if (-not $p) { break }
        Test-NikkeDir $p
    }
}

$shell = $null
try { $shell = New-Object -ComObject WScript.Shell } catch {}

function Add-FromShortcuts([string]$Folder, [bool]$Recurse) {
    if (-not $shell -or [string]::IsNullOrWhiteSpace($Folder) -or -not (Test-Path -LiteralPath $Folder)) { return }
    if ($Recurse) {
        $lnks = @(Get-ChildItem -LiteralPath $Folder -Filter '*.lnk' -File -Recurse -ErrorAction SilentlyContinue)
    } else {
        $lnks = @(Get-ChildItem -LiteralPath $Folder -Filter '*.lnk' -File -ErrorAction SilentlyContinue)
    }
    foreach ($l in $lnks) {
        if ($l.Name -notmatch 'NIKKE|니케|승리의 여신') { continue }
        try {
            $target = $shell.CreateShortcut($l.FullName).TargetPath
            if ($target) { Add-InstallDir ([IO.Path]::GetDirectoryName($target)) }
        } catch {}
    }
}

# ---------------------------------------------------------------------
#  시작
# ---------------------------------------------------------------------
Say '=================================================================' DarkGray
Say '  니케(NIKKE) PC 런처 감염 검사' White
Say '  읽기 전용: 아무것도 지우거나 바꾸지 않고, 인터넷에도 접속하지 않습니다.' DarkGray
Say '  보통 10초~1분 걸립니다. 창을 닫지 말고 기다려 주세요.' DarkGray
Say '=================================================================' DarkGray
Say

# 지금 런처가 켜져 있는지
$running = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
    $_.ProcessName -eq 'nikke_launcher' -or ($_.ProcessName -eq 'tbs_browser' -and "$($_.Path)" -match 'NIKKE')
})

# ---------------------------------------------------------------------
#  1. 설치 위치 찾기
# ---------------------------------------------------------------------
Say '[1/4] 니케 설치 위치 찾는 중...' Cyan

# (가) 실행 중인 런처
foreach ($p in $running) { if ($p.Path) { Add-InstallDir ([IO.Path]::GetDirectoryName($p.Path)) } }

# (나) 프로그램 추가/제거 목록
foreach ($u in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
                 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*')) {
    $entries = @(Get-ItemProperty -Path $u -ErrorAction SilentlyContinue |
                 Where-Object { "$($_.DisplayName) $($_.PSChildName)" -match 'NIKKE|니케' })
    foreach ($e in $entries) {
        Add-InstallDir $e.InstallLocation
        foreach ($s in @($e.DisplayIcon, $e.UninstallString)) {
            if ($s -and ("$s" -match '([A-Za-z]:\\[^"<>|*?]+?\.exe)')) {
                Add-InstallDir ([IO.Path]::GetDirectoryName($Matches[1]))
            }
        }
    }
}

# (다) 바탕화면 / 시작 메뉴 바로가기
Add-FromShortcuts ([Environment]::GetFolderPath('Desktop')) $false
Add-FromShortcuts ([Environment]::GetFolderPath('CommonDesktopDirectory')) $false
Add-FromShortcuts ([Environment]::GetFolderPath('Programs')) $true
Add-FromShortcuts ([Environment]::GetFolderPath('CommonPrograms')) $true

# (라) 모든 로컬 드라이브를 4단계 깊이까지 훑기 (예: D:\NIKKE, C:\Program Files\NIKKE, D:\Games\NIKKE)
$skip = @('Windows', 'Windows.old', '$Recycle.Bin', 'System Volume Information', 'Recovery', 'PerfLogs',
          '$WinREAgent', '$SysReset', 'Config.Msi', 'WinSxS', 'AppData', 'WindowsApps', 'node_modules', '.git',
          'Package Cache', 'Windows Kits', 'Microsoft Visual Studio')
$drives = @([IO.DriveInfo]::GetDrives() | Where-Object {
    $_.IsReady -and ($_.DriveType -eq [IO.DriveType]::Fixed -or $_.DriveType -eq [IO.DriveType]::Removable)
})
foreach ($drv in $drives) {
    $root = $drv.RootDirectory.FullName
    Say ('      {0} 검색 중...' -f $root) DarkGray
    $queue = New-Object 'System.Collections.Generic.Queue[object]'
    $queue.Enqueue(@($root, 0))
    while ($queue.Count -gt 0) {
        $item  = $queue.Dequeue()
        $dir   = [string]$item[0]
        $depth = [int]$item[1]
        Test-NikkeDir $dir
        if ($depth -ge 4) { continue }
        $subs = $null
        try { $subs = [IO.Directory]::GetDirectories($dir) } catch { continue }
        foreach ($s in $subs) {
            $name = [IO.Path]::GetFileName($s)
            if ($skip -contains $name) { continue }
            try {
                if (([IO.File]::GetAttributes($s) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
            } catch { continue }
            $queue.Enqueue(@($s, ($depth + 1)))
        }
    }
}

# (마) 런처를 쓴 기록(AppData)은 있는데 설치 폴더를 못 찾았으면 직접 물어보기
$appDirs = @(Get-ChildItem -LiteralPath $env:APPDATA -Directory -ErrorAction SilentlyContinue |
             Where-Object { $_.Name -like 'nikke_launcher*' })
if ($LogFiles.Count -eq 0 -and $appDirs.Count -gt 0) {
    Say
    Say '  니케 런처를 쓴 기록은 있는데 설치 폴더를 자동으로 찾지 못했습니다.' Yellow
    Say '  다른 곳에 설치했다면 탐색기 주소창의 폴더 경로를 붙여넣고 Enter (예: E:\내게임\NIKKE)' Yellow
    Say '  모르겠거나 니케를 이미 지웠다면 그냥 Enter' Yellow
    $manual = Read-Host '  폴더 경로'
    if ($manual) {
        Add-InstallDir $manual
        if ($LogFiles.Count -eq 0) { Say '  그 경로에서 Launcher\intl_service\debug.log 를 찾지 못했습니다.' Yellow }
    }
}
Say ('      → 런처 로그(debug.log) {0}개 찾음' -f $LogFiles.Count) DarkGray

# ---------------------------------------------------------------------
#  2. debug.log 에서 k2f_chan 찾기 (핵심 판정)
# ---------------------------------------------------------------------
Say '[2/4] 런처 로그에서 k2f_chan 검색 중...' Cyan
foreach ($log in @($LogFiles.Values)) {
    $NikkeSeen = $true
    $launcherDir = Split-Path -Parent (Split-Path -Parent $log)   # ...\NIKKE\Launcher
    $hits = Get-K2fLines $log
    if ($hits.Count -gt 0) {
        $times = @($hits | ForEach-Object { Format-LogTime $_ } | Select-Object -Unique)
        $tt = (@($times | Select-Object -First 5)) -join ', '
        if ($times.Count -gt 5) { $tt += (' 외 {0}번' -f ($times.Count - 5)) }
        $Infected.Add(('debug.log에 k2f_chan {0}건 = 악성코드가 실행됨 (실행 시각, 이 PC 시계 기준: {1})' -f $hits.Count, $tt))
        $Checked.Add(('{0}  →  k2f_chan {1}건' -f $log, $hits.Count))
    } else {
        $Checked.Add(('{0}  →  k2f_chan 없음' -f $log))
    }
    # 악성코드 본체 다운로드 기록
    $tg = Join-Path $launcherDir 'log\tinyget'
    if (Test-Path -LiteralPath $tg) {
        if ([IO.File]::Exists((Join-Path $tg 'k2f.lua'))) { $Infected.Add("악성코드 파일 k2f.lua 남아 있음: $tg") }
        $dl = Get-ChildItem -LiteralPath $tg -File -ErrorAction SilentlyContinue |
              Where-Object { $_.Length -lt $MaxBytes -and (Test-FileHas $_.FullName @('insight.bundle')) } |
              Select-Object -First 1
        if ($dl) { $Infected.Add("악성코드 본체(insight.bundle) 다운로드 기록: $($dl.FullName)") }
    }
}

# ---------------------------------------------------------------------
#  3. 런처 데이터(AppData) - 니케 폴더를 지워도 남는 기록
# ---------------------------------------------------------------------
Say '[3/4] 런처 데이터(AppData) 확인 중...' Cyan
foreach ($ad in $appDirs) {
    $NikkeSeen = $true
    $tbs = Join-Path $ad.FullName 'tbs_cache'

    # 악성코드 에이전트 상태 기록
    $ldb = Join-Path $tbs 'Local Storage\leveldb'
    if (Test-Path -LiteralPath $ldb) {
        $agent = Get-ChildItem -LiteralPath $ldb -File -ErrorAction SilentlyContinue |
                 Where-Object { $_.Length -lt $MaxBytes -and (Test-FileHas $_.FullName @('k2f.agent')) } |
                 Select-Object -First 1
        if ($agent) {
            $Infected.Add("악성코드 에이전트 기록(k2f.agent): $($agent.FullName)")
            $Checked.Add(('{0}  →  k2f.agent 있음' -f $ldb))
        } else {
            $Checked.Add(('{0}  →  k2f.agent 없음' -f $ldb))
        }
    }

    # 변조된 스크립트(로더)가 실행된 흔적
    $loader = $false
    $cc = Join-Path $tbs 'Code Cache\js'
    if (Test-Path -LiteralPath $cc) {
        $x = Get-ChildItem -LiteralPath $cc -File -Recurse -ErrorAction SilentlyContinue |
             Where-Object { $_.Length -lt $MaxBytes -and (Test-FileHas $_.FullName @('insightjs.com/l.js', 'insightjs.org/l.js')) } |
             Select-Object -First 1
        if ($x) { $loader = $true }
    }
    if (-not $loader) {
        foreach ($rel in @('Network Persistent State', 'Network\Network Persistent State',
                           'Default\Network Persistent State', 'Default\Network\Network Persistent State')) {
            $f = Join-Path $tbs $rel
            if ([IO.File]::Exists($f) -and (Test-FileHas $f @('insightjs'))) { $loader = $true; break }
        }
    }
    if ($loader) { $Suspect.Add("변조된 스크립트가 런처에서 실행된 흔적(insightjs 접속 기록): $tbs") }
}

# ---------------------------------------------------------------------
#  4. 크롬 상주 흔적 / 임시 파일
# ---------------------------------------------------------------------
Say '[4/4] 크롬 상주 흔적 확인 중...' Cyan
$clsid = 'HKCU:\Software\Classes\CLSID\{E77CC89B-7401-4C04-8CED-149DB35ADD04}'
if (Test-Path -LiteralPath $clsid) {
    $target = ''
    try { $target = [string](Get-Item -LiteralPath (Join-Path $clsid 'InprocServer32')).GetValue('') } catch {}
    if ($target -match 'PlatformExperienceHelper') {
        $Infected.Add("크롬 상주용 레지스트리 키(HKCU CLSID {E77CC89B...}): $target")
    } else {
        $Suspect.Add("HKCU에 악성코드가 쓰는 CLSID {E77CC89B...} 키가 있음(가리키는 파일: $target) - 확인 필요")
    }
}
$peh = Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data\PlatformExperienceHelper'
if (Test-Path -LiteralPath $peh) {
    foreach ($d in @(Get-ChildItem -LiteralPath $peh -Directory -ErrorAction SilentlyContinue)) {
        if ($d.Name -match '^[0-9a-fA-F]{64}$') {
            $dll = Join-Path $d.FullName 'platform_experience_helper.dll'
            if ([IO.File]::Exists($dll)) { $Infected.Add("크롬에 심어진 악성 DLL: $dll") }
        }
    }
}
$tmpHits = @(Get-ChildItem -LiteralPath $env:TEMP -File -ErrorAction SilentlyContinue |
             Where-Object { $_.Name -like 'k2f-bcreds-*' -or $_.Name -like 'k2f_screen_*' })
if ($tmpHits.Count -gt 0) { $Infected.Add(("임시 폴더에 악성코드 작업 파일 {0}개: {1}" -f $tmpHits.Count, $env:TEMP)) }

if ($running.Count -gt 0) { $NikkeSeen = $true }

# ---------------------------------------------------------------------
#  결과
# ---------------------------------------------------------------------
Say
Say '=================================================================' DarkGray
Say '  확인한 위치' White
if ($Checked.Count -eq 0) { Say '  (니케 런처 로그나 데이터를 찾지 못했습니다)' DarkGray }
foreach ($c in $Checked) { Say "  · $c" DarkGray }
Say '=================================================================' DarkGray
Say

if ($running.Count -gt 0) {
    Say '  !! 지금 니케 런처가 켜져 있습니다. 바로 종료하고(작업 표시줄 오른쪽 트레이 아이콘도) 인터넷을 끊으세요.' Red
    Say
}

if ($Infected.Count -gt 0) {
    Say '  ■ 결과: 감염 - 이 PC에서 악성코드가 실행된 흔적이 있습니다' Red
    Say
    Say '  발견된 흔적' White
    foreach ($i in $Infected) { Say "   - $i" Red }
    foreach ($s in $Suspect)  { Say "   - $s" Yellow }
    Say
    Say '  지금 할 일 (2~4번은 휴대폰 등 "다른 기기"에서 하세요)' White
    Say '   1. 니케 런처를 켜지 말고, 가능하면 이 PC의 인터넷을 끊으세요.' Gray
    Say '   2. 이메일, 디스코드, 은행 등 중요한 계정과 브라우저에 저장해 둔 모든 비밀번호를 바꾸고 2단계 인증을 켜세요.' Gray
    Say '   3. 구글, 디스코드, 스팀 등에서 "모든 기기에서 로그아웃"을 하세요. (쿠키를 훔치면 비밀번호 없이도 로그인됩니다)' Gray
    Say '   4. 암호화폐 지갑이 있다면 새 지갑(새 복구 문구)으로 옮기세요.' Gray
    Say '   5. 가장 안전한 방법은 윈도우 재설치입니다. 백신 검사가 깨끗하게 나와도 안심할 수 없습니다.' Gray
    Say '   6. 이 화면을 캡처해 두세요.' Gray
}
elseif ($Suspect.Count -gt 0) {
    Say '  ■ 결과: 노출 - 악성코드가 실행된 흔적은 없습니다' Yellow
    Say
    foreach ($s in $Suspect) { Say "   - $s" Yellow }
    Say
    Say '  변조된 스크립트는 거쳐 갔지만, 공격자 서버가 악성코드 본체를 보내지 않은 경우로 보입니다.' Gray
    Say '  권장' White
    Say '   1. 공식 발표 전까지 니케 PC 런처를 켜지 마세요.' Gray
    Say ('   2. 다시 쓰기 전에 이 폴더를 지우세요: {0}\nikke_launcher\tbs_cache' -f $env:APPDATA) Gray
    Say '   3. 불안하면 중요한 계정 비밀번호를 바꿔 두세요.' Gray
}
elseif ($NikkeSeen) {
    Say '  ■ 결과: 흔적 없음' Green
    Say
    Say '  니케 런처 기록은 있지만 감염이나 노출 흔적은 발견되지 않았습니다.' Gray
    if ($LogFiles.Count -eq 0) {
        Say '  (단, 니케 설치 폴더를 찾지 못해 debug.log는 확인하지 못했고, 남아 있는 AppData 기록만 확인했습니다.)' Yellow
    }
    Say '  그래도 공식 발표 전까지는 런처를 켜지 말고, 다시 쓰기 전에 아래 폴더를 지우세요.' Gray
    Say ('   {0}\nikke_launcher\tbs_cache' -f $env:APPDATA) Gray
}
else {
    Say '  ■ 결과: 니케 없음' Green
    Say
    Say '  이 PC에서 니케 PC 런처를 설치하거나 사용한 기록을 찾지 못했습니다.' Gray
}

Say
Say '  ※ 2026년 11월 4일까지 공개된 분석의 흔적을 기준으로 한 검사입니다.' DarkGray
Say '    "흔적 없음"이 100% 안전을 보장하지는 않습니다.' DarkGray
Say
