#!/usr/bin/env python3
"""
Unit tests for split_spread.py
"""

import shutil
import tempfile
import unittest
from pathlib import Path
from pypdf import PdfReader, PdfWriter, PageObject

# Import functions from split_spread
import sys
sys.path.insert(0, str(Path(__file__).parent))
from split_spread import (
    compute_image_diff,
    detect_duplicate_pages,
    find_originals_dir,
    find_output_dir,
    group_sequential_files,
    is_image_blank,
    process_group,
    resolve_target_path,
    split_pdf_files_to_single_doc,
    validate_page_continuity,
)


def create_test_pdf(file_path: Path, is_portrait: bool = True, page_count: int = 2):
    """テスト用の見開きPDFを作成する (pypdf純粋実装)"""
    writer = PdfWriter()
    w, h = (841.89, 1190.55) if is_portrait else (1190.55, 841.89)

    for _ in range(page_count):
        page = PageObject.create_blank_page(width=w, height=h)
        writer.add_page(page)

    with open(file_path, "wb") as f:
        writer.write(f)


class TestSplitSpread(unittest.TestCase):
    def setUp(self):
        self.temp_dir = Path(tempfile.mkdtemp(prefix="test_split_spread_"))

    def tearDown(self):
        shutil.rmtree(self.temp_dir, ignore_errors=True)

    def test_group_sequential_files(self):
        """連番ファイルが同一グループにまとめられ、単独ファイルは維持されることをテスト"""
        files = [
            Path("/path/to/music1.pdf"),
            Path("/path/to/music2.pdf"),
            Path("/path/to/score_01.pdf"),
            Path("/path/to/score_02.pdf"),
            Path("/path/to/standalone.pdf"),
        ]
        groups = group_sequential_files(files)
        self.assertIn("music.pdf", groups)
        self.assertEqual(len(groups["music.pdf"]), 2)
        self.assertEqual(groups["music.pdf"][0].name, "music1.pdf")
        self.assertEqual(groups["music.pdf"][1].name, "music2.pdf")

        self.assertIn("score.pdf", groups)
        self.assertEqual(len(groups["score.pdf"]), 2)

        self.assertIn("standalone.pdf", groups)
        self.assertEqual(len(groups["standalone.pdf"]), 1)

    def test_validate_page_continuity(self):
        """ページ番号の連続性・飛び・逆転の検出をテスト"""
        # 1. 正常な連続
        ok_pages = [(1, 22), (2, 23), (3, 24)]
        self.assertEqual(validate_page_continuity(ok_pages), [])

        # 2. 飛び（欠番）
        gap_pages = [(1, 22), (2, 25)]
        warnings = validate_page_continuity(gap_pages)
        self.assertEqual(len(warnings), 1)
        self.assertIn("飛び", warnings[0])

        # 3. 逆転
        rev_pages = [(1, 23), (2, 22)]
        warnings = validate_page_continuity(rev_pages)
        self.assertEqual(len(warnings), 1)
        self.assertIn("逆転", warnings[0])

    def test_is_image_blank(self):
        """白紙ページの検出テスト"""
        from PIL import Image
        blank_img = Image.new("RGB", (600, 800), color=(255, 255, 255))
        self.assertTrue(is_image_blank(blank_img))

        # 非白紙（黒い矩形がある）
        non_blank = Image.new("RGB", (600, 800), color=(255, 255, 255))
        from PIL import ImageDraw
        draw = ImageDraw.Draw(non_blank)
        draw.rectangle([100, 100, 300, 300], fill=(0, 0, 0))
        self.assertFalse(is_image_blank(non_blank))

    def test_detect_duplicate_pages_2page_spread(self):
        """見開き重複スキャン (3, 4, 3, 4 のような2ページ単位の重複) を正しく検知し削除提案することをテスト"""
        # 4ページ分のメタデータを作成: [3, 4, 3, 4]
        from PIL import Image
        dummy_img = Image.new("RGB", (100, 100), color=(200, 200, 200))
        pages_meta = [
            {"page_num": 1, "nombre": 3, "half_img": dummy_img},
            {"page_num": 2, "nombre": 4, "half_img": dummy_img},
            {"page_num": 3, "nombre": 3, "half_img": dummy_img},
            {"page_num": 4, "nombre": 4, "half_img": dummy_img},
        ]
        dups = detect_duplicate_pages(pages_meta)
        self.assertEqual(len(dups), 1)
        dup = dups[0]
        self.assertEqual(dup.first_pages, [1, 2])
        self.assertEqual(dup.second_pages, [3, 4])
        self.assertEqual(dup.first_nombres, [3, 4])
        self.assertEqual(dup.second_nombres, [3, 4])
        self.assertIn("3, 4", dup.reason)
        self.assertIn("削除を推奨", dup.suggestion)

    def test_detect_duplicate_pages_image_similarity(self):
        """ノンブルが読めなくても画像類似度で重複スキャンが検知されることをテスト"""
        from PIL import Image, ImageDraw
        img1 = Image.new("RGB", (100, 100), color=(240, 240, 240))
        draw1 = ImageDraw.Draw(img1)
        draw1.line([(10, 10), (80, 80)], fill=(0, 0, 0), width=3)

        img2 = Image.new("RGB", (100, 100), color=(240, 240, 240))
        draw2 = ImageDraw.Draw(img2)
        draw2.line([(10, 80), (80, 10)], fill=(0, 0, 0), width=3)

        # スプレッド1: (img1, img2), スプレッド2（重複スキャン）: (img1, img2)
        pages_meta = [
            {"page_num": 1, "nombre": None, "half_img": img1},
            {"page_num": 2, "nombre": None, "half_img": img2},
            {"page_num": 3, "nombre": None, "half_img": img1},
            {"page_num": 4, "nombre": None, "half_img": img2},
        ]
        dups = detect_duplicate_pages(pages_meta)
        self.assertEqual(len(dups), 1)
        self.assertEqual(dups[0].first_pages, [1, 2])
        self.assertEqual(dups[0].second_pages, [3, 4])
        self.assertIn("画像類似度", dups[0].reason)

    def test_split_and_merge_sequential_group(self):
        """連番ファイルが1つのPDFにマージされ、白紙除外なしオプションで正しく分割されることをテスト"""
        f1 = self.temp_dir / "music1.pdf"
        f2 = self.temp_dir / "music2.pdf"
        create_test_pdf(f1, is_portrait=True, page_count=1) # 1 spread -> 2 pages
        create_test_pdf(f2, is_portrait=True, page_count=2) # 2 spreads -> 4 pages

        out_pdf = self.temp_dir / "out" / "music.pdf"
        # 白紙除外をオフにしてページ数遷移を検証
        spreads, pages, blanks, warnings = split_pdf_files_to_single_doc(
            input_files=[f1, f2],
            output_file=out_pdf,
            remove_blank=False,
            verify_page_numbers=False,
        )

        self.assertEqual(spreads, 3)
        self.assertEqual(pages, 6)
        self.assertTrue(out_pdf.exists())

        reader = PdfReader(str(out_pdf))
        self.assertEqual(len(reader.pages), 6)

    def test_find_originals_dir(self):
        """原本退避先ディレクトリの検出ロジックをテスト"""
        inbox_dir = self.temp_dir / "Scan" / "Inbox"
        orig_dir = self.temp_dir / "Scan" / "Originals"
        inbox_dir.mkdir(parents=True)
        orig_dir.mkdir(parents=True)

        pdf_path = inbox_dir / "scan1.pdf"
        detected = find_originals_dir(pdf_path)
        self.assertEqual(detected, orig_dir)

    def test_resolve_target_path(self):
        """キーワード 'music' から Inbox 内の連番PDFやディレクトリが解決されることをテスト"""
        # 直接存在するファイル
        direct_file = self.temp_dir / "direct.pdf"
        direct_file.touch()
        self.assertEqual(resolve_target_path(str(direct_file)), direct_file.resolve())

        # 存在しないパスでも resolve される
        non_existent = self.temp_dir / "none.pdf"
        self.assertEqual(resolve_target_path(str(non_existent)), non_existent.resolve())

    def test_find_output_dir(self):
        """保存先ディレクトリ（ルート階層の skills/pdf-spread-splitter）の検出ロジックをテスト"""
        scan_root = self.temp_dir / "Scan"
        inbox_dir = scan_root / "Inbox"
        expected_output_dir = scan_root / "skills" / "pdf-spread-splitter"
        inbox_dir.mkdir(parents=True)

        pdf_path = inbox_dir / "music1.pdf"
        detected = find_output_dir(pdf_path)
        self.assertEqual(detected, expected_output_dir)


if __name__ == "__main__":
    unittest.main()
