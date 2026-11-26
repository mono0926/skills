#!/usr/bin/env python3
"""
pdf-spread-splitter: 見開きPDFを左右の2ページ（A4等）に分割するCLIツール。
- 縦長（Portrait）の見開きPDFを自動で横長（Landscape）に回転補正（90° CW）
- 左右中央で分割し、完全無劣化でA4等の単一ページPDFを生成
- 同名連番ファイル（例: music1.pdf, music2.pdf）の自動連結（music.pdf を生成）
- 白紙ページの自動検出・除外（フチ影を除外した中央領域の輝度判定）
- ページ下部のノンブル（ページ番号）検出と連続性（インクリメント）の検証・警告
- 出力先: <親ディレクトリ>/pdf-spread-splitter/<元ファイル名またはグループ名>.pdf
- 原本退避: 処理成功後に元ファイルを Originals/ へ移動（--keep-original で無効化）
"""

import argparse
import os
import re
import shutil
import subprocess
import sys
import time
import uuid
from dataclasses import dataclass
from pathlib import Path
from PIL import Image, ImageChops, ImageStat
import numpy as np
from pypdf import PdfReader, PdfWriter


TMP_DIR = Path.home() / ".agents" / "tmp"


def ensure_tmp_dir() -> Path:
    TMP_DIR.mkdir(parents=True, exist_ok=True)
    return TMP_DIR


def find_inbox_dirs() -> list[Path]:
    """Inbox の候補ディレクトリ一覧を返す"""
    candidates = [
        Path("/Volumes/EXTERNAL/Scan/Inbox"),
        Path.cwd() / "Inbox",
        Path.cwd().parent / "Inbox",
        Path.home() / "Scan" / "Inbox",
    ]
    return [p for p in candidates if p.exists() and p.is_dir()]


def resolve_target_path(target_input: str) -> Path:
    """
    指定された引数（フルパス、ファイル名、または 'music' のようなキーワード）から処理対象パスを解決する。
    1. 直接存在するパスならそれを返す。
    2. 存在しない場合、Inbox 候補ディレクトリ内を探索：
       - <keyword> ディレクトリ
       - <keyword>.pdf
       - <keyword>*.pdf (連番ファイル群の1つ目)
       - 部分一致するディレクトリまたはPDF
    """
    p = Path(target_input)
    if p.exists():
        return p.resolve()

    # Inbox 内を探索
    inbox_dirs = find_inbox_dirs()
    clean_target = target_input.strip().rstrip("/\\")
    lower_target = clean_target.lower()

    for inbox in inbox_dirs:
        # 1. ズバリの名前のディレクトリ (例: Inbox/music)
        dir_exact = inbox / clean_target
        if dir_exact.exists() and dir_exact.is_dir():
            return dir_exact.resolve()

        # 2. ズバリの名前のPDF (例: Inbox/music.pdf)
        pdf_exact = inbox / f"{clean_target}.pdf"
        if pdf_exact.exists() and pdf_exact.is_file():
            return pdf_exact.resolve()

        # 3. 前方一致のPDF (例: Inbox/music1.pdf, Inbox/music_01.pdf)
        matched_pdfs = sorted(
            [
                f
                for f in inbox.iterdir()
                if f.is_file()
                and f.suffix.lower() == ".pdf"
                and f.stem.lower().startswith(lower_target)
            ]
        )
        if matched_pdfs:
            return matched_pdfs[0].resolve()

        # 4. ディレクトリ名にキーワードを含むもの (例: Inbox/2026-music)
        matched_dirs = sorted(
            [
                d
                for d in inbox.iterdir()
                if d.is_dir() and lower_target in d.name.lower()
            ]
        )
        if matched_dirs:
            return matched_dirs[0].resolve()

        # 5. 部分一致のPDF (例: Inbox/score_music.pdf)
        matched_any_pdfs = sorted(
            [
                f
                for f in inbox.iterdir()
                if f.is_file()
                and f.suffix.lower() == ".pdf"
                and lower_target in f.stem.lower()
            ]
        )
        if matched_any_pdfs:
            return matched_any_pdfs[0].resolve()

    return p.resolve()


