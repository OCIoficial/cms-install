"""Importa a CMS un concurso exportado con `ocimatic export-cms` y fija el límite de
tiempo de cada tarea midiendo sus soluciones en los workers.

1. Por cada tarea arma un dataset nuevo (loader.py). Si la tarea no existe, la crea con
   ese dataset; si existe, se lo agrega sin activarlo (con autojudge, para que CMS lo
   evalúe). Todo en una transacción: si algo falla aquí, no cambia nada.
2. Envía las soluciones correctas que cuentan para el límite como el usuario `tester`
   (participación oculta, no sale en el ranking), con un límite holgado.
3. Calcula el límite con la fórmula de ocimatic, lo fija, reevalúa esas soluciones y
   envía las demás.
4. Compara cada subtarea con lo esperado. Si todo calza en todas las tareas, activa los
   datasets nuevos, borra los antiguos y actualiza título, enunciado y orden. Si no,
   borra lo creado y el concurso queda como estaba.
"""

import secrets
import sys
import tempfile
import time
import traceback
from contextlib import contextmanager
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path

from cms import ServiceCoord, get_service_address, get_service_shards
from cms.db import (
    Contest,
    Dataset,
    File,
    Participation,
    SessionGen,
    Submission,
    SubmissionResult,
    Task,
    User,
)
from cms.db.filecacher import FileCacher
from cms.io import RemoteServiceClient
from cmscommon.crypto import build_password
from cmscommon.datetime import make_datetime

from . import outcomes
from .bundle import BundleError, ContestBundle, Solution, extract
from .loader import OcimaticTaskLoader

TESTER = "tester"
# Límite con que se miden las soluciones correctas, antes de conocer el límite real
MEASURE_TIME_LIMIT = 10.0
LANGUAGES = {
    "cpp": "C++20 / g++",
    "java": "Java / JDK",
    "python": "Python 3 / CPython",
}
# Intentos de CMS antes de rendirse con un envío (cms/service/esoperations.py)
MAX_TRIES = 3
POLL_SECONDS = 3
PROGRESS_SECONDS = 30
WAIT_TIMEOUT_SECONDS = 3 * 3600


class ImportFailed(Exception):
    pass


def say(msg: str = "") -> None:
    print(msg, flush=True)


@dataclass
class TaskState:
    loader: OcimaticTaskLoader
    task_id: int
    dataset_id: int
    created: bool
    """La tarea no existía: se borra entera si la importación falla."""
    submissions: dict[str, int] = field(default_factory=dict)
    """Id del envío de cada solución (por `Solution.path`)."""
    time_limit: float | None = None

    @property
    def bundle(self):
        return self.loader.bundle


def run(zip_path: Path, contest_id: int) -> bool:
    """Importa el concurso. Devuelve si todo salió bien."""
    with tempfile.TemporaryDirectory(prefix="cms-task-") as tmp:
        try:
            contest = extract(zip_path, Path(tmp))
        except BundleError as e:
            say(f"ERROR en {zip_path.name}: {e}")
            return False
        say(f"Tareas: {', '.join(t.codename for t in contest.tasks)}")
        try:
            check_workers()
            states = create(contest, contest_id)
        except (BundleError, ImportFailed) as e:
            say(f"ERROR: {e}")
            say("No se hizo ningún cambio en CMS.")
            return False
        except Exception:
            # create() escribe en una sola transacción: si falla, no queda nada
            traceback.print_exc(file=sys.stdout)
            say("No se hizo ningún cambio en CMS.")
            return False

        try:
            ok = measure(states)
        except ImportFailed as e:
            say(f"ERROR: {e}")
            ok = False
        except BaseException:
            say("ERROR inesperado; se deshacen los cambios")
            rollback(states)
            raise
        if not ok:
            rollback(states)
            say("No se hizo ningún cambio en CMS.")
            return False

        finalize(contest, contest_id, states)
        return True


def main_ip() -> str:
    return get_service_address(ServiceCoord("EvaluationService", 0)).ip


def main_worker_shards() -> set[int]:
    """Shards de los workers que corren en la principal."""
    ip = main_ip()
    return {
        shard
        for shard in range(get_service_shards("Worker"))
        if get_service_address(ServiceCoord("Worker", shard)).ip == ip
    }


