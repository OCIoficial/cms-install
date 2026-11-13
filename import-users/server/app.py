#!/usr/bin/env python3
"""Importador de usuarios de CMS, en https://<admin>/import-users/.

Corre en la principal con el Python de CMS (servicio cms-import-users) y
escucha solo en 127.0.0.1; nginx le pasa /import-users del dominio del admin.

Usa el login del panel de administración: valida la cookie `awslogin` igual
que AdminWebServer (cms/server/admin/authentication.py), con la secret_key de
cms.toml. Solo pueden entrar administradores activos con todos los permisos.

Rutas (bajo /import-users):
  GET  /             la página (el frontend compilado en static/)
  GET  /assets/...   JS y CSS del frontend
  GET  /api/meta     concursos y equipos
  POST /api/preview  valida las filas, sin escribir
  POST /api/import   valida y escribe todo en una transacción
"""

import argparse
import collections
import collections.abc
import json
import logging
import math
from pathlib import Path

# CMS usa tornado 4.5.3, que no funciona en Python ≥ 3.10 sin esto (CMS hace
# lo mismo antes de importar tornado, p. ej. en cms/server/util.py)
if not hasattr(collections, "MutableMapping"):
    collections.MutableMapping = collections.abc.MutableMapping

from gevent.pywsgi import WSGIServer
from sqlalchemy.exc import IntegrityError
from tornado.web import decode_signed_value
from werkzeug.exceptions import HTTPException
from werkzeug.middleware.shared_data import SharedDataMiddleware
from werkzeug.routing import Map, Rule
from werkzeug.wrappers import Request, Response

from cms import ServiceCoord, config
from cms.db import Admin, Contest, Participation, SessionGen, Team, User
from cms.io import RemoteServiceClient
from cmscommon.crypto import build_password, validate_password
from cmscommon.datetime import make_timestamp

from rules import FIELDS, ExistingUser, Regions, check_rows, summarize

logger = logging.getLogger("cms-import-users")

HERE = Path(__file__).resolve().parent
STATIC = HERE / "static"
PREFIX = "/import-users"
COOKIE = "awslogin"
MAX_ROWS = 5000

REGIONS = Regions.load(HERE / "data")


class ApiError(Exception):
    def __init__(self, status: int, message: str, **extra):
        super().__init__(message)
        self.status = status
        self.body = {"error": message, **extra}


def json_response(data, status: int = 200) -> Response:
    return Response(json.dumps(data), status=status, mimetype="application/json")


# ---------------------------------------------------------------------------
# Login (la cookie del panel de administración)
# ---------------------------------------------------------------------------

def current_admin(request: Request, session) -> tuple[Admin | None, str]:
    """El administrador de la cookie, o None y el motivo ("login" o "forbidden")."""
    duration = config.admin_web_server.cookie_duration
    value = decode_signed_value(
        bytes.fromhex(config.web_server.secret_key),
        COOKIE,
        request.cookies.get(COOKIE),
        max_age_days=math.ceil(duration / 60 / 60 / 24),
    )
    if value is None:
        return None, "login"
    try:
        cookie = json.loads(value)
    except ValueError:
        return None, "login"
    admin_id = cookie.get("id") if isinstance(cookie, dict) else None
    timestamp = cookie.get("timestamp") if isinstance(cookie, dict) else None
    if not isinstance(admin_id, int) or not isinstance(timestamp, float):
        return None, "login"
    if make_timestamp() - timestamp > duration:
        return None, "login"
    admin = Admin.get_from_id(admin_id, session)
    if admin is None or not admin.enabled:
        return None, "login"
    if not admin.permission_all:
        return None, "forbidden"
    return admin, ""


def require_admin(request: Request, session) -> Admin:
    admin, reason = current_admin(request, session)
    if admin is None:
        if reason == "forbidden":
            raise ApiError(403, "Your admin account needs full permissions to import users.")
        raise ApiError(401, "Not logged in to the admin panel.", login=login_url())
    return admin