def find_originals_dir(file_path: Path, specified_dir: str | None = None) -> Path:
    """原本の退避先ディレクトリを決定する"""
    if specified_dir:
        return Path(specified_dir)

    # 候補1: 親の親にある Originals (例: /Volumes/EXTERNAL/Scan/Inbox/file.pdf -> /Volumes/EXTERNAL/Scan/Originals)
    parent_parent_orig = file_path.parent.parent / "Originals"
    if parent_parent_orig.exists():
        return parent_parent_orig

    # 候補2: 同じ親にある Originals (例: ./Inbox/file.pdf -> ./Originals)
    parent_orig = file_path.parent / "Originals"
    if parent_orig.exists():
        return parent_orig

    # デフォルト: 親の親/Originals を作成して使用、なければ親/Originals
    if file_path.parent.name == "Inbox":
        return file_path.parent.parent / "Originals"
    return file_path.parent / "Originals"


def find_output_dir(file_path: Path, specified_dir: str | None = None) -> Path:
    """保存先ディレクトリを決定する（ルート階層の skills/pdf-spread-splitter）"""
    if specified_dir:
        return Path(specified_dir)

    # 候補1: 親が Inbox の場合 -> 親の親/skills/pdf-spread-splitter
    if file_path.parent.name == "Inbox":
        return file_path.parent.parent / "skills" / "pdf-spread-splitter"

    # 候補2: 親の親に Inbox や Originals がある場合 (ルート配下のサブフォルダ)
    if (file_path.parent.parent / "Inbox").exists() or (file_path.parent.parent / "Originals").exists():
        return file_path.parent.parent / "skills" / "pdf-spread-splitter"

    # 候補3: 同じ親に Inbox や Originals がある場合
    if (file_path.parent / "Inbox").exists() or (file_path.parent / "Originals").exists():
        return file_path.parent / "skills" / "pdf-spread-splitter"

    # デフォルト: 親の親/skills/pdf-spread-splitter、なければ親/skills/pdf-spread-splitter
    if file_path.parent.parent.exists():
        return file_path.parent.parent / "skills" / "pdf-spread-splitter"
    return file_path.parent / "skills" / "pdf-spread-splitter"


def is_image_blank(img: Image.Image) -> bool:
    """
    Pillow画像が白紙（ほぼ真っ白）であるかを判定する。
    外周5%のマージン（スキャナの影やフチノイズ）を除外して中央領域の白画素率を計測。
    """
    gray = img.convert("L")
    w, h = gray.size
    crop_box = (int(w * 0.05), int(h * 0.05), int(w * 0.95), int(h * 0.95))
    inner = gray.crop(crop_box)
    arr = np.array(inner)
    white_ratio = float((arr > 240).mean())
    mean_val = float(arr.mean())

    # 白画素率が 99.0% 以上かつ平均輝度 245 以上なら白紙と判定
    return white_ratio >= 0.99 and mean_val >= 245.0


def ocr_page_number(img: Image.Image) -> int | None:
    """
    Pillow画像の最下部（フッター領域）からノンブル（ページ番号）を OCR で検出する。
    """
    w, h = img.size
    bottom_crop = img.crop((0, int(h * 0.90), w, h))

    tmp_dir = ensure_tmp_dir()
    crop_tmp = tmp_dir / f"crop_{uuid.uuid4().hex[:8]}.png"
    bottom_crop.save(crop_tmp)

    try:
        res = subprocess.run(
            ["tesseract", str(crop_tmp), "stdout", "--psm", "6"],
            capture_output=True,
            text=True,
            timeout=3,
            check=True,
        )
        text = res.stdout.strip()
        matches = re.findall(r"[-—~〜]?\s*(\d{1,4})\s*[-—~〜]?", text)
        if matches:
            for m in reversed(matches):
                val = int(m)
                if 1 <= val <= 2000:
                    return val
        return None
    except Exception:
        return None
    finally:
        crop_tmp.unlink(missing_ok=True)


