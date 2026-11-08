"""Verificación: los conteos de la base coinciden con lo que se envió.

Se ejecuta en el contenedor del processor, que ve sent.log (volumen sent,
solo lectura), el crudo y PostgreSQL:

    docker compose exec processor /app/.venv/bin/python /app/ingestion/verify.py

Comprueba:
  1. Por canción: reproducciones válidas (ms_played >= 30000) de sent.log
     (los originales, sin duplicados) = conteos de la base.
  2. Por canción: total de subscriber_song_play = total de song_daily_play.
  Además, con más detalle:
  3. Por (suscriptor, canción): sent.log = subscriber_song_play.
  4. Por (canción, día UTC): sent.log = song_daily_play.

Muestra OK si todo coincide o la lista de diferencias. Para que coincida,
la base y sent.log deben venir de la misma ejecución (partir de
docker compose down -v), el producer debe estar detenido y el processor
debe haber hecho su siguiente corrida.
"""

import json
import logging
import os
import sys
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path

import psycopg

LOG_DIR = Path("/app/logs")
SENT_FILE = Path("/app/sent/sent.log")
RAW_DIR = Path("/app/data/raw")
STATE_FILE = Path("/app/data/state/processor_state.json")
VALID_MS = 30_000

LOG_DIR.mkdir(parents=True, exist_ok=True)
console = logging.StreamHandler()
console.setFormatter(logging.Formatter("%(message)s"))
logfile = logging.FileHandler(LOG_DIR / "verify.log")
logfile.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(message)s", "%Y-%m-%dT%H:%M:%S%z"))
logging.basicConfig(level=logging.INFO, handlers=[console, logfile])
log = logging.getLogger("verify")


def read_sent() -> tuple[int, Counter, Counter, Counter]:
    """Cuenta las reproducciones válidas de sent.log por canción, por
    (suscriptor, canción) y por (canción, día UTC)."""
    total = 0
    per_song, per_sub_song, per_song_day = Counter(), Counter(), Counter()
    with SENT_FILE.open(encoding="utf-8") as f:
        for line in f:
            if not line.strip():
                continue
            msg = json.loads(line)
            total += 1
            if msg["ms_played"] < VALID_MS:
                continue
            day = datetime.fromisoformat(msg["played_at"]).astimezone(timezone.utc).date()
            per_song[msg["song_id"]] += 1
            per_sub_song[(msg["subscriber_id"], msg["song_id"])] += 1
            per_song_day[(msg["song_id"], day)] += 1
    return total, per_song, per_sub_song, per_song_day


def read_db(pg: dict) -> tuple[Counter, Counter]:
    with psycopg.connect(**pg, connect_timeout=10) as conn:
        ssp = Counter({(s, g): n for s, g, n in conn.execute(
            "SELECT subscriber_id, song_id, num_rep FROM subscriber_song_play").fetchall()})
        sdp = Counter({(g, d): n for g, d, n in conn.execute(
            "SELECT song_id, play_date, num_rep FROM song_daily_play").fetchall()})
    return ssp, sdp


def by_song(counts: Counter, song_pos: int) -> Counter:
    out = Counter()
    for key, n in counts.items():
        out[key[song_pos]] += n
    return out


def compare(name: str, left_name: str, left: Counter, right_name: str, right: Counter) -> list[str]:
    diffs = []
    for key in sorted(set(left) | set(right), key=str):
        if left[key] != right[key]:
            diffs.append(f"  {name} {key}: {left_name}={left[key]}, {right_name}={right[key]}")
    return diffs


def main() -> None:
    try:
        topic = os.environ["KAFKA_TOPIC"]
        pg = {
            "host": os.environ["POSTGRES_HOST"],
            "dbname": os.environ["POSTGRES_DB"],
            "user": os.environ["POSTGRES_USER"],
            "password": os.environ["POSTGRES_PASSWORD"],
        }
    except KeyError as e:
        log.error("Falta la variable de entorno %s: ejecuta verify.py en el contenedor del processor", e)
        sys.exit(1)
    if not SENT_FILE.exists():
        log.error("No existe %s: el producer todavía no ha enviado nada", SENT_FILE)
        sys.exit(1)

    # Aviso si el processor todavía no alcanza el final del crudo.
    raw_file = RAW_DIR / f"{topic}.log"
    if raw_file.exists():
        processed = json.loads(STATE_FILE.read_text())["offset"] if STATE_FILE.exists() else 0
        pending = raw_file.stat().st_size - processed
        if pending > 0:
            log.warning("AVISO: el processor aún no procesa %d bytes del crudo; "
                        "espera su siguiente corrida para comparar", pending)

    try:
        total, sent_song, sent_sub_song, sent_song_day = read_sent()
        ssp, sdp = read_db(pg)
    except psycopg.OperationalError as e:
        log.error("No se pudo conectar a PostgreSQL: %s", e)
        sys.exit(1)

    ssp_song, sdp_song = by_song(ssp, 1), by_song(sdp, 0)

    log.info("sent.log: %d mensajes originales, %d reproducciones válidas",
             total, sum(sent_song.values()))
    log.info("Base: subscriber_song_play suma %d, song_daily_play suma %d",
             sum(ssp_song.values()), sum(sdp_song.values()))
    log.info("")
    log.info("%8s %10s %22s %17s", "song_id", "sent.log", "subscriber_song_play", "song_daily_play")
    for song in sorted(set(sent_song) | set(ssp_song) | set(sdp_song)):
        log.info("%8s %10d %22d %17d", song, sent_song[song], ssp_song[song], sdp_song[song])
    log.info("")

    checks = [
        ("1. Por canción, sent.log = base",
         compare("canción", "sent.log", sent_song, "song_daily_play", sdp_song)),
        ("2. Por canción, subscriber_song_play = song_daily_play",
         compare("canción", "subscriber_song_play", ssp_song, "song_daily_play", sdp_song)),
        ("3. Por (suscriptor, canción), sent.log = subscriber_song_play",
         compare("(suscriptor, canción)", "sent.log", sent_sub_song, "subscriber_song_play", ssp)),
        ("4. Por (canción, día UTC), sent.log = song_daily_play",
         compare("(canción, día)", "sent.log", sent_song_day, "song_daily_play", sdp)),
    ]
    all_ok = True
    for title, diffs in checks:
        if diffs:
            all_ok = False
            log.info("%s: %d diferencias", title, len(diffs))
            for d in diffs:
                log.info(d)
        else:
            log.info("%s: coincide", title)

    log.info("")
    if all_ok:
        log.info("OK")
    else:
        log.info("HAY DIFERENCIAS")
        sys.exit(1)


if __name__ == "__main__":
    main()