def login_url() -> str:
    return f"/login?next={PREFIX}/"


# ---------------------------------------------------------------------------
# Datos
# ---------------------------------------------------------------------------

def parse_body(request: Request) -> tuple[int | None, set[str], list[dict]]:
    """Lee {contest_id, mapped, rows} y devuelve el id del concurso, los campos
    asignados y las filas (solo con esos campos, como texto)."""
    try:
        body = json.loads(request.get_data(as_text=True))
        contest_id = body.get("contest_id")
        mapped = set(body["mapped"])
        rows = body["rows"]
        assert contest_id is None or isinstance(contest_id, int)
        assert mapped <= set(FIELDS)
        assert isinstance(rows, list)
        rows = [{f: str(row.get(f, "")) for f in mapped} for row in rows]
    except (ValueError, KeyError, TypeError, AttributeError, AssertionError):
        raise ApiError(400, "Malformed request.") from None
    if "username" not in mapped:
        raise ApiError(400, "Assign a column to Username.")
    if not rows:
        raise ApiError(400, "There are no rows to import.")
    if len(rows) > MAX_ROWS:
        raise ApiError(400, f"Too many rows (maximum {MAX_ROWS}).")
    return contest_id, mapped, rows


def check(session, contest_id, mapped, rows):
    contest = None
    if contest_id is not None:
        contest = Contest.get_from_id(contest_id, session)
        if contest is None:
            raise ApiError(400, f"Contest {contest_id} doesn't exist.")
        if contest.main_group is None:
            raise ApiError(400, f"Contest {contest.name} has no main group.")

    usernames = {r["username"] for r in rows}
    users = {
        u.username: u
        for u in session.query(User).filter(User.username.in_(usernames))
    }
    participations = {}
    if contest is not None:
        for p in (
            session.query(Participation)
            .join(User)
            .filter(Participation.contest_id == contest.id)
            .filter(User.username.in_(usernames))
        ):
            participations[p.user.username] = p.team.code if p.team else None

    results = check_rows(
        rows,
        mapped,
        contest is not None,
        REGIONS,
        {
            name: ExistingUser(u.first_name, u.last_name, u.email, u.password)
            for name, u in users.items()
        },
        participations,
        password_matches,
    )
    return contest, users, results


def password_matches(stored: str, password: str) -> bool:
    try:
        return validate_password(stored, password)
    except ValueError:
        return False


def write(session, contest: Contest | None, users: dict[str, User], results: list[dict]):
    teams: dict[str, Team] = {t.code: t for t in session.query(Team)}

    def team(code: str | None) -> Team | None:
        if code is None:
            return None
        if code not in teams:
            teams[code] = Team(code=code, name=REGIONS.teams[code])
            session.add(teams[code])
        return teams[code]

    participations = {}
    if contest is not None:
        participations = {
            p.user_id: p
            for p in session.query(Participation).filter(Participation.contest_id == contest.id)
        }

    for r in results:
        v = r["values"]
        user = users.get(v["username"])
        if user is None:
            user = User(
                username=v["username"],
                first_name=v["first_name"],
                last_name=v["last_name"],
                password=build_password(v["password"]),
                email=v.get("email") or None,
            )
            session.add(user)
        if r["participation"] == "new":
            session.add(Participation(
                user=user, contest=contest, group=contest.main_group, team=team(r["team"]),
            ))
        elif r["participation"] == "team":
            participations[user.id].team = team(r["team"])


def notify_ranking():
    """Pide al ProxyService que reenvíe usuarios y equipos al ranking. Solo
    corre si CMS está asociado a un concurso (cms-contest <id>); si no, no hay
    nada que avisar."""
    client = RemoteServiceClient(ServiceCoord("ProxyService", 0))
    client.connect()
    try:
        if client.wait_for_connection(timeout=1):
            client.reinitialize()
            return True
        return False
    finally:
        client.disconnect()