def validate_page_continuity(detected_pages: list[tuple[int, int]]) -> list[str]:
    """
    検出されたページ番号の連続性を検証する。
    detected_pages: [(実ページ番号, 検出されたノンブル), ...]
    戻り値: 警告メッセージのリスト
    """
    warnings = []
    if len(detected_pages) < 2:
        return warnings

    for i in range(1, len(detected_pages)):
        prev_idx, prev_num = detected_pages[i - 1]
        curr_idx, curr_num = detected_pages[i]

        expected_diff = curr_idx - prev_idx
        actual_diff = curr_num - prev_num

        if actual_diff <= 0:
            warnings.append(
                f"⚠️ ページ番号の逆転/重複を検知: P{prev_idx}(ノンブル:{prev_num}) ➔ P{curr_idx}(ノンブル:{curr_num})"
            )
        elif actual_diff != expected_diff:
            missing_count = actual_diff - expected_diff
            warnings.append(
                f"⚠️ ページ番号の不連続/飛びを検知: P{prev_idx}(ノンブル:{prev_num}) ➔ P{curr_idx}(ノンブル:{curr_num}) "
                f"({missing_count}ページの欠番または重送の可能性)"
            )

    return warnings


def compute_image_diff(img1: Image.Image | None, img2: Image.Image | None) -> float:
    """
    2枚の画像の平均絶対輝度差（0.0〜255.0）を計算する。
    画像がNoneの場合は 999.0 を返す。
    """
    if img1 is None or img2 is None:
        return 999.0
    try:
        g1 = img1.convert("L").resize((64, 64))
        g2 = img2.convert("L").resize((64, 64))
        diff = ImageChops.difference(g1, g2)
        stat = ImageStat.Stat(diff)
        return float(stat.mean[0])
    except Exception:
        return 999.0


@dataclass
class DuplicateInfo:
    first_indices: list[int]      # 0-indexed candidate indices
    second_indices: list[int]     # 0-indexed candidate indices (除外候補)
    first_pages: list[int]        # 1-indexed output page numbers
    second_pages: list[int]       # 1-indexed output page numbers
    first_nombres: list[int | None]
    second_nombres: list[int | None]
    reason: str
    suggestion: str


