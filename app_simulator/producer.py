"""Simulador de la app de Spotify.

Inventa reproducciones y las publica en el tópico de Kafka con el formato
fijo del enunciado:

    {"event_id": "...", "subscriber_id": 1, "song_id": 101,
     "played_at": "2026-11-03T18:42:10-07:00", "ms_played": 187000}

Para probar la ingesta como en la vida real, además:
  * genera skips (ms_played < 30000) en una proporción SKIP_RATE;
  * reenvía una proporción DUPLICATE_RATE de los mensajes, idénticos, con un
    retraso aleatorio de 0 a MAX_DUPLICATE_DELAY_SECONDS (máx. 300);
  * simula el modo sin conexión: played_at cae en cualquier momento de los
    últimos MAX_PLAY_AGE_DAYS días;
  * anota en /app/sent/sent.log cada mensaje ORIGINAL que Kafka confirmó
    (sin los duplicados): es la referencia de ingestion/verify.py.

Al iniciar lee de PostgreSQL los suscriptores y las canciones que existen y
solo usa esos IDs.
"""

import heapq
import json
import logging
import os
import random
import signal
import sys
import time
import uuid
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path

import psycopg
from confluent_kafka import Producer

LOG_DIR = Path("/app/logs")
SENT_FILE = Path("/app/sent/sent.log")

# Zona horaria de los teléfonos simulados (Hermosillo, UTC-7, sin horario
# de verano). La app manda played_at en hora local con su desfase; el
# processor es quien lo convierte a UTC.
APP_TZ = timezone(timedelta(hours=-7))

# Cada cuánto revisa el ciclo principal si toca enviar algo (segundos).
TICK_SECONDS = 0.2

LOG_DIR.mkdir(parents=True, exist_ok=True)
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%S%z",
    handlers=[logging.FileHandler(LOG_DIR / "producer.log"), logging.StreamHandler()],
)
log = logging.getLogger("producer")


@dataclass(frozen=True)
class Config:
    postgres_host: str
    postgres_db: str
    postgres_user: str
    postgres_password: str
    bootstrap_servers: str
    topic: str
    interval_seconds: float
    skip_rate: float
    duplicate_rate: float
    max_duplicate_delay_seconds: float
    max_play_age_days: float


def read_config() -> Config:
    """Lee la configuración de las variables de entorno y valida sus rangos."""
    try:
        cfg = Config(
            postgres_host=os.environ["POSTGRES_HOST"],
            postgres_db=os.environ["POSTGRES_DB"],
            postgres_user=os.environ["POSTGRES_USER"],
            postgres_password=os.environ["POSTGRES_PASSWORD"],
            bootstrap_servers=os.environ["KAFKA_BOOTSTRAP_SERVERS"],
            topic=os.environ["KAFKA_TOPIC"],
            interval_seconds=float(os.environ["INTERVAL_SECONDS"]),
            skip_rate=float(os.environ["SKIP_RATE"]),
            duplicate_rate=float(os.environ["DUPLICATE_RATE"]),
            max_duplicate_delay_seconds=float(os.environ["MAX_DUPLICATE_DELAY_SECONDS"]),
            max_play_age_days=float(os.environ["MAX_PLAY_AGE_DAYS"]),
        )
    except KeyError as e:
        log.error("Falta la variable de entorno %s: revisa el .env y docker-compose.yml", e)
        sys.exit(1)
    except ValueError as e:
        log.error("Una variable numérica del .env no es un número: %s", e)
        sys.exit(1)

    problems = []
    if cfg.interval_seconds <= 0:
        problems.append("INTERVAL_SECONDS debe ser mayor que 0")
    if not 0 <= cfg.skip_rate <= 1:
        problems.append("SKIP_RATE debe estar entre 0 y 1")
    if not 0 <= cfg.duplicate_rate <= 1:
        problems.append("DUPLICATE_RATE debe estar entre 0 y 1")
    if not 0 <= cfg.max_duplicate_delay_seconds <= 300:
        problems.append("MAX_DUPLICATE_DELAY_SECONDS debe estar entre 0 y 300")
    if cfg.max_play_age_days <= 0:
        problems.append("MAX_PLAY_AGE_DAYS debe ser mayor que 0")
    if problems:
        for p in problems:
            log.error("Configuración inválida: %s", p)
        sys.exit(1)
    return cfg


def read_catalog(cfg: Config) -> tuple[list[int], dict[int, int]]:
    """Regresa los IDs de los suscriptores y la duración (s) de cada canción."""
    with psycopg.connect(
        host=cfg.postgres_host,
        dbname=cfg.postgres_db,
        user=cfg.postgres_user,
        password=cfg.postgres_password,
        connect_timeout=10,
    ) as conn:
        subscribers = [r[0] for r in conn.execute(
            "SELECT subscriber_id FROM subscribers ORDER BY subscriber_id"
        ).fetchall()]
        songs = dict(conn.execute(
            "SELECT song_id, duration_seconds FROM songs ORDER BY song_id"
        ).fetchall())
    return subscribers, songs


