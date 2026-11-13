"""Pruebas de rules.py. Correr con: python3 import-users/server/test_rules.py"""

import unittest
from pathlib import Path

from rules import ExistingUser, Regions, check_rows, normalize_name, region_key, summarize

DATA = Path(__file__).resolve().parent.parent / "data"
FLAGS = Path(__file__).resolve().parent.parent.parent / "ranking" / "flags"
REGIONS = Regions.load(DATA)
ALL = {"username", "first_name", "last_name", "password", "email", "region"}


def plain(stored, pw):
    return stored == f"plaintext:{pw}"


def run(rows, mapped=ALL, contest=True, users=None, parts=None):
    return check_rows(rows, set(mapped), contest, REGIONS, users or {}, parts or {}, plain)


def row(**kw):
    base = {"username": "jperez", "first_name": "Juan", "last_name": "Pérez",
            "password": "x1", "email": "", "region": "biobio"}
    return base | kw


JUAN = ExistingUser("Juan", "Pérez", None, "plaintext:x1")


class Normalize(unittest.TestCase):
    def test_names(self):
        self.assertEqual(normalize_name("  MARÍA  JOSÉ "), "María José")
        self.assertEqual(normalize_name("de la FUENTE   gonzález"), "De La Fuente González")
        self.assertEqual(normalize_name("o'higgins pérez-cotapos"), "O'Higgins Pérez-Cotapos")
        self.assertEqual(normalize_name("ñuñez"), "Ñuñez")

    def test_region_key(self):
        self.assertEqual(region_key("Ñuble"), "nuble")
        self.assertEqual(region_key("Los Ángeles"), "losangeles")


class Data(unittest.TestCase):
    def test_every_team_has_a_flag(self):
        flags = {p.stem for p in FLAGS.glob("*.png")}
        self.assertEqual(set(REGIONS.teams), flags)

    def test_resolve(self):
        self.assertEqual(REGIONS.resolve("biobio"), "biobio")
        self.assertEqual(REGIONS.resolve("Biobío"), "biobio")
        self.assertEqual(REGIONS.resolve("Región de Los Lagos"), "loslagos")
        self.assertEqual(REGIONS.resolve("REGIÓN DEL BIOBÍO"), "biobio")
        self.assertEqual(REGIONS.resolve("Región de la Araucanía"), "araucania")
        self.assertEqual(REGIONS.resolve("region de nuble"), "nuble")
        self.assertEqual(REGIONS.resolve("concepcion"), "biobio")
        self.assertEqual(REGIONS.resolve("Puerto Montt"), "loslagos")
        self.assertEqual(REGIONS.resolve("Santiago"), "metropolitana")
        self.assertIsNone(REGIONS.resolve("Narnia"))

    def test_conflicting_city(self):
        with self.assertRaises(ValueError):
            Regions({"a": "Uno", "b": "Dos"}, [("Uno", "b")])


class Rows(unittest.TestCase):
    def test_new_user_in_contest(self):
        [r] = run([row(first_name=" juan  PABLO ", region="Concepción")])
        self.assertEqual(r["errors"], {})
        self.assertEqual(r["values"]["first_name"], "Juan Pablo")
        self.assertEqual((r["user"], r["participation"], r["team"]), ("new", "new", "biobio"))

    def test_new_user_needs_fields(self):
        [r] = run([row(password="")], mapped={"username", "first_name", "region"})
        self.assertEqual(set(r["errors"]), {"last_name", "password"})
        [r] = run([row(password="")])
        self.assertEqual(set(r["errors"]), {"password"})

    def test_username_untouched_and_checked(self):
        [r] = run([row(username=" jperez")])
        self.assertIn("username", r["errors"])
        rs = run([row(), row()])
        self.assertTrue(all("username" in r["errors"] for r in rs))

    def test_existing_user_same_data(self):
        [r] = run([row(first_name="JUAN")], users={"jperez": JUAN})
        self.assertEqual(r["errors"], {})
        self.assertEqual((r["user"], r["participation"]), ("existing", "new"))

    def test_existing_user_only_username_and_region(self):
        [r] = run([{"username": "jperez", "region": "maule"}],
                  mapped={"username", "region"}, users={"jperez": JUAN})
        self.assertEqual(r["errors"], {})

    def test_existing_user_different_data(self):
        [r] = run([row(last_name="Soto", password="otra", email="a@b.cl")], users={"jperez": JUAN})
        self.assertEqual(set(r["errors"]), {"last_name", "password", "email"})

    def test_participation_states(self):
        parts = {"jperez": "biobio"}
        [r] = run([row()], users={"jperez": JUAN}, parts=parts)
        self.assertEqual(r["participation"], "same")
        [r] = run([row(region="maule")], users={"jperez": JUAN}, parts=parts)
        self.assertEqual((r["participation"], r["team"]), ("team", "maule"))
        [r] = run([row(region="")], users={"jperez": JUAN}, parts=parts)
        self.assertEqual((r["participation"], r["team"]), ("team", None))
        [r] = run([row()], mapped=ALL - {"region"}, users={"jperez": JUAN}, parts=parts)
        self.assertEqual((r["participation"], r["team"]), ("same", "biobio"))

    def test_unknown_region(self):
        [r] = run([row(region="Narnia")])
        self.assertIn("region", r["errors"])

    def test_no_contest_ignores_region(self):
        [r] = run([row(region="Narnia")], contest=False)
        self.assertEqual(r["errors"], {})
        self.assertIsNone(r["participation"])

    def test_summary(self):
        rs = run([row(), row(username="ana", region="")], users={"jperez": JUAN},
                 parts={"jperez": "biobio"})
        self.assertEqual(summarize(rs), {
            "rows": 2, "errors": 0, "users_created": 1, "participations_created": 1,
            "teams_changed": 0, "unchanged": 1,
        })


if __name__ == "__main__":
    unittest.main()
