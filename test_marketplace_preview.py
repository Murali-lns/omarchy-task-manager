#!/usr/bin/python3
"""Guards the marketplace preview: a real PNG, inside the published limits."""

from __future__ import annotations

import struct
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent
PREVIEW = ROOT / "preview.png"
MAX_BYTES = 50 * 1024 * 1024
MAX_PIXELS = 40_000_000


class MarketplacePreviewTests(unittest.TestCase):
    def test_preview_is_a_bounded_png(self):
        self.assertTrue(PREVIEW.is_file(), "root preview.png is required for this listing")
        data = PREVIEW.read_bytes()
        self.assertTrue(data.startswith(b"\x89PNG\r\n\x1a\n"))
        self.assertLess(len(data), MAX_BYTES)
        width, height = struct.unpack(">II", data[16:24])
        self.assertGreater(width, 400)
        self.assertGreater(height, 400)
        self.assertLess(width * height, MAX_PIXELS)
        # A full desktop capture is not a card preview.
        self.assertLess(width, 1800)
        self.assertLess(height, 1200)