def build_play(cfg: Config, subscribers: list[int], songs: dict[int, int]) -> dict:
    """Inventa una reproducción con el formato fijo del tópico."""
    song_id = random.choice(list(songs))
    if random.random() < cfg.skip_rate:
        ms_played = random.randint(1_000, 29_999)                 # skip: no cuenta
    else:
        full_ms = max(30_000, songs[song_id] * 1000)
        ms_played = random.randint(30_000, full_ms)               # válida: hasta la canción completa
    age = timedelta(seconds=random.uniform(0, cfg.max_play_age_days * 86_400))
    played_at = (datetime.now(timezone.utc) - age).astimezone(APP_TZ)
    return {
        "event_id": str(uuid.uuid4()),
        "subscriber_id": random.choice(subscribers),
        "song_id": song_id,
        "played_at": played_at.isoformat(timespec="seconds"),
        "ms_played": ms_played,
    }


def main() -> None:
    cfg = read_config()

    # Catálogo: si PostgreSQL todavía no acepta conexiones, se termina con
    # error y Docker vuelve a iniciar el contenedor (restart: on-failure).
    try:
        subscribers, songs = read_catalog(cfg)
    except psycopg.OperationalError as e:
        log.error("No se pudo conectar a PostgreSQL; Docker volverá a iniciar el producer: %s", e)
        sys.exit(1)
    except psycopg.errors.UndefinedTable as e:
        log.error("La base todavía no tiene las tablas; Docker volverá a iniciar el producer: %s", e)
        sys.exit(1)
    except Exception:
        log.exception("Error inesperado al leer el catálogo")
        sys.exit(1)
    if not subscribers or not songs:
        log.error("No hay suscriptores o canciones en la base; no hay qué simular")
        sys.exit(1)
    log.info("Catálogo leído: %d suscriptores %s y %d canciones %s",
             len(subscribers), subscribers, len(songs), sorted(songs))

    # sent.log se abre en modo append: si Docker reinicia el producer, no se
    # pierde lo que ya se había anotado.
    try:
        SENT_FILE.parent.mkdir(parents=True, exist_ok=True)
        sent = SENT_FILE.open("a", encoding="utf-8")
    except OSError as e:
        log.error("No se puede escribir en %s: %s", SENT_FILE, e)
        sys.exit(1)

    producer = Producer({"bootstrap.servers": cfg.bootstrap_servers})

    # Duplicados pendientes: (momento de envío, consecutivo, mensaje). Un
    # heap entrega siempre el próximo a enviar sin frenar los originales.
    pending: list[tuple[float, int, str]] = []
    counter = 0

    def on_original(err, msg) -> None:
        """Kafka confirmó (o no) un mensaje original."""
        nonlocal counter
        value = msg.value().decode("utf-8")
        if err is not None:
            log.error("Kafka no confirmó el mensaje; no se anota en sent.log: %s (%s)", value, err)
            return
        sent.write(value + "\n")
        sent.flush()
        log.info("Enviado: %s", value)
        # El duplicado se programa desde la confirmación del original, así
        # nunca llega un duplicado de un mensaje que Kafka no guardó.
        if random.random() < cfg.duplicate_rate:
            delay = random.uniform(0, cfg.max_duplicate_delay_seconds)
            counter += 1
            heapq.heappush(pending, (time.monotonic() + delay, counter, value))
            log.info("Duplicado programado en %.0f s: %s", delay, json.loads(value)["event_id"])

    def on_duplicate(err, msg) -> None:
        """Kafka confirmó (o no) un duplicado."""
        value = msg.value().decode("utf-8")
        if err is not None:
            log.error("Kafka no confirmó el duplicado: %s (%s)", value, err)
        else:
            log.info("Duplicado enviado: %s", value)

    # docker compose stop manda SIGTERM: se termina el ciclo y se espera a
    # que Kafka confirme lo que estaba en camino, para anotarlo en sent.log.
    running = True

    def stop(signum, frame) -> None:
        nonlocal running
        running = False

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)

    log.info("Publicando en el tópico %s cada %s s (skips %.0f%%, duplicados %.0f%%, "
             "retraso máx. %s s, played_at hasta %s días atrás)",
             cfg.topic, cfg.interval_seconds, cfg.skip_rate * 100, cfg.duplicate_rate * 100,
             cfg.max_duplicate_delay_seconds, cfg.max_play_age_days)

    next_original = time.monotonic()
    try:
        while running:
            now = time.monotonic()
            while pending and pending[0][0] <= now:
                _, _, value = heapq.heappop(pending)
                producer.produce(cfg.topic, value=value, on_delivery=on_duplicate)
            if now >= next_original:
                value = json.dumps(build_play(cfg, subscribers, songs))
                producer.produce(cfg.topic, value=value, on_delivery=on_original)
                next_original += cfg.interval_seconds
            producer.poll(TICK_SECONDS)       # atiende las confirmaciones de Kafka
    except Exception:
        log.exception("Error inesperado al publicar")
        sys.exit(1)
    finally:
        left = producer.flush(10)
        sent.close()
        log.info("Producer detenido; %d duplicados pendientes no se enviaron; "
                 "%d mensajes sin confirmar", len(pending), left)


if __name__ == "__main__":
    main()
