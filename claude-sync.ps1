<#
.SYNOPSIS
  Claude Code の設定一式を Dropbox 経由で複数の Windows PC 間で同期する。

.DESCRIPTION
  ~/.claude 配下のうち sync-manifest.json で指定した項目だけを、
  Dropbox 内の同期フォルダとの間でコピーする。
  認証情報 (.credentials.json) と会話履歴 (projects/) は同期しない。

.PARAMETER Command
  push   : このPCの設定を Dropbox へ送る（作業を終えるとき）
  pull   : Dropbox の設定をこのPCへ取り込む（作業を始めるとき）
  status : いまどちらが新しいかを確認するだけ（何も変更しない）

.EXAMPLE
  .\claude-sync.ps1 status
  .\claude-sync.ps1 pull
  .\claude-sync.ps1 push -DryRun
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('push', 'pull', 'status')]
    [string]$Command = 'status',

    # 実際にはコピーせず、何が起きるかだけ表示する
    [switch]$DryRun,

    # 確認・競合チェックを飛ばして強行する
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ToolkitRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
. (Join-Path $ToolkitRoot 'lib\Common.ps1')

# ---------------------------------------------------------------- 準備

$config     = Get-SyncConfig
$manifest   = Get-Manifest $ToolkitRoot
$claudeHome = Get-ClaudeHome
$syncRoot   = $config.syncRoot
$dataRoot   = Get-DataRoot $syncRoot
$pairs      = Get-ItemPairs -Manifest $manifest -ClaudeHome $claudeHome -DataRoot $dataRoot

$meta  = Read-Meta $syncRoot
$state = Read-State

if ($DryRun) { Write-Host "`n[ドライラン] 実際のコピーは行いません。" -ForegroundColor Magenta }

# ---------------------------------------------------------------- status

function Show-Status {
    Write-Head '同期の状態'
    Write-Info "このPC            : $env:COMPUTERNAME"
    Write-Info "ローカル設定       : $claudeHome"
    Write-Info "Dropbox 同期フォルダ: $syncRoot"

    if ($meta.revision -eq 0) {
        Write-Warn 'Dropbox 側にはまだ設定が入っていません。最初のPCで push を実行してください。'
    } else {
        Write-Info "Dropbox 側の版     : rev.$($meta.revision)  ($($meta.machine) が $($meta.pushedAt) に push)"
        Write-Info "このPCが見た版     : rev.$($state.lastSeenRevision)  ($($state.lastAction) $($state.lastSyncAt))"
    }

    Write-Head '対象ごとの差分'
    $diff = Compare-Tree -Pairs $pairs -Manifest $manifest

    if (-not $diff.HasDiff) {
        Write-Ok '差分なし。両者は一致しています。'
    } else {
        foreach ($d in $diff.Differs)   { Write-Host "  変更 $($d.Path)  [$($d.Newer)]" -ForegroundColor Yellow }
        foreach ($p in $diff.OnlyLocal) { Write-Host "  追加 $p  [このPCにのみ存在]" -ForegroundColor Yellow }
        foreach ($p in $diff.OnlyRemote){ Write-Host "  追加 $p  [Dropbox にのみ存在]" -ForegroundColor Yellow }
    }

    Write-Head 'おすすめの操作'
    if ($meta.revision -gt $state.lastSeenRevision) {
        Write-Host '  別のPCが新しい設定を push しています。まず pull してください:' -ForegroundColor Yellow
        Write-Host '      claude-sync pull' -ForegroundColor White
    } elseif ($diff.HasDiff) {
        Write-Host '  このPCの変更が未送信です。push してください:' -ForegroundColor Yellow
        Write-Host '      claude-sync push' -ForegroundColor White
    } else {
        Write-Ok '何もする必要はありません。'
    }
    Write-Host ''
    return $diff
}

# ---------------------------------------------------------------- push

