---
name: pdf-spread-splitter
description: Split two-page spread PDFs (such as A3/B4 spreads from books, sheet music, or scanned documents) into single-page PDFs (A4/B5). Automatically corrects portrait orientation to landscape (90° CW) initially, splits spreads into left and right halves without quality loss, supports keyword resolution in Inbox (e.g. 'music' -> Inbox/music1.pdf, music2.pdf), detects 2-page duplicate spread scans (e.g. 3,4,3,4) and proposes removal (with --remove-duplicates option), merges sequential files, removes blank pages, verifies page number increment, saves output to <root>/skills/pdf-spread-splitter/<filename>.pdf, and archives original files to Originals/.
---

# PDF Spread Splitter Skill

スキャナーで読み取られた見開きPDF（A3やB4など）を、左右2枚の単一ページ（A4やB5など）に無劣化で高速分割・結合し、原本を安全に退避するスキルです。

---

## 🌟 主な特徴

1. **キーワード指定による Inbox 自動解決**:
   - `music` のように1単語添えるだけで、`Inbox/` 内の `music.pdf`、連番ファイル群（`music1.pdf`, `music2.pdf` 等）、または `music` ディレクトリを自動探索して処理します。
2. **初めの向き自動補正（スプレッド回転先行）**:
   - 縦長（Height > Width）でスキャンされた見開き原稿を検出し、分割前に**スプレッド全体を時計回り90度（90° CW）に回転補正**して横長（Landscape）に正立させます。
   - これにより、左右の分割ページ（A4縦）が確実に正立し、文字や譜面が寝てしまう問題を防ぎます。
3. **見開き重複スキャン（2ページ単位の重複）の検知 & 削除提案**:
   - スキャン時のめくり忘れや二重スキャンによって生じる「3, 4, 3, 4」のような2ページごとの重複（または画像一致）を自動検知します。
   - 勝手に削除せず、「重複している P... の削除を推奨します」と削除提案メッセージを発報します。
   - `--remove-duplicates`（`-d`）オプションを指定することで、重複ページを自動除外してPDFを生成することも可能です。
4. **完全無劣化 & 爆速（Lossless & Fast）**:
   - PDF内のスキャン画像やベクターデータを再圧縮・再ラスタライズせず、CropBox / MediaBox の境界調整によって高速分割します。
   - 解像度や画質の劣化が一切なく、数十ページの見開きであっても数秒程度で書き出せます。
5. **同名連番ファイルの自動連結**:
   - `music1.pdf`, `music2.pdf` や `score_01.pdf`, `score_02.pdf` 等の連番ファイルを自動認識し、順番に結合して `music.pdf` として1冊に出力します。
6. **白紙ページの自動除外**:
   - スキャナのフチ影やノイズ（外周5%）を除外した中央領域のピクセル輝度を判定し、ほぼ真っ白な白紙ページ（白画素率99%以上かつ平均輝度245以上）を出力PDFから自動除外します（`--no-remove-blank` で無効化可能）。
7. **ノンブル（ページ番号）連続性の検証・警告**:
   - ページ最下部（フッター領域）から OCR でページ番号を検出し、インクリメント（+1）しているかを検証。飛び（欠番）や順序逆転を検知した場合は警告を発報します（`--no-verify-pages` で無効化可能）。
8. **開き方向の選択**:
   - **左開き（デフォルト: LTR）**: 楽譜、横書き書籍、洋書など ➔ `左ページ ➔ 右ページ` の順。
   - **右開き（`--rtl`）**: 国語、縦書き小説、漫画など ➔ `右ページ ➔ 左ページ` の順。
9. **整理と原本保全**:
   - 保存先: ルート階層（Inboxなどと並ぶ階層）の `skills/pdf-spread-splitter/<ファイル名またはグループ名>.pdf`（例: `/Volumes/EXTERNAL/Scan/skills/pdf-spread-splitter/music.pdf`）
   - 原本退避: 処理成功後、元ファイルを自動的に `Originals/` ディレクトリへ安全に移動します（`--keep-original` で保持可能）。

---

## 🛠️ コマンド実行方法

```bash
# 1. キーワード指定（Inbox内の music1.pdf, music2.pdf などを自動探索して結合・分割）
python3 scripts/split_spread.py music

# 2. 重複ページを検知時に自動除外したい場合
python3 scripts/split_spread.py music --remove-duplicates

# 3. フォルダ内の全PDFを一括処理（連番は自動結合、原本は Originals/ へ退避）
python3 scripts/split_spread.py /Volumes/EXTERNAL/Scan/Inbox/

# 4. 単一ファイルの分割（同階層に連番があればまとめて結合）
python3 scripts/split_spread.py /Volumes/EXTERNAL/Scan/Inbox/music1.pdf

# 5. テスト時など、元ファイルを移動せず保持する場合
python3 scripts/split_spread.py music --keep-original

# 6. 右開き（縦書き・国語・小説など）の場合
python3 scripts/split_spread.py /path/to/book.pdf --rtl
```

---

## 📂 ディレクトリと保存ルール

- **入力**: 任意のPDFファイルパス、フォルダパス、または `music` などのキーワード
- **出力**:
  - `Inbox/music1.pdf` と `Inbox/music2.pdf` を処理した場合 ➔ `/Volumes/EXTERNAL/Scan/skills/pdf-spread-splitter/music.pdf`
- **原本退避**:
  - `/Volumes/EXTERNAL/Scan/Inbox/music1.pdf` ➔ `/Volumes/EXTERNAL/Scan/Originals/music1.pdf`
  - 同名ファイルが退避先に既に存在する場合は `music1_1.pdf` のように自動連番を付与して安全に保管します。

---

## 🧪 単体テスト実行

```bash
python3 scripts/test_split_spread.py
```
