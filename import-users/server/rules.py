"""Reglas del importador de usuarios, sin dependencias de CMS (se prueban con
test_rules.py en cualquier máquina).

Cada fila pegada llega como un dict {campo: texto} con solo los campos que se
asignaron a una columna. check_rows normaliza y valida las filas contra lo que
ya hay en la base de datos (que app.py le pasa ya consultado).
"""

import csv
import re
import unicodedata
from collections import Counter
from collections.abc import Callable, Iterable
from dataclasses import dataclass
from pathlib import Path

FIELDS = ("username", "first_name", "last_name", "password", "email", "region")
NEW_USER_FIELDS = ("first_name", "last_name", "password")

# Lo que acepta el tipo Codename de CMS (usernames y códigos de equipo)
CODENAME = re.compile(r"^[A-Za-z0-9_-]+$")

# Tramos de letras (con tilde, ñ, etc.): "o'HIGGINS-pérez" → O, HIGGINS, pérez
_LETTERS = re.compile(r"[^\W\d_]+")


def normalize_name(text: str) -> str:
    """Quita espacios sobrantes y pone mayúscula inicial a cada palabra."""
    text = " ".join(text.split())
    return _LETTERS.sub(lambda m: m[0][:1].upper() + m[0][1:].lower(), text)


def _words(text: str) -> list[str]:
    """Palabras en minúscula y sin tildes ni signos."""
    text = unicodedata.normalize("NFKD", text)
    text = "".join(c for c in text if not unicodedata.combining(c))
    return re.findall(r"[a-z0-9]+", text.lower())


def region_key(text: str) -> str:
    """Clave para comparar regiones y ciudades: sin tildes, mayúsculas,
    espacios ni signos. "Los Ángeles" → "losangeles"."""
    return "".join(_words(text))


def _region_candidates(text: str) -> list[str]:
    """Claves a probar, quitando de a poco un prefijo "Región de (los)...":
    "Región de Los Lagos" → regiondeloslagos, deloslagos, loslagos, lagos."""
    words = _words(text)
    keys = ["".join(words)]
    if words[:1] == ["region"]:
        words = words[1:]
        keys.append("".join(words))
        while words[:1] and words[0] in ("de", "del", "la", "los", "las"):
            words = words[1:]
            keys.append("".join(words))
    return keys


class Regions:
    """Traduce lo que viene en la columna de región a un código de equipo.

    Acepta el código ("biobio"), el nombre del equipo ("Biobío") o una ciudad
    de cities.csv ("Concepción"), sin importar tildes ni mayúsculas.
    """

    def __init__(self, teams: dict[str, str], cities: Iterable[tuple[str, str]]):
        self.teams = teams  # código → nombre
        self._lookup: dict[str, str] = {}
        for code, name in teams.items():
            if not CODENAME.match(code):
                raise ValueError(f"Código de equipo inválido: {code!r}")
            self._add(code, code)
            self._add(name, code)
        for city, code in cities:
            if code not in teams:
                raise ValueError(f"Ciudad {city!r} con equipo desconocido {code!r}")
            self._add(city, code)

    def _add(self, text: str, code: str):
        key = region_key(text)
        if not key:
            raise ValueError(f"Nombre vacío para el equipo {code!r}")
        if self._lookup.get(key, code) != code:
            raise ValueError(
                f"{text!r} corresponde a dos equipos: {self._lookup[key]!r} y {code!r}")
        self._lookup[key] = code

    def resolve(self, text: str) -> str | None:
        for key in _region_candidates(text):
            if key in self._lookup:
                return self._lookup[key]
        return None

    @classmethod
    def load(cls, data_dir: Path) -> "Regions":
        with open(data_dir / "teams.csv", newline="", encoding="utf-8") as f:
            teams = {r["code"]: r["name"] for r in csv.DictReader(f)}
        with open(data_dir / "cities.csv", newline="", encoding="utf-8") as f:
            cities = [(r["city"], r["team"]) for r in csv.DictReader(f)]
        return cls(teams, cities)


