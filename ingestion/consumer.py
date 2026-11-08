"""Consumer: lee el tópico de Kafka y guarda cada mensaje, tal cual, en el crudo.

No interpreta ni filtra nada: eso le toca al processor. Cada mensaje se
agrega como una línea al final de /app/data/raw/<tópico>.log (un solo
archivo que solo crece; ver README, «Cómo se organiza el crudo»).

Entrega «al menos una vez»: el offset de un mensaje se le confirma a Kafka
solo DESPUÉS de escribirlo en el crudo. Si el consumer se cae a la mitad,
al reiniciar vuelve a leer desde el último mensaje guardado; en el peor
caso un mensaje queda dos veces en el crudo, y el processor lo descarta
como duplicado por su event_id.
"""

import logging
import os
import sys
from pathlib import Path

from confluent_kafka import Consumer, KafkaError

LOG_DIR = Path("/app/logs")
RAW_DIR = Path("/app/data/raw")
GROUP_ID = "ingestion"

LOG_DIR.mkdir(parents=True, exist_ok=True)
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%S%z",
    handlers=[logging.FileHandler(LOG_DIR / "consumer.log"), logging.StreamHandler()],
)
log = logging.getLogger("consumer")


def main() -> None:
    try:
        bootstrap_servers = os.environ["KAFKA_BOOTSTRAP_SERVERS"]
        topic = os.environ["KAFKA_TOPIC"]
    except KeyError as e:
        log.error("Falta la variable de entorno %s: revisa el .env y docker-compose.yml", e)
        sys.exit(1)

    raw_file = RAW_DIR / f"{topic}.log"
    try:
        RAW_DIR.mkdir(parents=True, exist_ok=True)
        raw = raw_file.open("a", encoding="utf-8")
    except OSError as e:
        log.error("No se puede escribir en el crudo %s: %s", raw_file, e)
        sys.exit(1)

    consumer = Consumer({
        "bootstrap.servers": bootstrap_servers,
        "group.id": GROUP_ID,
        "auto.offset.reset": "earliest",
        "allow.auto.create.topics": True,
        # La librería confirma sola cada pocos segundos, pero solo los
        # offsets que guardamos con store_offsets(), es decir, los de
        # mensajes que ya están en el crudo.
        "enable.auto.offset.store": False,
    })
    consumer.subscribe([topic])
    log.info("Suscrito al tópico %s; el crudo se escribe en %s", topic, raw_file)

    try:
        while True:
            msg = consumer.poll(timeout=1.0)
            if msg is None:
                continue
            if msg.error():
                if msg.error().code() == KafkaError.UNKNOWN_TOPIC_OR_PART:
                    log.warning("El tópico %s todavía no existe; sigo esperando mensajes", topic)
                else:
                    log.error("Kafka reportó un error: %s", msg.error())
                continue
            if msg.value() is None:
                log.warning("Mensaje vacío en el offset %s; no hay nada que guardar", msg.offset())
                consumer.store_offsets(message=msg)
                continue

            # Una línea por mensaje. Un JSON válido no puede llevar saltos de
            # línea dentro de sus textos (van escapados como \n), así que
            # cambiar un salto de línea literal por un espacio no altera el
            # contenido del mensaje y garantiza que ocupe una sola línea.
            value = msg.value().decode("utf-8", errors="replace")
            line = value.replace("\r", " ").replace("\n", " ")
            try:
                raw.write(line + "\n")
                raw.flush()
            except OSError as e:
                log.error("No se pudo escribir en el crudo %s: %s", raw_file, e)
                sys.exit(1)
            consumer.store_offsets(message=msg)
            log.info("Guardado en el crudo (offset %s): %s", msg.offset(), line)
    except Exception:
        log.exception("Error inesperado al leer de Kafka")
        sys.exit(1)
    finally:
        consumer.close()
        raw.close()


if __name__ == "__main__":
    main()
