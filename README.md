# claude-sync — Claude Code の設定を Dropbox 経由で別PCと共有する

メインPCで育てた Claude Code の設定（`CLAUDE.md`・スキル・スラッシュコマンド・サブエージェント）を、
Dropbox を通じてもう1台の Windows PC でもそのまま使えるようにするツールです。

```
   PC-A                    Dropbox                     PC-B
 ~/.claude/  ── push ──▶  claude-sync/data/  ── pull ──▶  ~/.claude/
                              rev.7
```

**認証情報と会話履歴は同期しません。** 設定・カスタマイズだけを運びます。


## 同期するもの / しないもの

| 対象 | 同期 | 理由 |
|---|:--:|---|
| `CLAUDE.md` | ✅ | 全プロジェクト共通の指示 |
| `settings.json` | ✅ | 権限・フック・モデル設定 |
| `skills/` | ✅ | 自作スキル |
| `commands/` | ✅ | スラッシュコマンド |
| `agents/` | ✅ | サブエージェント定義 |
| `output-styles/` | ✅ | 出力スタイル |
| `keybindings.json` | ✅ | キーバインド |
| `plugins/config.json` | ✅ | プラグイン設定 |
| `.credentials.json` | ❌ | **ログイン情報。クラウドに置いてはいけない** |
| `projects/`・`history.jsonl` | ❌ | 会話履歴。容量が大きく、競合の原因になる |
| `settings.local.json` | ❌ | そのPC専用の設定として使う場所 |
| `~/.claude.json` | ❌ | プロジェクト履歴と認証トークンが混在している |
| `shell-snapshots/`・`todos/`・`statsig/` | ❌ | 一時ファイル |

同期対象は `sync-manifest.json` を編集すれば変えられます。

**各PCで最初に一度 `claude` を起動してログインしてください。** ログイン状態は同期されません。


## セットアップ

### 1台目（メインPC — 設定が入っている方）

```powershell
git clone https://github.com/tenyuu-hub/claude_backup.git
cd claude_backup
.\setup.ps1
```

`setup.ps1` は Dropbox フォルダを自動検出し、`<Dropbox>\claude-sync\` にツール一式を配置して、
PowerShell に `claude-sync` コマンドを登録します。

**新しい PowerShell を開いてから**、設定を送ります:

```powershell
claude-sync push
```

Dropbox のアイコンが緑チェック（同期完了）になるまで待ちます。

### 2台目

Dropbox で `claude-sync` フォルダが降ってきたら、その中で setup を実行します:

```powershell
cd "$env:USERPROFILE\Dropbox\claude-sync"
.\setup.ps1
```

新しい PowerShell を開いて、取り込みます:

```powershell
claude-sync pull
```

これで2台目でも同じ Claude Code 環境になります。

> `setup.ps1` が動かない場合は実行ポリシーを緩めてください（管理者権限は不要）:
> `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`


## 日々の使い方

覚えるのは2つだけです。

| タイミング | コマンド |
|---|---|
| そのPCでの作業を**終える**とき | `claude-sync push` |
| そのPCでの作業を**始める**とき | `claude-sync pull` |

pull を忘れても大丈夫です。PowerShell を開いたときに、Dropbox 側が新しければ自動で知らせます:

```
  [claude-sync] Dropbox 側に新しい Claude Code 設定があります (rev.8 / DESKTOP-A)。
                取り込むには:  claude-sync pull
```

### コマンド一覧

```powershell
claude-sync status          # どちらが新しいか、どのファイルが違うかを表示（変更しない）
claude-sync pull            # Dropbox → このPC
claude-sync push            # このPC → Dropbox
claude-sync push -DryRun    # 何が起きるかだけ確認する
claude-sync pull -Force     # 確認プロンプトを飛ばす
```


## 競合したとき

両方のPCで設定をいじってしまった場合、`push` が止まります:

```
  警告 別のPC (DESKTOP-B) が rev.9 を push しています。
  警告 このPCが最後に同期したのは rev.7 です。
