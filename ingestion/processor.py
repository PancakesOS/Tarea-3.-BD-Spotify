"""Processor: cada 5 minutos (cron) convierte el crudo en conteos.

En cada corrida:
  1. Lee del crudo solo lo que no ha procesado: guarda en su estado hasta
     qué byte de /app/data/raw/<tópico>.log llegó (como el offset de Kafka).
  2. Descarta lo que no es una reproducción con el formato del tópico
     (JSON inválido, campos faltantes o con otro tipo, played_at sin zona).
  3. Quita los duplicados: un event_id que ya vio. Recuerda los event_id de
     los últimos SEEN_TTL_SECONDS (30 min); un duplicado llega a Kafka a lo
     más 5 minutos después que el original, así que el margen sobra.
  4. Se queda con las reproducciones válidas (ms_played >= 30000).
  5. Descarta las de suscriptores o canciones que no existen en la base
     (p. ej., un suscriptor ya eliminado); si no, una sola FK violada
     abortaría el lote entero en cada corrida.
  6. Suma los conteos en subscriber_song_play y song_daily_play (día UTC
     de played_at) en UNA transacción: las dos tablas cambian juntas o no
     cambia ninguna, y por eso siempre cuadran entre sí.
  7. Solo después del COMMIT guarda su estado (byte leído y event_id
     vistos). Si algo falla antes, la siguiente corrida repite el lote.
  8. Anota en /app/logs/processor.log qué hizo, cuánto descartó y por qué.

Funciona con cualquier productor que respete el formato del tópico: no
depende de nada del simulador.
"""

import fcntl
import json
import logging
import os
import sys
import time
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path

import psycopg

LOG_DIR = Path("/app/logs")
RAW_DIR = Path("/app/data/raw")
STATE_DIR = Path("/app/data/state")
STATE_FILE = STATE_DIR / "processor_state.json"
LOCK_FILE = STATE_DIR / "processor.lock"

VALID_MS = 30_000            # regla 1: cuenta si duró al menos 30 s
SEEN_TTL_SECONDS = 30 * 60   # regla 2: un duplicado llega <= 5 min después; margen amplio
MAX_LOGGED_LINE = 300        # cuánto de una línea descartada se copia al log

LOG_DIR.mkdir(parents=True, exist_ok=True)
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%S%z",
    # Sin StreamHandler: lo que imprime un programa que ejecuta cron no
    # aparece en ningún lado, así que todo va a su archivo.
    handlers=[logging.FileHandler(LOG_DIR / "processor.log")],
)
log = logging.getLogger("processor")

UPSERT_SUBSCRIBER_SONG = """
    INSERT INTO subscriber_song_play (subscriber_id, song_id, num_rep)
    VALUES (%s, %s, %s)
    ON CONFLICT (subscriber_id, song_id)
    DO UPDATE SET num_rep = subscriber_song_play.num_rep + EXCLUDED.num_rep
"""

UPSERT_SONG_DAILY = """
    INSERT INTO song_daily_play (song_id, play_date, num_rep)
    VALUES (%s, %s, %s)
    ON CONFLICT (song_id, play_date)
    DO UPDATE SET num_rep = song_daily_play.num_rep + EXCLUDED.num_rep
"""


class InvalidMessage(Exception):
    """La línea no es una reproducción con el formato del tópico."""

    def __init__(self, reason: str):
        super().__init__(reason)
        self.reason = reason


def parse_play(line: str) -> dict:
    """Valida una línea del crudo y regresa la reproducción con played_at en UTC."""
    try:
        msg = json.loads(line)
    except json.JSONDecodeError:
        raise InvalidMessage("json_invalido")
    if not isinstance(msg, dict):
        raise InvalidMessage("json_invalido")

    def is_int(v) -> bool:
        return isinstance(v, int) and not isinstance(v, bool)

    event_id = msg.get("event_id")
    if not isinstance(event_id, str) or not event_id:
        raise InvalidMessage("campos_invalidos")
    if not all(is_int(msg.get(f)) for f in ("subscriber_id", "song_id", "ms_played")):
        raise InvalidMessage("campos_invalidos")
    if msg["ms_played"] < 0 or not isinstance(msg.get("played_at"), str):
        raise InvalidMessage("campos_invalidos")
    try:
        played_at = datetime.fromisoformat(msg["played_at"])
    except ValueError:
        raise InvalidMessage("campos_invalidos")
    if played_at.tzinfo is None:
        # Sin zona horaria no se puede saber el día UTC (regla 3).
        raise InvalidMessage("played_at_sin_zona")

    return {
        "event_id": event_id,
        "subscriber_id": msg["subscriber_id"],
        "song_id": msg["song_id"],
        "play_date": played_at.astimezone(timezone.utc).date(),
        "ms_played": msg["ms_played"],
    }


def load_state(raw_name: str) -> dict:
    if not STATE_FILE.exists():
        return {"raw_file": raw_name, "offset": 0, "seen": {}}
    with STATE_FILE.open(encoding="utf-8") as f:
        return json.load(f)


def save_state(state: dict) -> None:
    """Escribe el estado de forma atómica: o queda el anterior o el nuevo."""
    tmp = STATE_FILE.with_suffix(".tmp")
    with tmp.open("w", encoding="utf-8") as f:
        json.dump(state, f)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, STATE_FILE)


