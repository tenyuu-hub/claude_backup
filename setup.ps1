<#
.SYNOPSIS
  claude-sync をこのPCにセットアップする。1台につき1回だけ実行すればよい。

.DESCRIPTION
  やること:
    1. Dropbox のフォルダを自動検出する
    2. Dropbox 内に同期フォルダ (既定: <Dropbox>\claude-sync) を作る
    3. リポジトリから実行した場合、ツール一式を同期フォルダへコピーする
    4. このPC用の設定を %LOCALAPPDATA%\claude-sync\config.json に書く
    5. PowerShell プロファイルに claude-sync コマンドと起動時チェックを登録する

.PARAMETER SyncRoot
  同期フォルダを直接指定する。省略時は <Dropbox>\claude-sync。

.PARAMETER DropboxRoot
  Dropbox フォルダを直接指定する。自動検出に失敗するときに使う。

.PARAMETER SkipProfile
  PowerShell プロファイルを書き換えない。

.PARAMETER Force
  同期フォルダに既にあるツール一式・sync-manifest.json を上書きする。

.EXAMPLE
  # 1台目（リポジトリを clone した場所で実行）
  .\setup.ps1

  # 2台目（Dropbox で同期されてきたフォルダの中で実行）
  cd "$env:USERPROFILE\Dropbox\claude-sync"; .\setup.ps1