```

こうなったら:

1. `claude-sync status` でどのファイルが食い違っているか確認する
2. 相手の変更を採用するなら `claude-sync pull`
3. こちらの変更を採用するなら `claude-sync push -Force`
4. **両方の変更を残したい**なら、先に自分の変更ファイルを別名でコピーしてから `pull` し、手で統合してから `push`

`pull` は上書きする前に必ずバックアップを取ります（直近10世代）:

```
%LOCALAPPDATA%\claude-sync\backups\20260823-181500\
```

元に戻したいときは、このフォルダから `%USERPROFILE%\.claude\` へコピーし直してください。


## 安全策

- **機密スキャン** — `push` の前に、API キーらしき文字列（`sk-ant-...`、`ghp_...`、AWS キー、秘密鍵など）を
  探します。見つかると push は中断します。該当箇所は `settings.local.json` か環境変数へ移してください。
  誤検知だと確認できたときだけ `-Force` を使います。
- **除外リスト** — `.credentials.json` や `*.key` は、たとえ同期対象フォルダの中にあってもコピーされません。
- **バックアップ** — `pull` は上書き前に必ず退避します。

Dropbox はクラウド上のサービスです。`CLAUDE.md` やスキルに顧客名・パスワード・社外秘を書いている場合は、
同期対象に入れる前に内容を確認してください。


## カスタマイズ

同期する項目を変えるには `<Dropbox>\claude-sync\sync-manifest.json` を編集します。

```jsonc
{
  "include": [
    { "path": "CLAUDE.md", "type": "file" },
    { "path": "skills",    "type": "dir"  }
  ],
  "excludeFiles": [ ".credentials.json", "*.key" ]
}
```

編集したら両方のPCで同じ内容にしてください（`sync-manifest.json` 自体は同期対象外です）。

会話履歴（`projects/`）も運びたくなったら `include` に
`{ "path": "projects", "type": "dir" }` を足せますが、容量が大きく競合しやすいので推奨しません。


## トラブルシューティング

**`claude-sync` が見つからない**
新しい PowerShell を開き直してください。それでも駄目なら実行ポリシーを確認します:
`Get-ExecutionPolicy -Scope CurrentUser` → `Restricted` なら `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`

**「同期フォルダが見つかりません」**
Dropbox の同期が完了していません。タスクトレイの Dropbox アイコンを確認してください。
Dropbox のパスが変わった場合は `setup.ps1 -DropboxRoot "D:\Dropbox"` で再実行します。

**pull したのに Claude Code に反映されない**
起動中の Claude Code を再起動してください。設定は起動時に読み込まれます。

**Dropbox に「競合コピー」ファイルができた**
両方のPCが同時に push した可能性があります。`claude-sync status` で差分を確認し、
不要な `(... の競合コピー ...)` ファイルは削除してから push し直してください。

**別PCでログインを求められる**
正常です。認証情報は同期していません。`claude` を起動して各PCで一度ログインしてください。


## 制限

- Windows 専用です（`robocopy` と PowerShell に依存しています）。Mac/Linux では動きません。
- リアルタイム同期ではありません。`push` / `pull` は手動で実行します。
- 2台同時に Claude Code で設定を編集すると競合します。rev 番号で検出しますが、統合は手作業です。
- MCP サーバーの設定（`~/.claude.json`）は認証トークンを含むため同期しません。各PCで
  `claude mcp add` を実行してください。プロジェクト単位の `.mcp.json` は、そのプロジェクトの
  Git リポジトリで管理するのが確実です。


## ファイル構成

```
claude-sync/
├── setup.ps1              各PCで1回だけ実行するセットアップ
├── claude-sync.ps1        push / pull / status の本体
├── claude-sync.cmd        cmd.exe から呼ぶためのラッパー
├── check-remote.ps1       ターミナル起動時の更新チェック
├── sync-manifest.json     同期対象・除外・機密パターンの定義
├── lib/Common.ps1         共通関数
└── data/                  同期される設定の実体（Dropbox 上にのみ存在）
```

このPCだけの設定（Dropbox のパスなど）は `%LOCALAPPDATA%\claude-sync\` に置かれ、同期されません。
