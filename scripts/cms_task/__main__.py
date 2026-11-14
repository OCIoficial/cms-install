"""Uso (con el Python de CMS): python -m cms_task import <cms-export.zip> --contest <id>

Normalmente no se llama directo: `cms-task start` lo lanza como servicio de systemd.
"""

import argparse
import sys
import traceback
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser(prog="cms-task")
    sub = parser.add_subparsers(dest="command", required=True)
    imp = sub.add_parser("import", help="importa cms-export.zip y mide los límites de tiempo")
    imp.add_argument("zip", type=Path)
    imp.add_argument("--contest", type=int, required=True)
    args = parser.parse_args()

    # Importar CMS es lento y lee la configuración: solo cuando hace falta
    from .importer import run

    try:
        ok = run(args.zip, args.contest)
    except BaseException:
        # `cms-task attach` lee el resultado de la última línea: que siempre esté
        traceback.print_exc(file=sys.stdout)
        ok = False
    print("RESULTADO: OK" if ok else "RESULTADO: FALLÓ", flush=True)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
