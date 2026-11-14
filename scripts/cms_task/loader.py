"""Loader de CMS para una tarea exportada con `ocimatic export-cms`.

Sigue la interfaz de los loaders de cmscontrib (TaskLoader), como el de TPS, para
que se pueda usar con TaskImporter/DatasetImporter o proponer a CMS más adelante.
CMS no carga loaders externos (la lista de cmscontrib/loaders/__init__.py es fija),
así que cms-task lo usa directamente.
"""

import logging
import subprocess
import tempfile
from pathlib import Path

from cms import FEEDBACK_LEVEL_FULL
from cms.db import Dataset, Manager, Statement, Task, Testcase
from cms.db.filecacher import FileCacher
from cms.grading.languagemanager import HEADER_EXTS
from cmscommon.constants import SCORE_MODE_MAX_SUBTASK
from cmscontrib.loaders.base_loader import TaskLoader

from .bundle import BundleError, TaskBundle, load_task

logger = logging.getLogger(__name__)

MEMORY_LIMIT_MIB = 256
STATEMENT_LANGUAGE = "es"


class OcimaticTaskLoader(TaskLoader):
    short_name = "ocimatic"
    description = "Tarea exportada con `ocimatic export-cms` (una carpeta de cms-export.zip)"

    def __init__(
        self,
        path: str,
        file_cacher: FileCacher,
        *,
        dataset_description: str = "ocimatic",
        time_limit: float = 1.0,
    ):
        super().__init__(path, file_cacher)
        self.dataset_description = dataset_description
        self.time_limit = time_limit
        self.bundle: TaskBundle = load_task(Path(path))

    @staticmethod
    def detect(path: str) -> bool:
        return (Path(path) / "task.json").is_file() and (Path(path) / "tests").is_dir()

    def task_has_changed(self) -> bool:
        return True

    def get_task(self, get_statement: bool = True) -> Task:
        """Arma la tarea con un solo dataset, el activo. Falla con BundleError."""
        b = self.bundle
        task = Task(
            name=b.codename,
            title=b.title,
            submission_format=[f"{b.codename}.%l"],
            score_mode=SCORE_MODE_MAX_SUBTASK,
            feedback_level=FEEDBACK_LEVEL_FULL,
        )
        if get_statement:
            task.statements = {STATEMENT_LANGUAGE: self.get_statement()}
            task.primary_statements = [STATEMENT_LANGUAGE]
        task.active_dataset = self.get_dataset(task)
        return task

    def get_statement(self) -> Statement:
        digest = self.file_cacher.put_file_from_path(
            str(self.bundle.directory / "statement.pdf"),
            f"Statement for task {self.bundle.codename}",
        )
        return Statement(language=STATEMENT_LANGUAGE, digest=digest)

    def get_dataset(self, task: Task) -> Dataset:
        b = self.bundle
        managers = {}
        if b.checker is not None:
            managers["checker"] = Manager(filename="checker", digest=self._compile_checker())
        if b.grader is not None:
            # El grader y los headers que incluyen el grader o las soluciones
            for f in b.managers():
                if f.name == "grader.cpp" or f.suffix in HEADER_EXTS:
                    managers[f.name] = Manager(filename=f.name, digest=self._put(f, "Manager"))

        testcases = {}
        for name in b.tests:
            testcases[name] = Testcase(
                codename=name,
                public=True,
                input=self._put(b.directory / "tests" / f"{name}.in", "Input"),
                output=self._put(b.directory / "tests" / f"{name}.sol", "Output"),
            )

        return Dataset(
            task=task,
            description=self.dataset_description,
            autojudge=False,
            time_limit=self.time_limit,
            memory_limit=MEMORY_LIMIT_MIB * 1024 * 1024,
            task_type="Batch",
            task_type_parameters=[
                "grader" if b.grader is not None else "alone",
                ["", ""],  # entrada y salida estándar
                "comparator" if b.checker is not None else "diff",
            ],
            score_type="GroupMin",
            score_type_parameters=b.score_params,
            managers=managers,
            testcases=testcases,
        )

    def _put(self, path: Path, what: str) -> str:
        return self.file_cacher.put_file_from_path(
            str(path), f"{what} {path.name} for task {self.bundle.codename}"
        )

    def _compile_checker(self) -> str:
        """Compila el checker y lo guarda en CMS. CMS no compila checkers: usa el binario."""
        b = self.bundle
        source = b.directory / b.checker
        if source.suffix != ".cpp":
            raise BundleError(f"{b.codename}: solo se soportan checkers en C++, no {b.checker}")
        logger.info("%s: compilando el checker", b.codename)
        with tempfile.TemporaryDirectory() as tmp:
            binary = Path(tmp) / "checker"
            # Igual que el loader de TPS. -I managers: ahí está testlib.h, como en ocimatic
            cmd = [
                "g++", "-x", "c++", "-std=gnu++20", "-O2", "-static",
                "-I", str(b.directory / "managers"), "-o", str(binary), str(source),
            ]  # fmt: skip
            result = subprocess.run(cmd, capture_output=True, text=True)
            if result.returncode != 0:
                raise BundleError(f"{b.codename}: el checker no compila:\n{result.stderr}")
            return self.file_cacher.put_file_from_path(
                str(binary), f"Checker for task {b.codename}"
            )