def run(topic: str, pg: dict) -> None:
    raw_file = RAW_DIR / f"{topic}.log"
    if not raw_file.exists():
        log.warning("El crudo %s todavía no existe; nada que procesar", raw_file)
        return

    state = load_state(raw_file.name)
    offset = state["offset"]
    size = raw_file.stat().st_size
    if size < offset:
        log.warning("El crudo mide %d bytes, menos que lo ya procesado (%d); "
                    "se procesa desde el inicio", size, offset)
        offset = 0

    # Solo líneas completas: si el consumer va a medio escribir una, se
    # queda para la siguiente corrida.
    with raw_file.open("rb") as f:
        f.seek(offset)
        chunk = f.read()
    end = chunk.rfind(b"\n") + 1
    chunk = chunk[:end]
    lines = chunk.decode("utf-8", errors="replace").splitlines()

    now = time.time()
    seen = {eid: t for eid, t in state["seen"].items() if now - t < SEEN_TTL_SECONDS}

    discarded = Counter()
    candidates = []
    for line in lines:
        if not line.strip():
            continue
        try:
            play = parse_play(line)
        except InvalidMessage as e:
            discarded[e.reason] += 1
            log.warning("Descartado (%s): %s", e.reason, line[:MAX_LOGGED_LINE])
            continue
        if play["event_id"] in seen:
            discarded["duplicado"] += 1
            continue
        seen[play["event_id"]] = now
        if play["ms_played"] < VALID_MS:
            discarded["skip"] += 1
            continue
        candidates.append(play)

    counted = 0
    rows_ssp = rows_sdp = 0
    if candidates:
        with psycopg.connect(**pg, connect_timeout=10) as conn:
            # Todo lo de este bloque es una sola transacción (COMMIT al salir).
            sub_ids = sorted({p["subscriber_id"] for p in candidates})
            song_ids = sorted({p["song_id"] for p in candidates})
            known_subs = {r[0] for r in conn.execute(
                "SELECT subscriber_id FROM subscribers WHERE subscriber_id = ANY(%s)", (sub_ids,)
            ).fetchall()}
            known_songs = {r[0] for r in conn.execute(
                "SELECT song_id FROM songs WHERE song_id = ANY(%s)", (song_ids,)
            ).fetchall()}

            per_subscriber_song = Counter()
            per_song_day = Counter()
            for p in candidates:
                if p["subscriber_id"] not in known_subs:
                    discarded["suscriptor_inexistente"] += 1
                    log.warning("Descartado (suscriptor_inexistente): event_id %s, subscriber_id %s",
                                p["event_id"], p["subscriber_id"])
                    continue
                if p["song_id"] not in known_songs:
                    discarded["cancion_inexistente"] += 1
                    log.warning("Descartado (cancion_inexistente): event_id %s, song_id %s",
                                p["event_id"], p["song_id"])
                    continue
                per_subscriber_song[(p["subscriber_id"], p["song_id"])] += 1
                per_song_day[(p["song_id"], p["play_date"])] += 1
                counted += 1

            with conn.cursor() as cur:
                if per_subscriber_song:
                    cur.executemany(UPSERT_SUBSCRIBER_SONG,
                                    [(s, g, n) for (s, g), n in per_subscriber_song.items()])
                if per_song_day:
                    cur.executemany(UPSERT_SONG_DAILY,
                                    [(g, d, n) for (g, d), n in per_song_day.items()])
            rows_ssp, rows_sdp = len(per_subscriber_song), len(per_song_day)

    # Después del COMMIT: se avanza el crudo y se recuerdan los event_id.
    save_state({"raw_file": raw_file.name, "offset": offset + end, "seen": seen})

    detail = ", ".join(f"{k}={v}" for k, v in sorted(discarded.items())) or "ninguno"
    log.info("%s: %d mensajes nuevos leídos (bytes %d-%d); %d reproducciones válidas contadas; "
             "%d descartados (%s); filas actualizadas: subscriber_song_play %d, song_daily_play %d; "
             "event_id recordados: %d",
             raw_file.name, len(lines), offset, offset + end, counted,
             sum(discarded.values()), detail, rows_ssp, rows_sdp, len(seen))


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
        log.error("Falta la variable de entorno %s: revisa docker-compose.yml y /etc/environment", e)
        sys.exit(1)

    STATE_DIR.mkdir(parents=True, exist_ok=True)
    with LOCK_FILE.open("w") as lock:
        # Si una corrida anterior sigue trabajando, esta no hace nada: dos
        # corridas a la vez contarían el mismo lote dos veces.
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            log.warning("Otra corrida del processor sigue en curso; esta se omite")
            return
        try:
            run(topic, pg)
        except psycopg.OperationalError as e:
            log.error("No se pudo conectar a PostgreSQL; el lote se reintenta en la siguiente corrida: %s", e)
            sys.exit(1)
        except psycopg.Error as e:
            log.error("PostgreSQL rechazó la actualización (ROLLBACK); el lote se reintenta "
                      "en la siguiente corrida: %s", e)
            sys.exit(1)
        except Exception:
            log.exception("Error inesperado; el lote se reintenta en la siguiente corrida")
            sys.exit(1)


if __name__ == "__main__":
    main()
