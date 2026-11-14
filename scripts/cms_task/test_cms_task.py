"""Pruebas de bundle.py y outcomes.py (no necesitan CMS).

Correr desde la raíz del repo: python3 -m unittest discover -s scripts/cms_task -t scripts
"""

import json
import tempfile
import unittest
import zipfile
from pathlib import Path

from cms_task import outcomes
from cms_task.bundle import BundleError, extract
from cms_task.outcomes import ERROR, OK, TIMEOUT, WRONG, SolutionResult, TestResult


def solution(path, *, correct=True, stats=True, expected=None, language="cpp"):
    return {
        "path": path,
        "language": language,
        "correct": correct,
        "include_in_stats": stats,
        "expected": expected or {"1": "OK", "2": "OK"},
    }


def task_json(**kw):
    base = {
        "codename": "suma",
        "title": "Suma",
        "score_type": "GroupMin",
        "score_params": [[30, "st1-.*"], [70, "(st1|st2)-.*"]],
        "checker": None,
        "grader": None,
        "solutions": [
            solution("solutions/correct/suma.cpp"),
            solution(
                "solutions/partial/lenta.py",
                correct=False,
                stats=False,
                expected={"1": "OK", "2": "TLE"},
                language="python",
            ),
        ],
    }
    return base | kw


def write_zip(path: Path, task: dict, contest: dict | None = None, extra: dict | None = None):
    files = {
        "contest.json": json.dumps(contest or {"format_version": 1, "tasks": ["suma"]}),
        "suma/task.json": json.dumps(task),
        "suma/statement.pdf": "%PDF",
        "suma/tests/st1-a.in": "1 2\n",
        "suma/tests/st1-a.sol": "3\n",
        "suma/tests/st2-b.in": "10 20\n",
        "suma/tests/st2-b.sol": "30\n",
        "suma/solutions/correct/suma.cpp": "int main() {}\n",
        "suma/solutions/partial/lenta.py": "print(3)\n",
    } | (extra or {})
    with zipfile.ZipFile(path, "w") as zf:
        for name, content in files.items():
            zf.writestr(name, content)


