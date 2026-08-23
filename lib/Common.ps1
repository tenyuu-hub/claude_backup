# claude-sync 共通関数
# 各スクリプトから . (ドットソース) で読み込んで使う。

Set-StrictMode -Version Latest

# ---------------------------------------------------------------- JSON ユーティリティ

function Get-Prop {
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop -or $null -eq $prop.Value) { return $Default }
    return $prop.Value
}

function Read-JsonFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    return $raw | ConvertFrom-Json
}

function Write-JsonFile {
    param($Object, [string]$Path)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $json = $Object | ConvertTo-Json -Depth 10
    # BOM なし UTF-8 で書く（BOM 付きだと他ツールが読めないことがある）
    [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($false)))
}

# ---------------------------------------------------------------- パス解決

function Get-ClaudeHome {
    if ($env:CLAUDE_CONFIG_DIR) { return $env:CLAUDE_CONFIG_DIR }
    return (Join-Path $env:USERPROFILE '.claude')
}

function Get-LocalDataDir {
    # マシン固有の設定と状態の置き場所。Dropbox には入れない。
    return (Join-Path $env:LOCALAPPDATA 'claude-sync')
}

function Get-ConfigPath { return (Join-Path (Get-LocalDataDir) 'config.json') }
function Get-StatePath  { return (Join-Path (Get-LocalDataDir) 'state.json') }
function Get-BackupRoot { return (Join-Path (Get-LocalDataDir) 'backups') }

function Find-DropboxRoot {
    <#
      Dropbox クライアントが置く info.json から実際の同期フォルダを割り出す。
      見つからなければ $null を返す（呼び出し側で手入力を促す）。
    #>
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Dropbox\info.json'),
        (Join-Path $env:APPDATA     'Dropbox\info.json')
    )
    foreach ($c in $candidates) {
        if (-not (Test-Path -LiteralPath $c)) { continue }
        try { $info = Read-JsonFile $c } catch { continue }
        if ($null -eq $info) { continue }
        foreach ($kind in @('personal', 'business')) {
            $entry = Get-Prop $info $kind
            $path  = Get-Prop $entry 'path'
            if ($path -and (Test-Path -LiteralPath $path)) { return $path }
        }
    }
    $fallback = Join-Path $env:USERPROFILE 'Dropbox'
    if (Test-Path -LiteralPath $fallback) { return $fallback }
    return $null
}

function Get-SyncConfig {
    <# setup.ps1 が書いた config.json を読む。無ければ setup を促して終了。 #>
    $path = Get-ConfigPath
    $cfg  = Read-JsonFile $path
    if ($null -eq $cfg -or -not (Get-Prop $cfg 'syncRoot')) {
        throw "このPCはまだセットアップされていません。先に setup.ps1 を実行してください。 (期待した設定ファイル: $path)"
    }
    if (-not (Test-Path -LiteralPath $cfg.syncRoot)) {
        throw "同期フォルダが見つかりません: $($cfg.syncRoot)`nDropbox の同期が完了しているか確認するか、setup.ps1 を再実行してください。"
    }
    return $cfg
}

function Get-DataRoot {
    param([string]$SyncRoot)
    return (Join-Path $SyncRoot 'data')
}

function Get-MetaPath {
    param([string]$SyncRoot)
    return (Join-Path $SyncRoot '.claude-sync-meta.json')
}

function Get-Manifest {
    param([string]$ToolkitRoot)
    $path = Join-Path $ToolkitRoot 'sync-manifest.json'
    $m = Read-JsonFile $path
    if ($null -eq $m) { throw "同期対象の定義ファイルが読めません: $path" }
    return $m
}

# ---------------------------------------------------------------- メタ情報と同期状態

function Read-Meta {
    param([string]$SyncRoot)
    $meta = Read-JsonFile (Get-MetaPath $SyncRoot)
    # 古い版や壊れたファイルでも必ず同じ形で返す（StrictMode 下で参照が落ちないように）
    return [pscustomobject]@{
        revision = [int](Get-Prop $meta 'revision' 0)
        machine  = [string](Get-Prop $meta 'machine' '')
        user     = [string](Get-Prop $meta 'user' '')
        pushedAt = [string](Get-Prop $meta 'pushedAt' '')
        items    = @(Get-Prop $meta 'items' @())
    }
}

function Write-Meta {
    param([string]$SyncRoot, [int]$Revision, [string[]]$Items)
    $meta = [pscustomobject]@{
        revision = $Revision
        machine  = $env:COMPUTERNAME
        user     = $env:USERNAME
        pushedAt = (Get-Date).ToString('o')
        items    = $Items
    }
    Write-JsonFile $meta (Get-MetaPath $SyncRoot)
    return $meta
}

function Read-State {
    $state = Read-JsonFile (Get-StatePath)
    return [pscustomobject]@{
        lastSeenRevision = [int](Get-Prop $state 'lastSeenRevision' 0)
        lastSyncAt       = [string](Get-Prop $state 'lastSyncAt' '')
        lastAction       = [string](Get-Prop $state 'lastAction' '(未同期)')
    }
}