def detect_duplicate_pages(pages_meta: list[dict]) -> list[DuplicateInfo]:
    """
    分割後の候補ページ列から重複（特に2ページごとの見開き重複スキャン: 3,4,3,4 等）を検出する。
    pages_meta: 各候補ページのメタデータ辞書のリスト
      - page_num: 1-indexed
      - nombre: int | None
      - half_img: Image.Image | None
      - input_file: Path
      - spread_idx: int
      - side: str ("left" | "right")
    戻り値: 検出された重複情報 DuplicateInfo のリスト
    """
    duplicates: list[DuplicateInfo] = []
    n = len(pages_meta)
    if n < 2:
        return duplicates

    matched_second_indices: set[int] = set()
    matched_all_indices: set[int] = set()

    # 1. 2ページ単位（見開き）の重複チェック (優先)
    # 隣接する2ページペア (i, i+1) と (i+2, i+3)
    i = 0
    while i <= n - 4:
        if i in matched_all_indices or (i + 1) in matched_all_indices:
            i += 1
            continue

        p1, p2 = pages_meta[i], pages_meta[i + 1]
        p3, p4 = pages_meta[i + 2], pages_meta[i + 3]

        n1, n2 = p1.get("nombre"), p2.get("nombre")
        n3, n4 = p3.get("nombre"), p4.get("nombre")

        diff_left = compute_image_diff(p1.get("half_img"), p3.get("half_img"))
        diff_right = compute_image_diff(p2.get("half_img"), p4.get("half_img"))

        is_dup = False
        reason = ""

        # ケースA: ノンブル完全一致 (例: 3, 4, 3, 4)
        if n1 is not None and n2 is not None and n1 == n3 and n2 == n4:
            is_dup = True
            reason = f"ノンブル完全一致 ({n1}, {n2}, {n3}, {n4})"
            if diff_left < 15.0 and diff_right < 15.0:
                reason += f" & 画像類似 (diff: {diff_left:.1f}, {diff_right:.1f})"

        # ケースB: ノンブル片方一致かつ画像類似 (例: 3, None, 3, None)
        elif (n1 is not None and n1 == n3 and diff_right < 12.0) or (
            n2 is not None and n2 == n4 and diff_left < 12.0
        ):
            is_dup = True
            n_str = f"ノンブル一部一致 ({n1 or '?'}, {n2 or '?'}) ➔ ({n3 or '?'}, {n4 or '?'})"
            reason = f"{n_str} & 画像類似 (diff: {diff_left:.1f}, {diff_right:.1f})"

        # ケースC: 画像差分が極小 (同一原稿の二重スキャン)
        elif diff_left < 7.0 and diff_right < 7.0:
            is_dup = True
            reason = f"画像類似度極めて高い (diff: {diff_left:.1f}, {diff_right:.1f})"

        if is_dup:
            p_first = [p1["page_num"], p2["page_num"]]
            p_sec = [p3["page_num"], p4["page_num"]]
            sec_pages_str = f"P{p_sec[0]}, P{p_sec[1]}"
            first_pages_str = f"P{p_first[0]}, P{p_first[1]}"
            n_sec_str = f"ノンブル: {n3 or '?'}, {n4 or '?'}"
            n_first_str = f"ノンブル: {n1 or '?'}, {n2 or '?'}"

            sug = (
                f"重複している {sec_pages_str} ({n_sec_str}) の削除を推奨します "
                f"(--remove-duplicates で自動除外可能)"
            )

            dup_info = DuplicateInfo(
                first_indices=[i, i + 1],
                second_indices=[i + 2, i + 3],
                first_pages=p_first,
                second_pages=p_sec,
                first_nombres=[n1, n2],
                second_nombres=[n3, n4],
                reason=reason,
                suggestion=sug,
            )
            duplicates.append(dup_info)
            matched_second_indices.update([i + 2, i + 3])
            matched_all_indices.update([i, i + 1, i + 2, i + 3])
            i += 4  # 重複ブロックをスキップ
            continue

        i += 1

    # 2. 1ページ単位の重複チェック
    for j in range(n - 1):
        if j in matched_all_indices or (j + 1) in matched_all_indices:
            continue
        pj1, pj2 = pages_meta[j], pages_meta[j + 1]
        nj1, nj2 = pj1.get("nombre"), pj2.get("nombre")
        diff_single = compute_image_diff(pj1.get("half_img"), pj2.get("half_img"))

        is_single_dup = False
        reason = ""
        if nj1 is not None and nj1 == nj2 and diff_single < 15.0:
            is_single_dup = True
            reason = f"ノンブル一致 ({nj1}) & 画像類似 (diff: {diff_single:.1f})"
        elif diff_single < 5.0:
            is_single_dup = True
            reason = f"画像類似度極めて高い (diff: {diff_single:.1f})"

        if is_single_dup:
            p_first = [pj1["page_num"]]
            p_sec = [pj2["page_num"]]
            sug = (
                f"重複している P{pj2['page_num']} (ノンブル: {nj2 or '?'}) の削除を推奨します "
                f"(--remove-duplicates で自動除外可能)"
            )
            dup_info = DuplicateInfo(
                first_indices=[j],
                second_indices=[j + 1],
                first_pages=p_first,
                second_pages=p_sec,
                first_nombres=[nj1],
                second_nombres=[nj2],
                reason=reason,
                suggestion=sug,
            )
            duplicates.append(dup_info)
            matched_second_indices.add(j + 1)
            matched_all_indices.update([j, j + 1])

    return duplicates