def check_workers() -> None:
    if len(main_worker_shards()) == get_service_shards("Worker"):
        raise ImportFailed(
            "los envíos los evalúa la principal (workers_running = false), así que los "
            "tiempos no sirven. Encender los workers (workers_running = true y terraform apply)."
        )


# ---------------------------------------------------------------------------
# 1. Crear tareas y datasets
# ---------------------------------------------------------------------------


def create(contest_bundle: ContestBundle, contest_id: int) -> list[TaskState]:
    description = f"ocimatic {datetime.now():%Y-%m-%d %H:%M:%S}"
    file_cacher = FileCacher()
    loaders = [
        OcimaticTaskLoader(
            str(t.directory),
            file_cacher,
            dataset_description=description,
            time_limit=MEASURE_TIME_LIMIT,
        )
        for t in contest_bundle.tasks
    ]
    for loader in loaders:
        for sol in loader.bundle.solutions:
            if sol.language not in LANGUAGES:
                raise BundleError(
                    f"{loader.bundle.codename}: {sol.name}: los workers no tienen {sol.language}"
                )

    with SessionGen() as session:
        contest = Contest.get_from_id(contest_id, session)
        if contest is None:
            raise ImportFailed(f"no existe el concurso {contest_id}")
        tester_participation(session, contest)

        pending = []
        for loader in loaders:
            b = loader.bundle
            task = session.query(Task).filter(Task.name == b.codename).first()
            if task is not None and task.contest_id != contest.id:
                raise ImportFailed(f"la tarea {b.codename} ya existe en otro concurso (o sin concurso)")
            if task is None:
                say(f"{b.codename}: tarea nueva")
                task = loader.get_task()
                task.contest = contest
                session.add(task)
                dataset = task.active_dataset
            else:
                say(f"{b.codename}: la tarea ya existe; se mide en un dataset nuevo")
                dataset = loader.get_dataset(task)
                # CMS solo evalúa el dataset activo y los que tienen autojudge
                dataset.autojudge = True
            pending.append((loader, task, dataset))

        session.flush()
        states = [
            TaskState(loader, task.id, dataset.id, created=task.active_dataset is dataset)
            for loader, task, dataset in pending
        ]
        session.commit()
    return states


def tester_participation(session, contest: Contest) -> Participation:
    """Participación oculta y sin restricciones del usuario `tester` en el concurso."""
    user = session.query(User).filter(User.username == TESTER).first()
    if user is None:
        user = User(
            username=TESTER,
            first_name="Tester",
            last_name="ocimatic",
            password=build_password(secrets.token_urlsafe(16)),
        )
        session.add(user)
    participation = (
        session.query(Participation)
        .filter(Participation.contest_id == contest.id, Participation.user_id == user.id)
        .first()
        if user.id is not None
        else None
    )
    if participation is None:
        participation = Participation(contest=contest, user=user, group=contest.main_group)
        session.add(participation)
    participation.hidden = True
    participation.unrestricted = True
    session.flush()
    return participation


# ---------------------------------------------------------------------------
# 2 y 3. Envíos y medición
# ---------------------------------------------------------------------------


def measure(states: list[TaskState]) -> bool:
    say()
    say(f"== Midiendo las soluciones correctas (límite provisorio de {MEASURE_TIME_LIMIT:g} s)")
    stats = {
        s.bundle.codename: [sol for sol in s.bundle.solutions if sol.correct and sol.include_in_stats]
        for s in states
    }
    submit(states, stats)
    wait(states, stats)

    ok = True
    for s in states:
        results = collect(s, stats[s.bundle.codename])
        try:
            max_time, name = outcomes.max_stats_time(s.bundle, results)
        except ValueError as e:
            say(f"{s.bundle.codename}: ERROR: {e}")
            ok = False
            continue
        s.time_limit = outcomes.time_limit(max_time)
        say(f"{s.bundle.codename}: límite {s.time_limit:g} s (máximo {max_time:.3f} s, {name})")
    if not ok:
        return False

    say()
    say("== Evaluando todas las soluciones con el límite final")
    with SessionGen() as session:
        for s in states:
            Dataset.get_from_id(s.dataset_id, session).time_limit = s.time_limit
        session.commit()
    # Las ya medidas se reevalúan con el límite final; las demás se envían ahora
    with service("EvaluationService") as es:
        for s in states:
            for sol in stats[s.bundle.codename]:
                es.invalidate_submission(
                    submission_id=s.submissions[sol.path],
                    dataset_id=s.dataset_id,
                    level="evaluation",
                ).get(timeout=60)
    rest = {
        s.bundle.codename: [sol for sol in s.bundle.solutions if sol not in stats[s.bundle.codename]]
        for s in states
    }
    submit(states, rest)
    everything = {s.bundle.codename: s.bundle.solutions for s in states}
    wait(states, everything)

    say()
    for s in states:
        lines, errors = outcomes.check_task(s.bundle, collect(s, s.bundle.solutions))
        status = "OK" if not errors else f"{len(errors)} diferencias con lo esperado"
        say(f"== {s.bundle.codename}: límite {s.time_limit:g} s, {status}")
        for line in lines:
            say(f"  {line}")
        for error in errors:
            say(f"  * {error}")
        say()
        ok &= not errors
    return ok