# ---------------------------------------------------------------------------
# Rutas
# ---------------------------------------------------------------------------

def page(request: Request) -> Response:
    with SessionGen() as session:
        admin, reason = current_admin(request, session)
    if admin is None and reason == "login":
        return Response(status=302, headers={"Location": login_url()})
    if admin is None:
        return Response(
            "Your admin account needs full permissions to import users.",
            status=403, mimetype="text/plain")
    return Response((STATIC / "index.html").read_bytes(), mimetype="text/html",
                    headers={"Cache-Control": "no-store"})


def meta(request: Request) -> Response:
    with SessionGen() as session:
        admin = require_admin(request, session)
        contests = [
            {"id": c.id, "name": c.name, "description": c.description}
            for c in session.query(Contest).order_by(Contest.id)
        ]
        return json_response({
            "admin": admin.username,
            "contests": contests,
            "teams": [{"code": c, "name": n} for c, n in REGIONS.teams.items()],
        })


def preview(request: Request) -> Response:
    contest_id, mapped, rows = parse_body(request)
    with SessionGen() as session:
        require_admin(request, session)
        _, _, results = check(session, contest_id, mapped, rows)
    return json_response({"rows": results, "summary": summarize(results)})


def do_import(request: Request) -> Response:
    contest_id, mapped, rows = parse_body(request)
    with SessionGen() as session:
        # Se lee antes del commit, que expira los objetos de la sesión
        admin_name = require_admin(request, session).username
        contest, users, results = check(session, contest_id, mapped, rows)
        contest_name = contest.name if contest is not None else None
        summary = summarize(results)
        if summary["errors"]:
            raise ApiError(400, "Some rows have errors. Nothing was imported.",
                           rows=results, summary=summary)
        write(session, contest, users, results)
        try:
            session.commit()
        except IntegrityError:
            # Alguien cambió la base de datos entre la validación y ahora
            logger.exception("Import failed")
            raise ApiError(409, "The database changed while importing. Nothing was "
                                "imported; check the preview again.") from None
    logger.info("Admin %s imported %d rows (contest %s): %s",
                admin_name, len(rows), contest_name, summary)
    ranking = None
    if contest_id is not None and (summary["participations_created"] or summary["teams_changed"]):
        ranking = notify_ranking()
    return json_response({"summary": summary, "ranking_notified": ranking})


def check_api_request(request: Request):
    """Protección CSRF: un sitio ajeno no puede mandar este encabezado sin que
    el navegador pida permiso (CORS), y este servidor nunca lo da."""
    if request.method == "POST" and (
        request.headers.get("X-Requested-With") != "cms-import-users"
        or request.mimetype != "application/json"
    ):
        raise ApiError(403, "Missing CSRF header.")


URLS = Map([
    Rule(PREFIX, endpoint="redirect"),
    Rule(f"{PREFIX}/", endpoint=page, methods=["GET"]),
    Rule(f"{PREFIX}/api/meta", endpoint=meta, methods=["GET"]),
    Rule(f"{PREFIX}/api/preview", endpoint=preview, methods=["POST"]),
    Rule(f"{PREFIX}/api/import", endpoint=do_import, methods=["POST"]),
])


@Request.application
def application(request: Request) -> Response:
    try:
        endpoint, _ = URLS.bind_to_environ(request.environ).match()
        if endpoint == "redirect":
            return Response(status=302, headers={"Location": f"{PREFIX}/"})
        check_api_request(request)
        return endpoint(request)
    except ApiError as e:
        return json_response(e.body, e.status)
    except HTTPException as e:
        return e


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--port", type=int, default=8891)
    args = parser.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    app = SharedDataMiddleware(application, {f"{PREFIX}/assets": str(STATIC / "assets")})
    logger.info("Listening on 127.0.0.1:%d", args.port)
    WSGIServer(("127.0.0.1", args.port), app, log=None).serve_forever()


if __name__ == "__main__":
    main()