def group_sequential_files(files: list[Path]) -> dict[str, list[Path]]:
    """
    ファイル群から連番パターン（例: music1.pdf, music2.pdf）をグループ化する。
    戻り値: { "music.pdf": [Path(music1.pdf), Path(music2.pdf)], "other.pdf": [Path(other.pdf)] }
    """
    groups: dict[str, list[tuple[int, Path]]] = {}
    singles: list[Path] = []

    pattern = re.compile(r"^(.*?)(?:[-_])?(\d+)$", re.IGNORECASE)

    for f in sorted(files):
        stem = f.stem
        match = pattern.match(stem)
        if match:
            prefix = match.group(1).rstrip("-_")
            num = int(match.group(2))
            if not prefix:
                prefix = "scan"
            group_key = f"{prefix}.pdf"
            if group_key not in groups:
                groups[group_key] = []
            groups[group_key].append((num, f))
        else:
            singles.append(f)

    result: dict[str, list[Path]] = {}

    for group_key, file_tuples in groups.items():
        if len(file_tuples) > 1:
            file_tuples.sort(key=lambda x: x[0])
            result[group_key] = [t[1] for t in file_tuples]
        else:
            single_file = file_tuples[0][1]
            result[single_file.name] = [single_file]

    for s in singles:
        result[s.name] = [s]

    return result


def render_pdf_spreads_to_images(pdf_path: Path, dpi: int = 50) -> list[Path]:
    """
    PDF内の全スプレッドを一度に高速画像レンダリングする (50 DPI)。
    戻り値: レンダリングされたPNG画像ファイルパスのソート済みリスト
    """
    tmp_dir = ensure_tmp_dir()
    unique_id = uuid.uuid4().hex[:8]
    png_prefix = tmp_dir / f"sp_{unique_id}"

    subprocess.run(
        ["pdftoppm", "-png", "-r", str(dpi), str(pdf_path), str(png_prefix)],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=True,
    )

    rendered_images = sorted(
        tmp_dir.glob(f"sp_{unique_id}-*.png"),
        key=lambda p: int(p.stem.split("-")[-1]) if p.stem.split("-")[-1].isdigit() else 0,
    )
    return rendered_images