def submit(states: list[TaskState], solutions: dict[str, list[Solution]]) -> None:
    """Envía las soluciones como `tester` y avisa a EvaluationService."""
    file_cacher = FileCacher()
    new_ids = []
    with SessionGen() as session:
        for s in states:
            task = Task.get_from_id(s.task_id, session)
            participation = (
                session.query(Participation)
                .join(User)
                .filter(Participation.contest_id == task.contest_id, User.username == TESTER)
                .one()
            )
            for sol in solutions[s.bundle.codename]:
                digest = file_cacher.put_file_from_path(
                    str(s.bundle.directory / sol.path),
                    f"Solution {sol.name} for task {task.name}",
                )
                submission = Submission(
                    timestamp=make_datetime(),
                    language=LANGUAGES[sol.language],
                    participation=participation,
                    task=task,
                    opaque_id=Submission.generate_opaque_id(session, participation.id),
                )
                session.add(File(filename=f"{task.name}.%l", digest=digest, submission=submission))
                session.add(submission)
                session.flush()
                s.submissions[sol.path] = submission.id
                new_ids.append(submission.id)
        session.commit()
    with service("EvaluationService") as es:
        for submission_id in new_ids:
            es.new_submission(submission_id=submission_id).get(timeout=60)
    say(f"{len(new_ids)} envíos")


def wait(states: list[TaskState], solutions: dict[str, list[Solution]]) -> None:
    """Espera a que CMS evalúe (o no logre compilar) los envíos en el dataset de su tarea."""
    pending = {
        (s.submissions[sol.path], s.dataset_id): f"{s.bundle.codename}/{sol.name}"
        for s in states
        for sol in solutions[s.bundle.codename]
    }
    total = len(pending)
    start = last_progress = time.monotonic()
    while pending:
        with SessionGen() as session:
            for key in list(pending):
                sr = SubmissionResult.get_from_id(key, session)
                if sr is None:
                    continue
                if sr.compilation_failed() or sr.evaluated():
                    del pending[key]
                elif sr.compilation_tries >= MAX_TRIES or sr.evaluation_tries >= MAX_TRIES:
                    raise ImportFailed(
                        f"CMS no logró evaluar {pending[key]} (envío {key[0]}). "
                        "Ver los logs de CMS (journalctl -u cms-resource, ~/cms/log/)."
                    )
        if not pending:
            break
        now = time.monotonic()
        if now - start > WAIT_TIMEOUT_SECONDS:
            raise ImportFailed(f"pasaron {WAIT_TIMEOUT_SECONDS // 3600} horas sin terminar de evaluar")
        if now - last_progress >= PROGRESS_SECONDS:
            say(f"  evaluados {total - len(pending)} de {total} envíos")
            last_progress = now
        time.sleep(POLL_SECONDS)
    say(f"  evaluados {total} de {total} envíos")