class Bundle(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.zip = self.tmp / "cms-export.zip"
        self.out = self.tmp / "out"
        self.out.mkdir()

    def tearDown(self):
        self._tmp.cleanup()

    def load(self, task=None, **kw):
        write_zip(self.zip, task or task_json(), **kw)
        return extract(self.zip, self.out)

    def assertFails(self, msg, task=None, **kw):
        with self.assertRaises(BundleError) as cm:
            self.load(task, **kw)
        self.assertIn(msg, str(cm.exception))

    def test_loads_task(self):
        [task] = self.load().tasks
        self.assertEqual(task.codename, "suma")
        self.assertEqual(task.tests, ["st1-a", "st2-b"])
        self.assertEqual(task.tests_of(1), ["st1-a"])
        self.assertEqual(task.tests_of(2), ["st1-a", "st2-b"])
        self.assertEqual(task.score_params, [[30, "st1-.*"], [70, "(st1|st2)-.*"]])
        self.assertEqual(task.solutions[1].name, "partial/lenta.py")
        self.assertEqual(task.solutions[1].expected, {1: "OK", 2: "TLE"})

    def test_rejects_other_format_version(self):
        self.assertFails("format_version", contest={"format_version": 2, "tasks": ["suma"]})

    def test_rejects_paths_outside_the_zip(self):
        self.assertFails("ruta inválida", extra={"../malo.txt": "x"})

    def test_rejects_test_without_output(self):
        self.assertFails("st3-c", extra={"suma/tests/st3-c.in": "1\n"})

    def test_rejects_subtask_without_tests(self):
        self.assertFails(
            "subtarea 2 no tiene casos",
            task_json(score_params=[[30, "st1-.*"], [70, "st9-.*"]]),
        )

    def test_rejects_missing_solution(self):
        self.assertFails(
            "falta la solución",
            task_json(solutions=[solution("solutions/correct/otra.cpp")]),
        )

    def test_rejects_incomplete_expected_outcome(self):
        self.assertFails(
            "resultado esperado inválido",
            task_json(solutions=[solution("solutions/correct/suma.cpp", expected={"1": "OK"})]),
        )

    def test_requires_a_solution_for_the_time_limit(self):
        self.assertFails(
            "include_in_stats",
            task_json(solutions=[solution("solutions/correct/suma.cpp", stats=False)]),
        )

    def test_rejects_missing_checker(self):
        self.assertFails("falta el checker", task_json(checker="managers/checker.cpp"))


class Outcomes(unittest.TestCase):
    def test_classify(self):
        self.assertEqual(outcomes.classify("1.0", ["Output is correct"]), OK)
        self.assertEqual(outcomes.classify("0.0", ["Output isn't correct"]), WRONG)
        # Con checker, el mensaje es del checker: manda el puntaje
        self.assertEqual(outcomes.classify("0.0", ["Respuesta incorrecta en la línea 2"]), WRONG)
        self.assertEqual(outcomes.classify("0.5", ["Output is partially correct"]), WRONG)
        self.assertEqual(outcomes.classify("0.0", ["Execution timed out"]), TIMEOUT)
        self.assertEqual(
            outcomes.classify("0.0", ["Execution timed out (wall clock limit exceeded)"]), TIMEOUT
        )
        self.assertEqual(outcomes.classify("0.0", ["Execution killed by signal"]), ERROR)
        self.assertEqual(outcomes.classify("0.0", ["Memory limit exceeded"]), ERROR)

    def test_matches_follows_ocimatic(self):
        self.assertTrue(outcomes.matches("OK", [OK, OK]))
        self.assertFalse(outcomes.matches("OK", [OK, TIMEOUT]))
        self.assertTrue(outcomes.matches("TLE", [OK, TIMEOUT]))
        self.assertFalse(outcomes.matches("TLE", [OK, OK]))
        self.assertFalse(outcomes.matches("TLE", [TIMEOUT, WRONG]))
        self.assertTrue(outcomes.matches("WA", [WRONG, OK]))
        self.assertFalse(outcomes.matches("WA", [WRONG, ERROR]))
        self.assertTrue(outcomes.matches("FAIL", [OK, ERROR]))
        self.assertFalse(outcomes.matches("FAIL", [OK, OK]))

    def test_time_limit(self):
        self.assertEqual(outcomes.time_limit(0.512), 1.5)
        self.assertEqual(outcomes.time_limit(0.25), 0.5)
        self.assertEqual(outcomes.time_limit(1.01), 2.5)
        self.assertEqual(outcomes.time_limit(0.0), 0.5)


class Report(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        tmp = Path(self._tmp.name)
        write_zip(tmp / "c.zip", task_json())
        (tmp / "out").mkdir()
        [self.task] = extract(tmp / "c.zip", tmp / "out").tasks

    def tearDown(self):
        self._tmp.cleanup()

    def result(self, a, b, time_a=0.1, time_b=0.2):
        return SolutionResult(
            compiled=True,
            tests={"st1-a": TestResult(a, time_a), "st2-b": TestResult(b, time_b)},
        )

    def test_max_stats_time_ignores_other_solutions(self):
        results = {
            "solutions/correct/suma.cpp": self.result(OK, OK, 0.1, 0.3),
            "solutions/partial/lenta.py": self.result(OK, TIMEOUT, 0.1, 9.0),
        }
        self.assertEqual(outcomes.max_stats_time(self.task, results), (0.3, "correct/suma.cpp"))

    def test_max_stats_time_fails_if_a_correct_solution_fails(self):
        results = {"solutions/correct/suma.cpp": self.result(OK, WRONG)}
        with self.assertRaisesRegex(ValueError, "falla en 1 casos"):
            outcomes.max_stats_time(self.task, results)

    def test_check_task_marks_differences(self):
        results = {
            "solutions/correct/suma.cpp": self.result(OK, OK),
            "solutions/partial/lenta.py": self.result(OK, OK, 0.1, 0.4),
        }
        lines, errors = outcomes.check_task(self.task, results)
        self.assertEqual(errors, ["partial/lenta.py: subtarea 2 dio OK, se esperaba TLE"])
        self.assertEqual(
            lines,
            [
                "solución          st1  st2  tiempo",
                "correct/suma.cpp  OK   OK   0.200s",
                "partial/lenta.py  OK   OK*  0.400s",
            ],
        )

    def test_check_task_reports_compilation_errors(self):
        results = {
            "solutions/correct/suma.cpp": SolutionResult(compiled=False),
            "solutions/partial/lenta.py": self.result(OK, TIMEOUT),
        }
        lines, errors = outcomes.check_task(self.task, results)
        self.assertEqual(errors, ["correct/suma.cpp: no compiló"])
        self.assertIn("no compiló", lines[1])


if __name__ == "__main__":
    unittest.main()