def split_pdf_files_to_single_doc(
    input_files: list[Path],
    output_file: Path,
    rtl: bool = False,
    rotate_ccw: bool = False,
    no_rotate: bool = False,
    remove_blank: bool = True,
    verify_page_numbers: bool = True,
    remove_duplicates: bool = False,
) -> tuple[int, int, int, list[str]]:
    """
    複数の入力PDF（1つまたは連番）を分割・結合して1つのPDFを生成する。
    戻り値: (元スプレッド数, 生成ページ数, 除外白紙数, 警告リスト)
    """
    writer = PdfWriter()
    total_spreads = 0
    blank_count = 0
    all_rendered_tmp_files: list[Path] = []
    candidates_meta: list[dict] = []

    try:
        candidate_counter = 0
        for input_file in input_files:
            reader = PdfReader(str(input_file))
            spread_count = len(reader.pages)
            if spread_count == 0:
                continue
            total_spreads += spread_count

            # 高速一括レンダリング (DPI 50 で判定には完全十分、処理は2〜3秒)
            spread_images = []
            if remove_blank or verify_page_numbers:
                spread_images = render_pdf_spreads_to_images(input_file, dpi=50)
                all_rendered_tmp_files.extend(spread_images)

            for s_idx, src_page in enumerate(reader.pages):
                # 元ページの縦横判定（Rotate属性も考慮）
                orig_w = float(src_page.mediabox.width)
                orig_h = float(src_page.mediabox.height)
                page_rot = src_page.get("/Rotate", 0) % 360
                if page_rot in (90, 270):
                    orig_w, orig_h = orig_h, orig_w

                # 初めにA3縦長だったらA3横長に回転 (時計回り90度: 90° CW)
                is_portrait = orig_h > orig_w
                if not no_rotate and is_portrait:
                    rot_angle = -90 if rotate_ccw else 90
                    src_page.rotate(rot_angle)
                    src_page.transfer_rotation_to_content()

                # 画像の切り出し
                img_left = None
                img_right = None
                if s_idx < len(spread_images):
                    with Image.open(spread_images[s_idx]) as sp_img:
                        if not no_rotate and is_portrait:
                            # 時計回り90度回転 (PILのrotateは反時計回り基準なので-90で時計回り)
                            sp_img = sp_img.rotate(-90 if not rotate_ccw else 90, expand=True)
                        iw, ih = sp_img.size
                        half_iw = iw // 2
                        img_left = sp_img.crop((0, 0, half_iw, ih)).copy()
                        img_right = sp_img.crop((half_iw, 0, iw, ih)).copy()

                # 左右どちらから処理するか
                halves_to_process = (
                    [("right", img_right, "右"), ("left", img_left, "左")]
                    if rtl
                    else [("left", img_left, "左"), ("right", img_right, "右")]
                )

                for side, half_img, side_label in halves_to_process:
                    # 白紙判定
                    if remove_blank and half_img is not None and is_image_blank(half_img):
                        blank_count += 1
                        print(f"      ⚪️ 白紙ページを除外しました ({input_file.name} スプレッド{s_idx + 1} {side_label}側)")
                        continue

                    # ノンブル検出
                    p_num = None
                    if verify_page_numbers and half_img is not None:
                        p_num = ocr_page_number(half_img)

                    candidate_counter += 1
                    candidates_meta.append(
                        {
                            "candidate_idx": candidate_counter - 1,
                            "page_num": candidate_counter,
                            "src_page": src_page,
                            "side": side,
                            "side_label": side_label,
                            "half_img": half_img,
                            "nombre": p_num,
                            "input_file": input_file,
                            "spread_idx": s_idx,
                        }
                    )

        # 重複検知
        warnings: list[str] = []
        indices_to_exclude: set[int] = set()

        if verify_page_numbers:
            detected_dups = detect_duplicate_pages(candidates_meta)
            for dup in detected_dups:
                p_first_str = ", ".join(f"P{p}" for p in dup.first_pages)
                p_sec_str = ", ".join(f"P{p}" for p in dup.second_pages)
                n_first_str = ", ".join(str(n) if n is not None else "?" for n in dup.first_nombres)
                n_sec_str = ", ".join(str(n) if n is not None else "?" for n in dup.second_nombres)

                msg = (
                    f"⚠️ 見開き重複スキャンを検知しました:\n"
                    f"      ・ 1回目: {p_first_str} (ノンブル: {n_first_str})\n"
                    f"      ・ 2回目: {p_sec_str} (ノンブル: {n_sec_str}) [{dup.reason}]\n"
                    f"      👉 提案: {dup.suggestion}"
                )
                warnings.append(msg)
                if remove_duplicates:
                    indices_to_exclude.update(dup.second_indices)

        # PDFへページ追加
        detected_numbers: list[tuple[int, int]] = []
        current_out_page = 0

        for idx, meta in enumerate(candidates_meta):
            if idx in indices_to_exclude:
                print(f"      ✂️ 重複ページを除外しました: P{meta['page_num']} ({meta['input_file'].name} スプレッド{meta['spread_idx'] + 1} {meta['side_label']}側)")
                continue

            writer.add_page(meta["src_page"])
            added_page = writer.pages[-1]

            # スプレッドはすでに横長に正立しているため、左右半分を MediaBox/CropBox で指定
            cur_w = float(added_page.mediabox.width)
            cur_h = float(added_page.mediabox.height)
            half_w = cur_w / 2.0

            if meta["side"] == "left":
                added_page.mediabox.lower_left = (0.0, 0.0)
                added_page.mediabox.upper_right = (half_w, cur_h)
                added_page.cropbox.lower_left = (0.0, 0.0)
                added_page.cropbox.upper_right = (half_w, cur_h)
            else:
                added_page.mediabox.lower_left = (half_w, 0.0)
                added_page.mediabox.upper_right = (cur_w, cur_h)
                added_page.cropbox.lower_left = (half_w, 0.0)
                added_page.cropbox.upper_right = (cur_w, cur_h)

            current_out_page += 1
            if meta["nombre"] is not None:
                detected_numbers.append((current_out_page, meta["nombre"]))

        output_file.parent.mkdir(parents=True, exist_ok=True)
        with open(output_file, "wb") as f:
            writer.write(f)

    finally:
        for tmp_file in all_rendered_tmp_files:
            tmp_file.unlink(missing_ok=True)

    # ページ連続性の検証
    if verify_page_numbers and detected_numbers:
        continuity_warnings = validate_page_continuity(detected_numbers)
        warnings.extend(continuity_warnings)

    return total_spreads, current_out_page, blank_count, warnings