function Invoke-Push {
    Write-Head 'このPCの設定を Dropbox へ送ります (push)'

    # 1. 競合チェック: 自分が最後に見た版より Dropbox 側が進んでいたら止める
    if ($meta.revision -gt $state.lastSeenRevision -and -not $Force) {
        Write-Warn "別のPC ($($meta.machine)) が rev.$($meta.revision) を push しています。"
        Write-Warn "このPCが最後に同期したのは rev.$($state.lastSeenRevision) です。"
        Write-Host ''
        Write-Host '  そのまま push すると相手の変更を消してしまいます。' -ForegroundColor Red
        Write-Host '  先に claude-sync pull を実行するか、消えて構わない場合のみ -Force を付けてください。' -ForegroundColor Red
        Write-Host ''
        throw '競合のため中断しました。'
    }

    # 2. 機密スキャン: APIキーらしき文字列を Dropbox に上げてしまうのを防ぐ
    Write-Info '機密情報スキャン中...'
    $filesToPush = @()
    foreach ($pair in $pairs) {
        $filesToPush += Get-TrackedFiles -Root $pair.Local -Manifest $manifest -Type $pair.Type
    }
    $hits = Find-Secrets -Files $filesToPush -Manifest $manifest
    if ($hits.Count -gt 0) {
        Write-Host ''
        Write-Warn "APIキー等の可能性がある文字列を $($hits.Count) 件のファイルで検出しました:"
        foreach ($h in $hits) { Write-Host "    $($h.File)" -ForegroundColor Red }
        Write-Host ''
        Write-Host '  Dropbox に上げる前に、該当箇所を settings.local.json や環境変数へ移してください。' -ForegroundColor Red
        Write-Host '  誤検知だと確認できている場合のみ -Force を付けてください。' -ForegroundColor Red
        Write-Host ''
        if (-not $Force) { throw '機密情報の疑いがあるため中断しました。' }
        Write-Warn '-Force が指定されたため、検出を無視して続行します。'
    } else {
        Write-Ok '機密情報は検出されませんでした。'
    }

    # 3. コピー
    if (-not $DryRun -and -not (Test-Path -LiteralPath $dataRoot)) {
        New-Item -ItemType Directory -Path $dataRoot -Force | Out-Null
    }

    $changed = @()
    foreach ($pair in $pairs) {
        if (-not (Test-Path -LiteralPath $pair.Local)) {
            Write-Info "$($pair.Rel) — このPCには無いのでスキップ"
            continue
        }
        $didChange = if ($pair.Type -eq 'dir') {
            Invoke-Mirror -Source $pair.Local -Destination $pair.Remote -Manifest $manifest -DryRun:$DryRun
        } else {
            Copy-SingleFile -Source $pair.Local -Destination $pair.Remote -DryRun:$DryRun
        }
        if ($didChange) { $changed += $pair.Rel; Write-Ok "$($pair.Rel) を送信" }
        else            { Write-Info "$($pair.Rel) — 変更なし" }
    }

    if ($DryRun) {
        Write-Host "`n[ドライラン] ここまでの内容で push されます。実行するには -DryRun を外してください。`n" -ForegroundColor Magenta
        return
    }

    # 4. 版数を進めて記録
    $newRevision = [int]$meta.revision + 1
    Write-Meta -SyncRoot $syncRoot -Revision $newRevision -Items @($pairs | ForEach-Object { $_.Rel }) | Out-Null
    Write-State -Revision $newRevision -Action 'push' | Out-Null

    Write-Host ''
    Write-Ok "push 完了 (rev.$newRevision)。変更 $($changed.Count) 項目。"
    Write-Info 'Dropbox のアイコンが同期完了（緑チェック）になってから、別PCで pull してください。'
    Write-Host ''
}

# ---------------------------------------------------------------- pull

function Invoke-Pull {
    Write-Head 'Dropbox の設定をこのPCへ取り込みます (pull)'

    if ($meta.revision -eq 0) {
        throw "Dropbox 側にまだ設定がありません。先にメインのPCで claude-sync push を実行してください。"
    }

    # 1. ローカルにだけある変更を潰さないか確認する
    $diff = Compare-Tree -Pairs $pairs -Manifest $manifest
    $localOnly = @($diff.OnlyLocal) + @($diff.Differs | Where-Object { $_.Newer -eq 'ローカルが新しい' } | ForEach-Object { $_.Path })

    if ($localOnly.Count -gt 0 -and -not $Force) {
        Write-Warn "このPCにしか無い（またはこのPCの方が新しい）ファイルが $($localOnly.Count) 件あります:"
        foreach ($p in @($localOnly | Select-Object -First 20)) { Write-Host "    $p" -ForegroundColor Yellow }
        if ($localOnly.Count -gt 20) { Write-Info "    ... 他 $($localOnly.Count - 20) 件" }
        Write-Host ''
        Write-Info 'pull すると、これらは Dropbox の内容で上書き・削除されます。'
        Write-Info '（直前のバックアップは自動で取得されるので後から復元できます）'
        Write-Host ''
        $answer = Read-Host '続行しますか？ [y/N]'
        if ($answer -notmatch '^(y|Y)') { throw '中止しました。このPCの変更を残したい場合は先に claude-sync push を実行してください。' }
    }

    # 2. バックアップ
    if (-not $DryRun) {
        $backup = New-SyncBackup -Pairs $pairs
        if ($backup) { Write-Ok "現在の設定をバックアップしました: $backup" }
    }

    # 3. コピー
    $changed = @()
    foreach ($pair in $pairs) {
        if (-not (Test-Path -LiteralPath $pair.Remote)) {
            Write-Info "$($pair.Rel) — Dropbox 側に無いのでスキップ"
            continue
        }
        $didChange = if ($pair.Type -eq 'dir') {
            Invoke-Mirror -Source $pair.Remote -Destination $pair.Local -Manifest $manifest -DryRun:$DryRun
        } else {
            Copy-SingleFile -Source $pair.Remote -Destination $pair.Local -DryRun:$DryRun
        }
        if ($didChange) { $changed += $pair.Rel; Write-Ok "$($pair.Rel) を取り込み" }
        else            { Write-Info "$($pair.Rel) — 変更なし" }
    }

    if ($DryRun) {
        Write-Host "`n[ドライラン] ここまでの内容で pull されます。実行するには -DryRun を外してください。`n" -ForegroundColor Magenta
        return
    }

    Write-State -Revision ([int]$meta.revision) -Action 'pull' | Out-Null

    Write-Host ''
    Write-Ok "pull 完了 (rev.$($meta.revision))。変更 $($changed.Count) 項目。"
    Write-Info '起動中の Claude Code があれば、設定を読み直すため再起動してください。'
    Write-Host ''
}

# ---------------------------------------------------------------- 実行

switch ($Command) {
    'status' { Show-Status | Out-Null }
    'push'   { Invoke-Push }
    'pull'   { Invoke-Pull }
}