def collect(state: TaskState, solutions: list[Solution]) -> dict[str, outcomes.SolutionResult]:
    """Resultados de las soluciones en el dataset nuevo.

    Falla si algún caso lo evaluó un worker de la principal: el tiempo no sería comparable.
    """
    main_shards = main_worker_shards()
    results = {}
    with SessionGen() as session:
        for sol in solutions:
            sr = SubmissionResult.get_from_id(
                (state.submissions[sol.path], state.dataset_id), session
            )
            if sr.compilation_failed():
                results[sol.path] = outcomes.SolutionResult(compiled=False)
                continue
            result = outcomes.SolutionResult(compiled=True)
            for ev in sr.evaluations:
                if ev.evaluation_shard in main_shards:
                    raise ImportFailed(
                        f"{state.bundle.codename}/{sol.name} se evaluó en la principal, "
                        "así que su tiempo no sirve. ¿Se apagaron los workers?"
                    )
                result.tests[ev.testcase.codename] = outcomes.TestResult(
                    status=outcomes.classify(ev.outcome, ev.text),
                    time=ev.execution_time,
                )
            for name in state.bundle.tests:
                result.tests.setdefault(name, outcomes.TestResult(outcomes.ERROR, None))
            results[sol.path] = result
    return results


# ---------------------------------------------------------------------------
# 4. Terminar o deshacer
# ---------------------------------------------------------------------------


def finalize(contest_bundle: ContestBundle, contest_id: int, states: list[TaskState]) -> None:
    with SessionGen() as session:
        for s in states:
            task = Task.get_from_id(s.task_id, session)
            dataset = Dataset.get_from_id(s.dataset_id, session)
            dataset.autojudge = False
            if s.created:
                continue
            task.active_dataset = dataset
            session.flush()
            for old in list(task.datasets):
                if old.id != dataset.id:
                    session.delete(old)
            # Los envíos de `tester` de importaciones anteriores ya no sirven
            ours = set(s.submissions.values())
            for sub in task.submissions:
                if sub.participation.user.username == TESTER and sub.id not in ours:
                    session.delete(sub)
            b = s.bundle
            task.title = b.title
            task.submission_format = [f"{b.codename}.%l"]
            new_statement = s.loader.get_statement()
            if new_statement.language in task.statements:
                task.statements[new_statement.language].digest = new_statement.digest
            else:
                task.statements[new_statement.language] = new_statement
            task.primary_statements = [new_statement.language]

        # Orden: el del problemset y después las demás tareas del concurso
        contest = Contest.get_from_id(contest_id, session)
        imported = [t.codename for t in contest_bundle.tasks]
        others = sorted(
            (t for t in contest.tasks if t.name not in imported),
            key=lambda t: (t.num is None, t.num or 0),
        )
        ordered = [next(t for t in contest.tasks if t.name == n) for n in imported] + others
        # (contest_id, num) es único: primero se liberan los números
        for t in contest.tasks:
            t.num = None
        session.flush()
        for num, t in enumerate(ordered):
            t.num = num
        session.commit()

    notify_ranking([s.task_id for s in states if not s.created])
    say("Importación terminada: los datasets nuevos están activos.")


def rollback(states: list[TaskState]) -> None:
    with SessionGen() as session:
        for s in states:
            task = Task.get_from_id(s.task_id, session)
            if task is None:
                continue
            if s.created:
                session.delete(task)
                continue
            for submission_id in s.submissions.values():
                sub = Submission.get_from_id(submission_id, session)
                if sub is not None:
                    session.delete(sub)
            dataset = Dataset.get_from_id(s.dataset_id, session)
            if dataset is not None:
                session.delete(dataset)
        session.commit()
    say("Se borraron las tareas y los datasets creados.")


def notify_ranking(task_ids: list[int]) -> None:
    """Avisa al ProxyService, como "Make live" en el panel. Solo corre si CMS está
    asociado a un concurso (cms-contest <id>); si no, no hay ranking que avisar."""
    client = RemoteServiceClient(ServiceCoord("ProxyService", 0))
    client.connect()
    try:
        if not client.wait_for_connection(timeout=2):
            return
        for task_id in task_ids:
            client.dataset_updated(task_id=task_id).get(timeout=60)
        client.reinitialize().get(timeout=60)
    finally:
        client.disconnect()


@contextmanager
def service(name: str):
    client = RemoteServiceClient(ServiceCoord(name, 0))
    client.connect()
    try:
        if not client.wait_for_connection(timeout=10):
            raise ImportFailed(f"no se pudo conectar a {name}. ¿Está corriendo CMS?")
        yield client
    finally:
        client.disconnect()