def process_group(
    group_name: str,
    files: list[Path],
    output_dir: Path | None = None,
    originals_dir: Path | None = None,
    keep_original: bool = False,
    rtl: bool = False,
    rotate_ccw: bool = False,
    no_rotate: bool = False,
    no_remove_blank: bool = False,
    no_verify_pages: bool = False,
    remove_duplicates: bool = False,
) -> bool:
    """1つのファイルグループ（単一または連番ファイル群）を処理する"""
    start_time = time.time()
    parent_dir = files[0].parent
    target_output_dir = output_dir or find_output_dir(files[0])
    target_output_file = target_output_dir / group_name

    file_names = ", ".join(f.name for f in files)
    print(f"\n📄 処理グループ開始: {group_name}")
    print(f"   構成ファイル ({len(files)}件): {file_names}")
    print(f"   出力先: {target_output_file}")

    try:
        total_spreads, new_pages, blank_count, warnings = split_pdf_files_to_single_doc(
            input_files=files,
            output_file=target_output_file,
            rtl=rtl,
            rotate_ccw=rotate_ccw,
            no_rotate=no_rotate,
            remove_blank=not no_remove_blank,
            verify_page_numbers=not no_verify_pages,
            remove_duplicates=remove_duplicates,
        )
    except Exception as e:
        print(f"❌ エラー: 分割処理に失敗しました: {e}", file=sys.stderr)
        return False

    elapsed = time.time() - start_time
    print(f"   ✅ 分割完了: 計{total_spreads}見開き ➔ {new_pages}ページ (除外白紙: {blank_count}枚, {elapsed:.2f}秒)")

    if warnings:
        for w in warnings:
            print(f"   {w}")
    else:
        print("   ✅ ページ番号の連続性: 正常にインクリメントされていることを確認しました")

    # 原本移動処理
    if not keep_original:
        for f in files:
            target_orig_dir = find_originals_dir(f, str(originals_dir) if originals_dir else None)
            target_orig_dir.mkdir(parents=True, exist_ok=True)
            dest_orig_path = target_orig_dir / f.name

            if dest_orig_path.exists():
                stem = f.stem
                suffix = f.suffix
                counter = 1
                while dest_orig_path.exists():
                    dest_orig_path = target_orig_dir / f"{stem}_{counter}{suffix}"
                    counter += 1

            shutil.move(str(f), str(dest_orig_path))
            print(f"   📦 原本退避: {f.name} ➔ {dest_orig_path}")
    else:
        print("   🔒 原本保持 (--keep-original が指定されたため移動しません)")

    return True