function Write-State {
    param([int]$Revision, [string]$Action)
    $state = [pscustomobject]@{
        lastSeenRevision = $Revision
        lastSyncAt       = (Get-Date).ToString('o')
        lastAction       = $Action
    }
    Write-JsonFile $state (Get-StatePath)
    return $state
}

# ---------------------------------------------------------------- 対象ファイルの列挙

function Get-ItemPair {
    <#
      マニフェストの1項目を、ローカル側とDropbox側の絶対パスの組にして返す。
      plugins/config.json のようにサブフォルダを含むパスも扱える。
    #>
    param($Item, [string]$ClaudeHome, [string]$DataRoot)
    $rel = ($Item.path -replace '/', '\')
    return [pscustomobject]@{
        Rel    = $rel
        Type   = $Item.type
        Desc   = (Get-Prop $Item 'desc' '')
        Local  = (Join-Path $ClaudeHome $rel)
        Remote = (Join-Path $DataRoot  $rel)
    }
}

function Get-ItemPairs {
    param($Manifest, [string]$ClaudeHome, [string]$DataRoot)
    $pairs = @()
    foreach ($item in $Manifest.include) {
        $pairs += (Get-ItemPair -Item $item -ClaudeHome $ClaudeHome -DataRoot $DataRoot)
    }
    return $pairs
}

function Get-TrackedFiles {
    <# 除外ルールを適用した上で、あるパス配下の同期対象ファイルを列挙する。 #>
    param([string]$Root, $Manifest, [string]$Type)

    if (-not (Test-Path -LiteralPath $Root)) { return @() }

    if ($Type -eq 'file') {
        $leaf = Split-Path -Leaf $Root
        if (Test-Excluded -Name $leaf -Manifest $Manifest) { return @() }
        return @(Get-Item -LiteralPath $Root)
    }

    $excludeDirs = @(Get-Prop $Manifest 'excludeDirs' @())
    return @(Get-ChildItem -LiteralPath $Root -Recurse -File -Force -ErrorAction SilentlyContinue | Where-Object {
        $relDir = $_.DirectoryName.Substring($Root.Length).Trim('\')
        $segments = if ($relDir) { $relDir -split '\\' } else { @() }
        $inExcludedDir = $false
        foreach ($seg in $segments) { if ($excludeDirs -contains $seg) { $inExcludedDir = $true; break } }
        (-not $inExcludedDir) -and (-not (Test-Excluded -Name $_.Name -Manifest $Manifest))
    })
}

function Test-Excluded {
    param([string]$Name, $Manifest)
    foreach ($pattern in @(Get-Prop $Manifest 'excludeFiles' @())) {
        if ($Name -like $pattern) { return $true }
    }
    return $false
}

# ---------------------------------------------------------------- 機密スキャン

function Find-Secrets {
    <# push 対象のファイルを走査し、APIキーらしき文字列を含むものを返す。 #>
    param([object[]]$Files, $Manifest)

    $patterns = @(Get-Prop $Manifest 'secretPatterns' @())
    if ($patterns.Count -eq 0) { return @() }
    $extensions = @(Get-Prop $Manifest 'secretScanExtensions' @())
    $maxBytes   = [int](Get-Prop $Manifest 'secretScanMaxBytes' 1048576)

    $hits = @()
    foreach ($file in $Files) {
        if ($file.Length -gt $maxBytes) { continue }
        if ($extensions.Count -gt 0 -and $extensions -notcontains $file.Extension.ToLowerInvariant()) { continue }
        try { $content = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 -ErrorAction Stop }
        catch { continue }
        if ([string]::IsNullOrEmpty($content)) { continue }
        foreach ($pattern in $patterns) {
            if ($content -match $pattern) {
                $hits += [pscustomobject]@{ File = $file.FullName; Pattern = $pattern }
                break
            }
        }
    }
    return $hits
}

# ---------------------------------------------------------------- コピー

function Invoke-Mirror {
    <#
      robocopy でフォルダを丸ごと同期する（コピー先の余分なファイルは削除される）。
      robocopy の終了コードは 0-7 が正常、8 以上が失敗。
    #>
    param(
        [string]$Source,
        [string]$Destination,
        $Manifest,
        [switch]$DryRun
    )

    $roboArgs = @($Source, $Destination, '/MIR', '/NJH', '/NJS', '/NP', '/NDL', '/NFL', '/R:2', '/W:2')
    if ($DryRun) { $roboArgs += '/L' }

    $excludeFiles = @(Get-Prop $Manifest 'excludeFiles' @())
    if ($excludeFiles.Count -gt 0) { $roboArgs += '/XF'; $roboArgs += $excludeFiles }
    $excludeDirs = @(Get-Prop $Manifest 'excludeDirs' @())
    if ($excludeDirs.Count -gt 0) { $roboArgs += '/XD'; $roboArgs += $excludeDirs }

    $output = & robocopy @roboArgs 2>&1
    $code = $LASTEXITCODE
    if ($code -ge 8) {
        throw "コピーに失敗しました (robocopy 終了コード $code)`n  $Source -> $Destination`n$($output -join "`n")"
    }
    # 終了コード 1 以上 = 何かしらコピー・削除が発生した
    return ($code -ge 1)
}

function Copy-SingleFile {
    param([string]$Source, [string]$Destination, [switch]$DryRun)

    if (-not (Test-Path -LiteralPath $Source)) { return $false }

    if (Test-Path -LiteralPath $Destination) {
        $src = Get-Item -LiteralPath $Source
        $dst = Get-Item -LiteralPath $Destination
        # 秒単位で比較（Dropbox がタイムスタンプを丸めることがあるため）
        $sameTime = [math]::Abs(($src.LastWriteTimeUtc - $dst.LastWriteTimeUtc).TotalSeconds) -lt 2
        if ($sameTime -and $src.Length -eq $dst.Length) { return $false }
    }

    if (-not $DryRun) {
        $dir = Split-Path -Parent $Destination
        if ($dir -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        Copy-Item -LiteralPath $Source -Destination $Destination -Force
    }
    return $true
}

# ---------------------------------------------------------------- バックアップ

function New-SyncBackup {
    <# pull で上書きする前に、いまローカルにある同期対象を退避する。 #>
    param([object[]]$Pairs, [int]$Keep = 10)

    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $dest  = Join-Path (Get-BackupRoot) $stamp
    $saved = 0

    foreach ($pair in $Pairs) {
        if (-not (Test-Path -LiteralPath $pair.Local)) { continue }
        $target = Join-Path $dest $pair.Rel
        $parent = Split-Path -Parent $target
        if ($parent -and -not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        Copy-Item -LiteralPath $pair.Local -Destination $target -Recurse -Force
        $saved++
    }

    if ($saved -eq 0) {
        if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
        return $null
    }

    # 古いバックアップを間引く
    $all = @(Get-ChildItem -LiteralPath (Get-BackupRoot) -Directory -ErrorAction SilentlyContinue |
             Sort-Object Name -Descending)
    if ($all.Count -gt $Keep) {
        foreach ($old in $all[$Keep..($all.Count - 1)]) {
            Remove-Item -LiteralPath $old.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    return $dest
}

# ---------------------------------------------------------------- 差分比較

function Compare-Tree {
    <# ローカル側とDropbox側の同期対象を突き合わせ、差分の件数と一覧を返す。 #>
    param([object[]]$Pairs, $Manifest)

    $onlyLocal = @(); $onlyRemote = @(); $differs = @()

    foreach ($pair in $Pairs) {
        $localFiles  = @{}
        $remoteFiles = @{}
        foreach ($f in Get-TrackedFiles -Root $pair.Local  -Manifest $Manifest -Type $pair.Type) {
            $key = if ($pair.Type -eq 'file') { $pair.Rel } else { Join-Path $pair.Rel $f.FullName.Substring($pair.Local.Length).Trim('\') }
            $localFiles[$key] = $f
        }
        foreach ($f in Get-TrackedFiles -Root $pair.Remote -Manifest $Manifest -Type $pair.Type) {
            $key = if ($pair.Type -eq 'file') { $pair.Rel } else { Join-Path $pair.Rel $f.FullName.Substring($pair.Remote.Length).Trim('\') }
            $remoteFiles[$key] = $f
        }

        foreach ($key in $localFiles.Keys) {
            if (-not $remoteFiles.ContainsKey($key)) { $onlyLocal += $key; continue }
            $l = $localFiles[$key]; $r = $remoteFiles[$key]
            $sameTime = [math]::Abs(($l.LastWriteTimeUtc - $r.LastWriteTimeUtc).TotalSeconds) -lt 2
            if (-not ($sameTime -and $l.Length -eq $r.Length)) {
                $newer = if ($l.LastWriteTimeUtc -gt $r.LastWriteTimeUtc) { 'ローカルが新しい' } else { 'Dropboxが新しい' }
                $differs += [pscustomobject]@{ Path = $key; Newer = $newer }
            }
        }
        foreach ($key in $remoteFiles.Keys) {
            if (-not $localFiles.ContainsKey($key)) { $onlyRemote += $key }
        }
    }

    return [pscustomobject]@{
        OnlyLocal  = $onlyLocal
        OnlyRemote = $onlyRemote
        Differs    = $differs
        HasDiff    = (($onlyLocal.Count + $onlyRemote.Count + $differs.Count) -gt 0)
    }
}

# ---------------------------------------------------------------- 表示

function Write-Head { param([string]$Text) Write-Host "`n== $Text" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Text) Write-Host "  OK   $Text" -ForegroundColor Green }
function Write-Warn { param([string]$Text) Write-Host "  警告 $Text" -ForegroundColor Yellow }
function Write-Info { param([string]$Text) Write-Host "       $Text" -ForegroundColor DarkGray }