#>
[CmdletBinding()]
param(
    [string]$SyncRoot,
    [string]$DropboxRoot,
    [string]$FolderName = 'claude-sync',
    [switch]$SkipProfile,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$SourceRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
. (Join-Path $SourceRoot 'lib\Common.ps1')

Write-Host ''
Write-Host '=====================================================' -ForegroundColor Cyan
Write-Host ' claude-sync セットアップ' -ForegroundColor Cyan
Write-Host ' Claude Code の設定を Dropbox 経由で別PCと共有します' -ForegroundColor Cyan
Write-Host '=====================================================' -ForegroundColor Cyan

# ---------------------------------------------------------------- 1. 同期フォルダの決定

Write-Head '同期フォルダを決めます'

if (-not $SyncRoot) {
    if (-not $DropboxRoot) {
        $DropboxRoot = Find-DropboxRoot
        if (-not $DropboxRoot) {
            Write-Warn 'Dropbox フォルダを自動検出できませんでした。'
            $DropboxRoot = Read-Host '  Dropbox フォルダのパスを入力してください (例: C:\Users\<ユーザー名>\Dropbox)'
        }
        if (-not (Test-Path -LiteralPath $DropboxRoot)) {
            throw "指定された Dropbox フォルダが見つかりません: $DropboxRoot"
        }
    }
    $SyncRoot = Join-Path $DropboxRoot $FolderName
}

Write-Info "同期フォルダ: $SyncRoot"

if (-not (Test-Path -LiteralPath $SyncRoot)) {
    New-Item -ItemType Directory -Path $SyncRoot -Force | Out-Null
    Write-Ok '作成しました。'
} else {
    Write-Ok '既にあります。'
}

# ---------------------------------------------------------------- 2. ツール一式の配置

Write-Head 'ツール一式を配置します'

$sourceResolved = (Resolve-Path -LiteralPath $SourceRoot).Path.TrimEnd('\')
$syncResolved   = (Resolve-Path -LiteralPath $SyncRoot).Path.TrimEnd('\')

if ($sourceResolved -ieq $syncResolved) {
    Write-Ok '同期フォルダの中から実行されています。コピーは不要です。'
} else {
    # 上書きしたくないもの（各PCで編集しうる設定）は既存を優先する
    $preserve = @('sync-manifest.json')
    $toolkitFiles = @(
        'claude-sync.ps1',
        'claude-sync.cmd',
        'check-remote.ps1',
        'setup.ps1',
        'sync-manifest.json',
        'README.md',
        'lib\Common.ps1'
    )

    foreach ($rel in $toolkitFiles) {
        $src = Join-Path $sourceResolved $rel
        if (-not (Test-Path -LiteralPath $src)) { continue }
        $dst = Join-Path $syncResolved $rel

        if ((Test-Path -LiteralPath $dst) -and ($preserve -contains $rel) -and -not $Force) {
            Write-Info "$rel — 既存を維持（上書きするには -Force）"
            continue
        }

        $dstDir = Split-Path -Parent $dst
        if ($dstDir -and -not (Test-Path -LiteralPath $dstDir)) {
            New-Item -ItemType Directory -Path $dstDir -Force | Out-Null
        }
        Copy-Item -LiteralPath $src -Destination $dst -Force
        Write-Ok "$rel を配置"
    }
}

# ---------------------------------------------------------------- 3. このPC用の設定

Write-Head 'このPC用の設定を保存します'

$claudeHome = Get-ClaudeHome
if (-not (Test-Path -LiteralPath $claudeHome)) {
    Write-Warn "Claude Code の設定フォルダが見つかりません: $claudeHome"
    Write-Info 'Claude Code をまだ起動していない場合は、一度起動してから setup.ps1 を実行し直してください。'
    Write-Info '（このまま進めても構いません。pull すればフォルダごと作られます。）'
}

$config = [pscustomobject]@{
    syncRoot    = $syncResolved
    claudeHome  = $claudeHome
    machine     = $env:COMPUTERNAME
    user        = $env:USERNAME
    configuredAt = (Get-Date).ToString('o')
}
Write-JsonFile $config (Get-ConfigPath)
Write-Ok "保存しました: $(Get-ConfigPath)"
Write-Info "Claude Code 設定フォルダ: $claudeHome"

# 環境変数（プロファイルや他ツールから同期フォルダを参照するため）
[Environment]::SetEnvironmentVariable('CLAUDE_SYNC_HOME', $syncResolved, 'User')
$env:CLAUDE_SYNC_HOME = $syncResolved
Write-Ok 'ユーザー環境変数 CLAUDE_SYNC_HOME を設定しました。'

# ---------------------------------------------------------------- 4. PowerShell プロファイル

if (-not $SkipProfile) {
    Write-Head 'PowerShell に claude-sync コマンドを登録します'

    $profilePath = $PROFILE.CurrentUserAllHosts
    $begin = '# >>> claude-sync >>>'
    $end   = '# <<< claude-sync <<<'

    $block = @"
$begin
`$env:CLAUDE_SYNC_HOME = '$syncResolved'
function claude-sync { & (Join-Path `$env:CLAUDE_SYNC_HOME 'claude-sync.ps1') @args }
if (Test-Path (Join-Path `$env:CLAUDE_SYNC_HOME 'check-remote.ps1')) {
    & (Join-Path `$env:CLAUDE_SYNC_HOME 'check-remote.ps1')
}
$end
"@

    $existing = ''
    if (Test-Path -LiteralPath $profilePath) {
        $existing = Get-Content -LiteralPath $profilePath -Raw -Encoding UTF8
    } else {
        $dir = Split-Path -Parent $profilePath
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    }

    if ($existing -match [regex]::Escape($begin)) {
        # 既存ブロックを差し替える
        $pattern = '(?s)' + [regex]::Escape($begin) + '.*?' + [regex]::Escape($end)
        $updated = [regex]::Replace($existing, $pattern, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $block })
        Write-Ok '既存の登録を更新しました。'
    } else {
        $updated = if ($existing.TrimEnd()) { $existing.TrimEnd() + "`r`n`r`n" + $block + "`r`n" } else { $block + "`r`n" }
        Write-Ok '登録しました。'
    }

    [System.IO.File]::WriteAllText($profilePath, $updated, (New-Object System.Text.UTF8Encoding($false)))
    Write-Info "プロファイル: $profilePath"

    $policy = Get-ExecutionPolicy -Scope CurrentUser
    if ($policy -in @('Restricted', 'Undefined', 'AllSigned')) {
        Write-Warn "実行ポリシーが $policy のため、プロファイルが読み込まれない可能性があります。"
        Write-Info '次のコマンドで許可できます（管理者権限は不要）:'
        Write-Host '    Set-ExecutionPolicy -Scope CurrentUser RemoteSigned' -ForegroundColor White
    }
} else {
    Write-Head 'PowerShell プロファイルの書き換えはスキップしました'
    Write-Info "手動で使う場合: & '$syncResolved\claude-sync.ps1' status"
}

# ---------------------------------------------------------------- 5. 次にやること

$meta = Read-Meta $syncResolved

Write-Head 'セットアップ完了'
Write-Host ''
Write-Host '  新しい PowerShell を開いてから、次を実行してください:' -ForegroundColor White
Write-Host ''

if ([int]$meta.revision -eq 0) {
    Write-Host '    claude-sync push      # このPCの設定を Dropbox へ送る（1台目）' -ForegroundColor Green
    Write-Host ''
    Write-Info 'Dropbox 側にはまだ設定がありません。メインで使っているPCから push してください。'
} else {
    Write-Host '    claude-sync status    # まず状態を確認' -ForegroundColor Green
    Write-Host '    claude-sync pull      # Dropbox の設定をこのPCへ取り込む（2台目）' -ForegroundColor Green
    Write-Host ''
    Write-Info "Dropbox 側には rev.$($meta.revision) ($($meta.machine) が push) があります。"
}
Write-Host ''
