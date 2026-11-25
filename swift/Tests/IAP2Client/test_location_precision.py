"""核对 iAP2 经纬度编码精度、分钟进位和五米取样范围。"""
import math
import random
import unittest
from unittest.mock import patch

from accessory_location.profile import coordinate, jittered_point, location_sentences


class LocationPrecisionTests(unittest.TestCase):
    def test_nmea_positions(self):
        for lat, lon in [(23.12345678, 113.87654321), (-89.999999999, -179.999999999)]:
            gga, rmc = location_sentences(lat, lon).values()
            self.assertLessEqual(max(len(gga), len(rmc)), 82)
            fields = gga.split(",")[2:6]
            self.assertEqual(fields, rmc.split(",")[3:7])
            for value, raw, side, width in [(lat, *fields[:2], 2), (lon, *fields[2:], 3)]:
                minutes = float(raw[width:])
                self.assertLess(minutes, 60)
                decoded = (int(raw[:width]) + minutes / 60) * (-1 if side in ("S", "W") else 1)
                self.assertAlmostEqual(value, decoded, delta=0.5e-6 / 60)
        self.assertEqual(coordinate(89.999999999, True), ("9000.000000", "N"))

    def test_radius_including_poles_and_date_line(self):
        generator = random.Random(514)
        with patch("accessory_location.profile.random.random", generator.random):
            for lat, lon in [(23.1, 113.4), (0, 179.9999999), (90, 180), (-90, -180)]:
                distances = []
                for _ in range(256):
                    y, x = jittered_point(lat, lon)
                    self.assertTrue(-90 <= y <= 90 and -180 <= x < 180)
                    a = (math.sin(math.radians(y - lat) / 2) ** 2
                         + math.cos(math.radians(y)) * math.cos(math.radians(lat))
                         * math.sin(math.radians(x - lon) / 2) ** 2)
                    distances.append(2 * 6_371_008.8 * math.asin(math.sqrt(a)))
                self.assertLessEqual(max(distances), 5)
                self.assertGreater(max(distances), 4.8)
                self.assertLess(min(distances), 1)
