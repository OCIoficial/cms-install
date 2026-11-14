"""Lectura del zip que genera `ocimatic export-cms` (cms-export.zip).

No depende de CMS, para poder probarlo sin instalarlo (test_cms_task.py).

Formato (ver `ocimatic export-cms --help`):
  contest.json             {"format_version": 1, "tasks": [codename, ...]} en el orden del problemset
  <codename>/task.json     codename, title, score_type, score_params, checker, grader, solutions
  <codename>/statement.pdf
  <codename>/tests/        <nombre>.in y <nombre>.sol
  <codename>/managers/
  <codename>/solutions/correct/ y solutions/partial/
"""

import json
import re
import zipfile
from dataclasses import dataclass
from pathlib import Path, PurePosixPath

FORMAT_VERSION = 1
LANGUAGES = ("cpp", "java", "python", "rust")
OUTCOMES = ("OK", "TLE", "WA", "FAIL")


class BundleError(Exception):
    pass


@dataclass(frozen=True)
class Solution:
    path: str
    """Relativa a la carpeta de la tarea, p. ej. `solutions/correct/a.cpp`."""
    language: str
    correct: bool
    include_in_stats: bool
    expected: dict[int, str]
    """Resultado esperado por subtarea (numeradas desde 1)."""

    @property
    def name(self) -> str:
        """Nombre para los reportes, p. ej. `correct/a.cpp`."""
        return self.path.removeprefix("solutions/")


@dataclass(frozen=True)
class Subtask:
    score: int | float
    regex: str
    """Calza (con `re.match`, como CMS) con los casos de la subtarea y de las que incluye."""


@dataclass(frozen=True)
class TaskBundle:
    directory: Path
    codename: str
    title: str
    subtasks: list[Subtask]
    checker: str | None
    """Fuente del checker, relativa a `directory`."""
    grader: str | None
    solutions: list[Solution]
    tests: list[str]
    """Nombres de los casos, sin extensión, ordenados."""

    @property
    def score_params(self) -> list[list]:
        return [[st.score, st.regex] for st in self.subtasks]

    def tests_of(self, subtask: int) -> list[str]:
        """Casos que cuentan para la subtarea `subtask` (desde 1)."""
        regex = re.compile(self.subtasks[subtask - 1].regex)
        return [t for t in self.tests if regex.match(t)]

    def managers(self) -> list[Path]:
        """Todos los archivos de managers/."""
        directory = self.directory / "managers"
        return sorted(f for f in directory.rglob("*") if f.is_file())


@dataclass(frozen=True)
class ContestBundle:
    directory: Path
    tasks: list[TaskBundle]


def extract(zip_path: Path, directory: Path) -> ContestBundle:
    """Extrae `zip_path` en `directory` (que debe existir y estar vacía) y lo valida."""
    with zipfile.ZipFile(zip_path) as zf:
        for name in zf.namelist():
            parts = PurePosixPath(name).parts
            if name.startswith("/") or ".." in parts:
                raise BundleError(f"ruta inválida en el zip: {name}")
        zf.extractall(directory)
    return load(directory)


def load(directory: Path) -> ContestBundle:
    contest = _read_json(directory / "contest.json")
    version = contest.get("format_version")
    if version != FORMAT_VERSION:
        raise BundleError(
            f"contest.json tiene format_version {version!r}, se esperaba {FORMAT_VERSION}. "
            "¿Versiones distintas de ocimatic y de cms-install?"
        )
    codenames = contest.get("tasks")
    if not isinstance(codenames, list) or not codenames:
        raise BundleError("contest.json no tiene tareas")
    if len(set(codenames)) != len(codenames):
        raise BundleError("contest.json tiene tareas repetidas")
    for codename in codenames:
        if not isinstance(codename, str) or not re.fullmatch(r"[A-Za-z0-9_-]+", codename):
            raise BundleError(f"nombre de tarea inválido: {codename!r}")
    return ContestBundle(directory, [load_task(directory / c) for c in codenames])


def load_task(directory: Path) -> TaskBundle:
    """Lee y valida la carpeta de una tarea (`<codename>/` dentro del zip)."""
    codename = directory.name
    data = _read_json(directory / "task.json")

    def fail(msg: str):
        raise BundleError(f"{codename}: {msg}")

    if data.get("codename") != codename:
        fail(f"task.json dice codename {data.get('codename')!r}")
    if data.get("score_type") != "GroupMin":
        fail(f"score_type {data.get('score_type')!r} no soportado")
    subtasks = []
    for item in data.get("score_params") or []:
        if not (
            isinstance(item, list)
            and len(item) == 2
            and isinstance(item[0], (int, float))
            and isinstance(item[1], str)
        ):
            fail(f"score_params inválido: {item!r}")
        subtasks.append(Subtask(item[0], item[1]))
    if not subtasks:
        fail("no tiene subtareas")

    for key in ("checker", "grader"):
        if data.get(key) is not None and not (directory / data[key]).is_file():
            fail(f"falta el {key} {data[key]}")

    tests_dir = directory / "tests"
    inputs = {f.stem for f in tests_dir.glob("*.in")}
    outputs = {f.stem for f in tests_dir.glob("*.sol")}
    if inputs != outputs:
        fail(f"casos sin entrada o sin salida: {', '.join(sorted(inputs ^ outputs))}")
    tests = sorted(inputs)
    if not tests:
        fail("no tiene casos")

    solutions = [_load_solution(directory, len(subtasks), s, fail) for s in data.get("solutions") or []]
    if not any(s.correct and s.include_in_stats for s in solutions):
        fail("ninguna solución correcta cuenta para el límite de tiempo (include_in_stats)")

    task = TaskBundle(
        directory=directory,
        codename=codename,
        title=data.get("title") or codename,
        subtasks=subtasks,
        checker=data.get("checker"),
        grader=data.get("grader"),
        solutions=solutions,
        tests=tests,
    )
    for i in range(1, len(subtasks) + 1):
        if not task.tests_of(i):
            fail(f"la subtarea {i} no tiene casos (regex {subtasks[i - 1].regex!r})")
    return task


def _load_solution(directory: Path, num_subtasks: int, data: dict, fail) -> Solution:
    path = data.get("path")
    if not isinstance(path, str) or not (directory / path).is_file():
        fail(f"falta la solución {path!r}")
    if data.get("language") not in LANGUAGES:
        fail(f"{path}: lenguaje {data.get('language')!r} no soportado")
    expected = {int(k): v for k, v in (data.get("expected") or {}).items()}
    if set(expected) != set(range(1, num_subtasks + 1)) or not set(expected.values()) <= set(OUTCOMES):
        fail(f"{path}: resultado esperado inválido: {data.get('expected')!r}")
    return Solution(
        path=path,
        language=data["language"],
        correct=bool(data.get("correct")),
        include_in_stats=bool(data.get("include_in_stats")),
        expected=expected,
    )


def _read_json(path: Path) -> dict:
    try:
        return json.loads(path.read_text())
    except FileNotFoundError:
        raise BundleError(f"falta {path.name}") from None
    except json.JSONDecodeError as e:
        raise BundleError(f"{path.name} no es JSON válido: {e}") from None
