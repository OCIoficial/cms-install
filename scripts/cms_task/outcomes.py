"""Resultados de las soluciones: clasificación de cada caso, comparación con lo
esperado por ocimatic y cálculo del límite de tiempo.

No depende de CMS, para poder probarlo sin instalarlo (test_cms_task.py).
"""

import math
from dataclasses import dataclass, field

from .bundle import TaskBundle

# Estado de un caso
OK = "ok"
WRONG = "wa"
TIMEOUT = "tle"
ERROR = "fail"  # error de ejecución, memoria, sin salida, etc.

# Mensajes de CMS (Evaluation.text[0]) cuando la solución no terminó bien
# (cms/grading/steps/evaluation.py)
_TIMEOUT_TEXTS = {
    "Execution timed out",
    "Execution timed out (wall clock limit exceeded)",
}
_ERROR_TEXTS = {
    "Evaluation didn't produce file %s",
    "Memory limit exceeded",
    "Execution killed by signal",
    "Execution failed because the return code was nonzero",
}


def classify(outcome: str | float | None, text: list[str] | None) -> str:
    """Estado de un caso a partir de Evaluation.outcome y Evaluation.text de CMS.

    Si la solución terminó bien, el mensaje es el del checker (o el de diff), así que el
    estado sale del puntaje: 1 es correcto y cualquier otro valor es respuesta incorrecta.
    """
    message = text[0] if text else ""
    if message in _TIMEOUT_TEXTS:
        return TIMEOUT
    if message in _ERROR_TEXTS:
        return ERROR
    try:
        score = float(outcome) if outcome is not None else 0.0
    except ValueError:
        return ERROR
    return OK if score == 1.0 else WRONG


@dataclass(frozen=True)
class TestResult:
    status: str
    time: float | None
    """Tiempo de CPU en segundos (Evaluation.execution_time)."""


@dataclass
class SolutionResult:
    """Resultados de una solución en un dataset."""

    compiled: bool
    tests: dict[str, TestResult] = field(default_factory=dict)
    """Por nombre de caso. Vacío si no compiló."""

    def max_time(self, tests: list[str] | None = None) -> float | None:
        times = [
            r.time
            for name, r in self.tests.items()
            if (tests is None or name in tests) and r.status == OK and r.time is not None
        ]
        return max(times, default=None)


def summarize(statuses: list[str]) -> str:
    """Resultado de una subtarea para mostrar: OK, TLE, WA o FAIL (mezcla o error)."""
    failed = {s for s in statuses if s != OK}
    if not failed:
        return "OK"
    if failed == {TIMEOUT}:
        return "TLE"
    if failed == {WRONG}:
        return "WA"
    return "FAIL"


def matches(expected: str, statuses: list[str]) -> bool:
    """Si los estados de los casos de una subtarea calzan con el resultado esperado.

    Mismas reglas que ocimatic (`Outcome.validate_results`).
    """
    match expected:
        case "OK":
            return all(s == OK for s in statuses)
        case "TLE":
            return all(s in (OK, TIMEOUT) for s in statuses) and TIMEOUT in statuses
        case "WA":
            return all(s in (OK, WRONG) for s in statuses) and WRONG in statuses
        case "FAIL":
            return any(s != OK for s in statuses)
    raise ValueError(f"resultado esperado desconocido: {expected}")


def time_limit(max_time: float) -> float:
    """Límite de tiempo a partir del tiempo máximo de las soluciones correctas.

    La misma fórmula que ocimatic (`RuntimeStats.set_limit`). Como mínimo 0.5 s: si todas
    las soluciones tardan 0 s (CMS mide en milisegundos), la fórmula da 0, y CMS no acepta un
    límite de 0.
    """
    return max(math.ceil(max_time * 4) / 2, 0.5)


def max_stats_time(task: TaskBundle, results: dict[str, SolutionResult]) -> tuple[float, str]:
    """Tiempo máximo de las soluciones correctas que cuentan para el límite, y cuál fue.

    Lanza ValueError si alguna no compiló o no resolvió todos los casos: con un límite
    holgado, una solución correcta debe resolverlos todos.
    """
    best: tuple[float, str] = (0.0, "")
    for sol in task.solutions:
        if not (sol.correct and sol.include_in_stats):
            continue
        result = results[sol.path]
        if not result.compiled:
            raise ValueError(f"{sol.name} no compiló")
        failed = [name for name in task.tests if result.tests[name].status != OK]
        if failed:
            raise ValueError(
                f"{sol.name} falla en {len(failed)} casos (p. ej. {failed[0]}) con un límite holgado"
            )
        time = result.max_time() or 0.0
        if time >= best[0]:
            best = (time, sol.name)
    return best


def check_task(task: TaskBundle, results: dict[str, SolutionResult]) -> tuple[list[str], list[str]]:
    """Compara los resultados con lo esperado. Devuelve las líneas de la tabla y los errores.

    En la tabla, cada subtarea muestra el resultado obtenido; un `*` marca las que no
    calzan con lo esperado.
    """
    header = ["solución"] + [f"st{i}" for i in range(1, len(task.subtasks) + 1)] + ["tiempo"]
    rows = [header]
    errors = []
    for sol in task.solutions:
        result = results[sol.path]
        if not result.compiled:
            rows.append([sol.name] + ["-"] * len(task.subtasks) + ["no compiló"])
            errors.append(f"{sol.name}: no compiló")
            continue
        row = [sol.name]
        for i in range(1, len(task.subtasks) + 1):
            statuses = [result.tests[name].status for name in task.tests_of(i)]
            got = summarize(statuses)
            if matches(sol.expected[i], statuses):
                row.append(got)
            else:
                row.append(got + "*")
                errors.append(f"{sol.name}: subtarea {i} dio {got}, se esperaba {sol.expected[i]}")
        time = result.max_time()
        row.append("-" if time is None else f"{time:.3f}s")
        rows.append(row)

    widths = [max(len(r[c]) for r in rows) for c in range(len(header))]
    lines = ["  ".join(cell.ljust(w) for cell, w in zip(r, widths, strict=True)).rstrip() for r in rows]
    return lines, errors