@dataclass
class ExistingUser:
    first_name: str
    last_name: str
    email: str | None
    password: str  # como lo guarda CMS, p. ej. "plaintext:abc"


# Estado de la participación en el concurso elegido
NO_TEAM = None
MISSING = object()


def check_rows(
    rows: list[dict[str, str]],
    mapped: set[str],
    with_contest: bool,
    regions: Regions,
    users: dict[str, ExistingUser],
    participations: dict[str, str | None],
    password_matches: Callable[[str, str], bool],
) -> list[dict]:
    """Normaliza y valida las filas.

    users: los usuarios que ya existen, por username.
    participations: username → código del equipo (o None) de los que ya están
        en el concurso elegido.
    password_matches(guardada, pegada): si la contraseña pegada es la de CMS.

    Devuelve, por fila:
      values: los valores normalizados (solo de los campos asignados)
      errors: campo → mensaje
      user: "new" | "existing"
      participation: None (sin concurso) | "new" | "team" (cambia el equipo)
                     | "same" (ya está, sin cambios)
      team: código del equipo, o None
    """
    usernames = Counter(r.get("username", "") for r in rows)
    results = []
    for row in rows:
        values: dict[str, str] = {}
        errors: dict[str, str] = {}

        username = row.get("username", "")
        values["username"] = username
        if not username:
            errors["username"] = "Required"
        elif not CODENAME.match(username):
            errors["username"] = "Only letters (a-z, A-Z), digits, _ and - are allowed"
        elif usernames[username] > 1:
            errors["username"] = "Repeated in the pasted rows"

        for field in ("first_name", "last_name"):
            if field in mapped:
                values[field] = normalize_name(row.get(field, ""))
        if "password" in mapped:
            values["password"] = row.get("password", "")
        if "email" in mapped:
            values["email"] = row.get("email", "").strip()
            if values["email"] and "@" not in values["email"]:
                errors["email"] = "Not an email address"

        existing = users.get(username)
        if existing is not None:
            # Una celda vacía no se compara: solo se quiere agregar al concurso
            for field in ("first_name", "last_name"):
                stored = getattr(existing, field)
                if values.get(field) and values[field] != stored:
                    errors[field] = f"Differs from CMS: “{stored}”"
            if values.get("password") and not password_matches(
                existing.password, values["password"]
            ):
                errors["password"] = "Differs from the password in CMS"
            if values.get("email") and values["email"] != (existing.email or ""):
                errors["email"] = f"Differs from CMS: “{existing.email or ''}”"
        else:
            for field in NEW_USER_FIELDS:
                if field not in mapped:
                    errors.setdefault(field, "New user: assign a column to this field")
                elif not values[field]:
                    errors.setdefault(field, "Required for new users")

        team = NO_TEAM
        participation = None
        if with_contest:
            if "region" in mapped:
                raw = row.get("region", "").strip()
                values["region"] = raw
                if raw:
                    team = regions.resolve(raw)
                    if team is None:
                        errors["region"] = "Unknown region or city"
            current = participations.get(username, MISSING)
            if current is MISSING:
                participation = "new"
            elif "region" in mapped and current != team:
                participation = "team"
            else:
                participation = "same"
                team = current

        results.append({
            "values": values,
            "errors": errors,
            "user": "existing" if existing is not None else "new",
            "participation": participation,
            "team": team,
        })
    return results


def summarize(results: list[dict]) -> dict[str, int]:
    return {
        "rows": len(results),
        "errors": sum(1 for r in results if r["errors"]),
        "users_created": sum(1 for r in results if r["user"] == "new"),
        "participations_created": sum(1 for r in results if r["participation"] == "new"),
        "teams_changed": sum(1 for r in results if r["participation"] == "team"),
        "unchanged": sum(
            1 for r in results
            if r["user"] == "existing" and r["participation"] in (None, "same")
        ),
    }
