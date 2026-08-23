<#
  ターミナル起動時に呼ばれる軽量チェック。
  Dropbox 側の設定がこのPCより新しければ一行だけ警告する。
  小さな JSON を2つ読むだけなので、シェルの起動を遅くしない。
  何が起きても例外は投げない（プロファイルを壊さないため）。
#>
Set-StrictMode -Version Latest

try {
    $toolkitRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
    . (Join-Path $toolkitRoot 'lib\Common.ps1')

    $config = Read-JsonFile (Get-ConfigPath)
    if ($null -eq $config) { return }
    $syncRoot = Get-Prop $config 'syncRoot'
    if (-not $syncRoot -or -not (Test-Path -LiteralPath $syncRoot)) { return }

    $meta  = Read-Meta $syncRoot
    $state = Read-State

    if ([int]$meta.revision -gt [int]$state.lastSeenRevision) {
        Write-Host ''
        Write-Host "  [claude-sync] Dropbox 側に新しい Claude Code 設定があります (rev.$($meta.revision) / $($meta.machine))。" -ForegroundColor Yellow
        Write-Host "                取り込むには:  claude-sync pull" -ForegroundColor Yellow
        Write-Host ''
    }
} catch {
    # 起動時チェックの失敗で作業を止めない
}