def main():
    parser = argparse.ArgumentParser(
        description="見開きPDF（A3/B4等）を左右2枚の単一ページ（A4/B5等）に無劣化分割するツール"
    )
    parser.add_argument("target", help="処理対象のPDFファイルまたはディレクトリ")
    parser.add_argument(
        "--rtl",
        action="store_true",
        help="右開き（右ページ ➔ 左ページ）で出力（縦書き書籍・漫画向け）",
    )
    parser.add_argument(
        "--rotate-ccw",
        action="store_true",
        help="縦長原稿を反時計回り（90° CCW / 左90度）に回転（デフォルトは時計回り 90° CW）",
    )
    parser.add_argument(
        "--no-rotate",
        action="store_true",
        help="縦長判定時の自動回転補正を行わない",
    )
    parser.add_argument(
        "--keep-original",
        action="store_true",
        help="元ファイルを Originals/ へ移動せず保持する",
    )
    parser.add_argument(
        "--no-remove-blank",
        action="store_true",
        help="白紙ページの自動除外を行わない",
    )
    parser.add_argument(
        "--no-verify-pages",
        action="store_true",
        help="ページ番号（ノンブル）の連続性検証を行わない",
    )
    parser.add_argument(
        "--remove-duplicates",
        "-d",
        action="store_true",
        help="検知された重複ページ（2ページ単位の見開き重複スキャン等）を自動除外してPDFを生成",
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=None,
        help="出力先ディレクトリ（未指定時はルート階層の skills/pdf-spread-splitter）",
    )
    parser.add_argument(
        "--originals-dir",
        type=Path,
        default=None,
        help="原本退避先ディレクトリ（未指定時は自動検出）",
    )

    args = parser.parse_args()
    target_path = resolve_target_path(args.target)
    if str(target_path) != args.target:
        print(f"🔍 ターゲット検索: '{args.target}' ➔ '{target_path}'")

    if not target_path.exists():
        print(f"エラー: 指定されたパス（またはInbox内の検索対象）が存在しません: {args.target}", file=sys.stderr)
        sys.exit(1)

    if target_path.is_file():
        parent_dir = target_path.parent
        sibling_pdfs = [
            p for p in parent_dir.iterdir()
            if p.is_file() and p.suffix.lower() == ".pdf" and not p.name.startswith(".")
        ]
        groups = group_sequential_files(sibling_pdfs)
        target_group_key = None
        target_group_files = [target_path]

        for g_key, g_files in groups.items():
            if target_path in g_files:
                target_group_key = g_key
                target_group_files = g_files
                break

        if target_group_key is None:
            target_group_key = target_path.name

        success = process_group(
            group_name=target_group_key,
            files=target_group_files,
            output_dir=args.output_dir,
            originals_dir=args.originals_dir,
            keep_original=args.keep_original,
            rtl=args.rtl,
            rotate_ccw=args.rotate_ccw,
            no_rotate=args.no_rotate,
            no_remove_blank=args.no_remove_blank,
            no_verify_pages=args.no_verify_pages,
            remove_duplicates=args.remove_duplicates,
        )
        sys.exit(0 if success else 1)

    elif target_path.is_dir():
        pdf_files = sorted(
            [
                p for p in target_path.iterdir()
                if p.is_file() and p.suffix.lower() == ".pdf" and not p.name.startswith(".")
            ]
        )
        if not pdf_files:
            print(f"ディレクトリ内に処理対象のPDFファイルが見つかりません: {target_path}")
            sys.exit(0)

        groups = group_sequential_files(pdf_files)
        print(f"📂 ディレクトリ一括処理開始: {len(pdf_files)}件のPDF ➔ {len(groups)}個のグループに分類")
        success_count = 0
        for g_key, g_files in groups.items():
            if process_group(
                group_name=g_key,
                files=g_files,
                output_dir=args.output_dir,
                originals_dir=args.originals_dir,
                keep_original=args.keep_original,
                rtl=args.rtl,
                rotate_ccw=args.rotate_ccw,
                no_rotate=args.no_rotate,
                no_remove_blank=args.no_remove_blank,
                no_verify_pages=args.no_verify_pages,
                remove_duplicates=args.remove_duplicates,
            ):
                success_count += 1

        print(f"\n🎉 完了: {len(groups)}グループ中 {success_count}グループ 正常終了")
        sys.exit(0 if success_count == len(groups) else 1)


if __name__ == "__main__":
    main()
