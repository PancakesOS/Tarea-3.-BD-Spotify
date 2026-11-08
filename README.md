# Plataforma de datos de Spotify

Proyecto del curso de Ingeniería de Datos. Empezó como la base de datos transaccional de Spotify (Tarea 3) y ahora es una pequeña plataforma de datos con dos piezas:

1. **La base de datos transaccional** en **PostgreSQL 18**: el catálogo, los suscriptores y sus playlists y bibliotecas, cargados con los datos de Laura.
2. **La ingesta de reproducciones con Kafka** (Tarea 4): la app publica cada reproducción en Kafka, un consumer la guarda en archivos (el **crudo**) y un processor, cada 5 minutos, quita duplicados, filtra y actualiza los **conteos** que necesitan el **top 100 semanal** y **las 20 canciones más escuchadas** de cada suscriptor.

Todo corre en Docker con un solo comando.

## Arquitectura

```
producer ──→ Kafka (tópico streams) ──→ consumer ──→ crudo: /app/data/raw/streams.log
(app_simulator/)                         (ingestion/)          │
                                                               ↓ cron, cada 5 minutos
                                         processor: quita duplicados, filtra y actualiza los conteos ──→ PostgreSQL
                                         (ingestion/)
```

**Regla principal: ningún mensaje se guarda en PostgreSQL.** La base solo guarda lo que la app necesita mostrar, los conteos (`subscriber_song_play` y `song_daily_play`). Los mensajes originales se quedan en el crudo, fuera de la base, para el análisis: es la separación entre OLTP y OLAP.

| Servicio | Imagen | Qué ejecuta | Volúmenes |
|---|---|---|---|
| `postgres` | `postgres:18` | La base de datos; con el volumen vacío ejecuta `db/01_`, `02_` y `03_` | `datos` |
| `kafka` | `apache/kafka:4.1.0` | Un broker en modo KRaft (sin ZooKeeper) | (ninguno) |
| `producer` | la nuestra (`Dockerfile`) | `app_simulator/producer.py`: simula la app y publica reproducciones | `logs`, `sent` |
| `consumer` | la nuestra | `ingestion/consumer.py`: guarda cada mensaje, tal cual, en el crudo | `crudo`, `logs` |
| `processor` | la nuestra | `cron`, que ejecuta `ingestion/processor.py` cada 5 minutos; aquí también se ejecuta `verify.py` | `crudo`, `logs`, `sent` (solo lectura) |

`app_simulator/` va aparte de `ingestion/` a propósito: en la vida real la app y su productor son de otro equipo, y nuestro sistema es la ingesta. Los tres programas usan la misma imagen (`Dockerfile`, con las librerías fijadas en `uv.lock`) y escriben su log de monitoreo con `logging` en el volumen `logs`: `producer.log`, `consumer.log`, `processor.log` y `verify.log`.

### El mensaje

Cada reproducción llega al tópico `streams` como un JSON con este formato fijo:

```json
{"event_id": "8c1e2f4a-6b3d-4e2a-9f1c-2d7b8a5e0c31", "subscriber_id": 4, "song_id": 105,
 "played_at": "2026-11-03T18:42:10-07:00", "ms_played": 187000}
```

`event_id` identifica la reproducción (mismo `event_id` = misma reproducción), `played_at` es el momento en que ocurrió (ISO 8601 con zona horaria) y `ms_played` cuántos milisegundos se escuchó.

## Requisitos

- Docker con Docker Compose (Docker Desktop en macOS/Windows o Docker Engine en Linux).
- El puerto `5432` libre.
- Solo para modificar las dependencias: [`uv`](https://docs.astral.sh/uv/). Para ejecutar el proyecto no hace falta, porque la imagen instala todo.

## Variables de entorno (`.env`)

Las credenciales no se suben al repositorio. Crea tu `.env` a partir de la plantilla:

```bash
cp .env.example .env
```

| Variable | Valor de ejemplo | Qué controla |
|---|---|---|
| `POSTGRES_USER` | `admin` | Usuario de PostgreSQL (no cambiar: `psql -U admin`) |
| `POSTGRES_PASSWORD` | la que quieras | Contraseña (es una base local de práctica) |
| `POSTGRES_DB` | `spotify` | Nombre de la base (no cambiar: `psql -d spotify`) |
| `KAFKA_TOPIC` | `streams` | Tópico donde se publican las reproducciones; también nombra el archivo del crudo |
| `INTERVAL_SECONDS` | `2` | Cada cuántos segundos publica el producer una reproducción |
| `SKIP_RATE` | `0.3` | Proporción de *skips* (`ms_played` < 30 000), entre 0 y 1 |
| `DUPLICATE_RATE` | `0.2` | Proporción de mensajes que se vuelven a enviar, entre 0 y 1 |
| `MAX_DUPLICATE_DELAY_SECONDS` | `300` | Retraso máximo de un duplicado; no debe pasar de 300 |
| `MAX_PLAY_AGE_DAYS` | `14` | Cuántos días hacia atrás puede caer `played_at` (modo sin conexión); con 14 siempre hay datos de la última semana completa |

Las credenciales de PostgreSQL solo se usan cuando la base se inicializa con el volumen vacío. Si las cambias después, borra los volúmenes con `docker compose down -v`. El producer valida los rangos al iniciar y, si alguno está mal, termina con un `ERROR` que dice cuál.

## Cómo ejecutar

Todos los comandos se ejecutan en la carpeta del repositorio.

```bash
# 1. Construir la imagen e iniciar los cinco servicios. Con el volumen vacío,
#    PostgreSQL ejecuta db/01_schema.sql, db/02_seed.sql y db/03_play_counts.sql.
#    Usa --build cada vez que cambies el código: la imagen guarda una copia.
docker compose up -d --build

# 2. Revisar que los cinco estén corriendo (STATUS = Up).
docker compose ps

# 3. Revisar que PostgreSQL se inicializó sin errores. Si no muestra nada, todo bien.
docker compose logs postgres | grep ERROR

# 4. Ver el log del processor: una línea por corrida, cada 5 minutos.
docker compose exec processor cat /app/logs/processor.log

# 5. Ejecutar las pruebas de SQL.
docker compose exec postgres psql -U admin -d spotify -f /tests.sql

# 6. Verificar los conteos contra lo enviado (ver «Verificación» abajo).
docker compose stop producer
#    ...esperar la siguiente corrida del processor (minutos 0, 5, 10... de cada hora)...
docker compose exec processor /app/.venv/bin/python /app/ingestion/verify.py

# 7. Detener y borrar todo, incluidos los volúmenes (datos, crudo, logs y sent.log).
docker compose down -v
```

**Al iniciar vas a ver errores y es normal.** Durante el primer minuto, `docker compose logs producer` muestra `No se pudo conectar a PostgreSQL` (el producer termina y Docker lo reinicia hasta que la base está lista) y el producer y el consumer muestran `Connect to ipv4#…:9092 failed: Connection refused` mientras Kafka arranca. El consumer muestra además, una vez, `El tópico streams todavía no existe`: se suscribió antes de que existiera y Kafka lo crea en ese momento. La primera línea de `processor.log` puede ser `WARNING El crudo … todavía no existe` si cron corrió antes del primer mensaje.

### Cómo revisar cada pieza

| Pieza | Qué debes ver | Comando |
|---|---|---|
| producer | Una línea `Enviado:` cada `INTERVAL_SECONDS` segundos, y de vez en cuando `Duplicado programado` / `Duplicado enviado` | `docker compose logs --tail 5 producer` |
| Kafka | El tópico existe y su número de mensajes crece | `docker compose exec kafka /opt/kafka/bin/kafka-get-offsets.sh --bootstrap-server kafka:9092 --topic streams` |
| consumer | Una línea `Guardado en el crudo (offset N)` por mensaje y un crudo que crece | `docker compose logs --tail 5 consumer` y `docker compose exec processor wc -l /app/data/raw/streams.log` |
| processor | Su horario instalado y una línea por corrida en su log | `docker compose exec processor crontab -l` y `docker compose exec processor tail -n 5 /app/logs/processor.log` |
| Tablas nuevas | Conteos que crecen tras cada corrida, con las dos sumas iguales | `docker compose exec postgres psql -U admin -d spotify -c "SELECT (SELECT sum(num_rep) FROM subscriber_song_play) AS ssp, (SELECT sum(num_rep) FROM song_daily_play) AS sdp;"` |

Para no esperar a cron, el processor se puede ejecutar a mano: `docker compose exec processor /app/.venv/bin/python /app/ingestion/processor.py`. Es seguro hacerlo aunque cron esté corriendo: un candado (`flock`) impide que dos corridas trabajen a la vez.

Cada corrida deja una línea como esta en `processor.log`:

```
2026-11-08T20:10:01+0000 INFO streams.log: 148 mensajes nuevos leídos (bytes 4943-27333); 91 reproducciones válidas contadas; 57 descartados (duplicado=17, skip=40); filas actualizadas: subscriber_song_play 32, song_daily_play 69; event_id recordados: 160
```

## Decisiones de diseño de la ingesta

### Cómo se organiza el crudo

**Un solo archivo por tópico, `/app/data/raw/streams.log` en el volumen `crudo`, que solo crece.** El consumer agrega cada mensaje como una línea, tal cual llegó, sin interpretarlo ni filtrarlo. El processor recuerda en su estado (`/app/data/state/processor_state.json`, en el mismo volumen) **hasta qué byte del archivo ya procesó**, como el offset de Kafka. En cada corrida lee solo lo nuevo.

Por qué así:

- **Se conserva la historia completa.** El crudo es la fuente para el análisis (OLAP). Borrar los archivos después de procesarlos la perdería, y un archivo por periodo complicaría la lectura sin ganar nada a este volumen.
- **Es simple y se puede reprocesar.** Si mañana cambia una regla (por ejemplo, el umbral de 30 s), basta con regresar el offset a 0 y vaciar las tablas de conteos para recalcular todo.
- **Solo se procesan líneas completas.** Si el consumer va a medio escribir una línea cuando corre el processor, esa línea se queda para la siguiente corrida.
- **Una línea por mensaje, siempre.** Un JSON válido no puede llevar saltos de línea dentro de sus textos (van escapados como `\n`). Si un productor manda un JSON con saltos de línea entre los campos, el consumer los cambia por espacios, lo que no altera el contenido.

Desventaja aceptada: el archivo crece sin fin. En producción se rotaría por día (`streams-2026-11-08.log`) y el estado guardaría archivo + byte; para esta tarea un solo archivo basta.

### Cómo se quitan los duplicados

Kafka entrega cada mensaje **al menos una vez**, así que el mismo mensaje puede llegar dos veces. El enunciado garantiza que **un duplicado llega a Kafka, a lo más, 5 minutos después que el original**.

- El processor guarda en su estado los `event_id` que ya vio, cada uno con la hora en que lo vio, y **los olvida a los 30 minutos**. Un mensaje cuyo `event_id` está en esa lista es un duplicado y no se cuenta. También se detectan duplicados dentro de un mismo lote.
- La ventana de 30 minutos es 6 veces la garantía de 5 minutos. Cubre el retraso del consumer y que cron corre cada 5 minutos, y la lista nunca crece sin fin: guarda solo los `event_id` de la última media hora (~900 con un mensaje cada 2 s).
- Los `event_id` **no** se guardan en PostgreSQL, porque serían otra forma de guardar los mensajes.

### Qué se descarta y por qué

El processor debe funcionar con **cualquier** productor que respete el formato, no solo con el nuestro. Por eso cada mensaje pasa por estos filtros, en orden, y el log anota cuántos se descartaron por cada motivo:

| Motivo en el log | Cuándo |
|---|---|
| `json_invalido` | La línea no es un objeto JSON |
| `campos_invalidos` | Falta un campo, o tiene otro tipo (p. ej. `"subscriber_id": "1"`), `ms_played` es negativo o `played_at` no es una fecha ISO 8601 |
| `played_at_sin_zona` | `played_at` no trae zona horaria: no se puede saber su día en UTC |
| `duplicado` | Su `event_id` ya se contó (ver arriba) |
| `skip` | `ms_played` < 30 000: llegó, pero no es una reproducción válida (regla 1) |
| `suscriptor_inexistente` / `cancion_inexistente` | El ID no existe en la base, por ejemplo un suscriptor que ya se eliminó. Si se intentara insertar, la llave foránea abortaría el lote entero en cada corrida |

Los mensajes con formato inválido o IDs inexistentes se copian además al log como `WARNING`, para poder revisarlos.

### Cómo el processor no cuenta dos veces

- **Una sola transacción por corrida.** Las dos tablas se actualizan con `INSERT … ON CONFLICT DO UPDATE SET num_rep = num_rep + EXCLUDED.num_rep` dentro del mismo `with psycopg.connect(...)`: o cambian las dos o no cambia ninguna, y por eso siempre cuadran entre sí.
- **El estado se guarda después del COMMIT**, y de forma atómica (archivo temporal + `os.replace`). Si PostgreSQL falla, el estado no avanza y la siguiente corrida repite el mismo lote.
- **Un candado (`flock`)** evita que dos corridas (cron y una manual, o una corrida lenta) procesen el mismo lote al mismo tiempo.
- **El consumer confirma el offset a Kafka solo después de escribir el mensaje en el crudo** (`enable.auto.offset.store = False` + `store_offsets`). Si se cae a la mitad, al reiniciar no se pierde nada; en el peor caso un mensaje queda dos veces en el crudo, y el processor lo descarta como duplicado.

### El simulador (`app_simulator/producer.py`)

- Al iniciar lee de PostgreSQL los suscriptores y las canciones que existen, y solo usa esos IDs (además lee la duración de cada canción, para que una reproducción válida no dure más que la canción).
- `played_at` es un momento al azar de los últimos `MAX_PLAY_AGE_DAYS` días (modo sin conexión), **en la hora local del teléfono con su desfase** (`-07:00`, Hermosillo), como en el ejemplo del enunciado. Así se prueba de verdad que el processor convierte a UTC antes de sacar el día.
- Los duplicados se programan en una cola por tiempo (un *heap*) con un retraso aleatorio entre 0 y `MAX_DUPLICATE_DELAY_SECONDS`, sin frenar el envío de los originales. Se programan **cuando Kafka confirma el original**, así nunca se envía el duplicado de un mensaje que Kafka no guardó.
- `sent.log` (volumen `sent`) guarda **solo los originales que Kafka confirmó**, sin duplicados. Se abre en modo *append*, así que un reinicio del contenedor no lo borra. Al detenerlo (`docker compose stop producer`), el producer espera las confirmaciones pendientes antes de terminar, para que `sent.log` quede completo.

## Las tablas nuevas (`db/03_play_counts.sql`)

Es una **migración**: un archivo nuevo, porque `01_schema.sql` y `02_seed.sql` ya están aplicados. Con el volumen vacío se ejecuta sola después de ellos (orden alfabético). En una base que ya tiene datos se aplica a mano:

```bash
docker compose exec postgres psql -U admin -d spotify -f /docker-entrypoint-initdb.d/03_play_counts.sql
```

Usa `CREATE TABLE IF NOT EXISTS` y `CREATE INDEX IF NOT EXISTS`, así que se puede ejecutar dos veces sin error.

| Tabla | Llave primaria | Columnas | Responde |
|---|---|---|---|
| `subscriber_song_play` | `(subscriber_id, song_id)` | `subscriber_id integer` FK → `subscribers`, `song_id integer` FK → `songs`, `num_rep integer NOT NULL CHECK (num_rep > 0)` | Las 20 más escuchadas de un suscriptor (desde siempre) |
| `song_daily_play` | `(song_id, play_date)` | `song_id integer` FK → `songs`, `play_date date` (día UTC de `played_at`), `num_rep integer NOT NULL CHECK (num_rep > 0)` | El top 100 semanal |

- `num_rep` es el número de reproducciones válidas y sin duplicados. Una fila existe solo si hubo al menos una, por eso el `CHECK (num_rep > 0)`.
- `integer` alcanza de sobra para los conteos por suscriptor y canción, y por canción y día. Los IDs usan el mismo tipo que en `01_schema.sql`.
- Índice en `song_daily_play (play_date)`: el top semanal filtra un rango de fechas de todas las canciones, y la PK, que empieza por `song_id`, no sirve para ese filtro. Para las 20 más escuchadas basta la PK de `subscriber_song_play`, que empieza por `subscriber_id`.
- Sin `ON DELETE CASCADE`, igual que el resto del esquema.
- Los nombres de las dos tablas los fija el enunciado; siguen la convención de las tablas de unión (`singular_singular`).

## Verificación (`ingestion/verify.py`)

`verify.py` demuestra que los conteos de la base coinciden con los eventos únicos enviados. Compara:

1. **Por canción**, las reproducciones válidas de `sent.log` (los originales, sin duplicados) contra los conteos de la base.
2. **Por canción**, el total de `subscriber_song_play` contra el de `song_daily_play`.
3. Con más detalle: por **(suscriptor, canción)** contra `subscriber_song_play` y por **(canción, día UTC)** contra `song_daily_play`. Esto confirma también la conversión de `played_at` a UTC.

Muestra `OK` si todo coincide o la lista de diferencias. Avisa si el processor todavía no alcanza el final del crudo.

**Se ejecuta en el contenedor del processor**, porque ahí están montados los tres insumos: `sent.log` (volumen `sent`, solo lectura), el crudo y las variables de PostgreSQL.

Procedimiento para obtener la evidencia:

```bash
docker compose down -v                 # partir de cero: la base y sent.log deben ser de la misma ejecución
docker compose up -d --build           # y dejar correr todo al menos 15 minutos
docker compose stop producer           # detener el producer (unos segundos)
# esperar la siguiente corrida del processor (minutos 0, 5, 10... de cada hora)
docker compose exec processor /app/.venv/bin/python /app/ingestion/verify.py
```

Salida obtenida (unos 18 minutos de publicación con los valores de `.env.example`; en ese tiempo el processor descartó 85 duplicados y 163 skips):

```
sent.log: 549 mensajes originales, 386 reproducciones válidas
Base: subscriber_song_play suma 386, song_daily_play suma 386

 song_id   sent.log   subscriber_song_play   song_daily_play
     101         55                     55                55
     102         56                     56                56
     103         43                     43                43
     104         48                     48                48
     105         47                     47                47
     106         54                     54                54
     107         47                     47                47
     108         36                     36                36

1. Por canción, sent.log = base: coincide
2. Por canción, subscriber_song_play = song_daily_play: coincide
3. Por (suscriptor, canción), sent.log = subscriber_song_play: coincide
4. Por (canción, día UTC), sent.log = song_daily_play: coincide

OK
```

Durante esa ejecución también se publicaron a mano en el tópico, con `kafka-console-producer.sh`, mensajes que no siguen las reglas, para probar que el processor funciona con cualquier productor: un texto que no es JSON, un mensaje sin `played_at`, uno con `played_at` sin zona horaria, uno con `subscriber_id` como texto, un suscriptor 999, una canción 999 y una copia de un mensaje ya procesado. El processor descartó cada uno con su motivo, y por eso `verify.py` sigue dando `OK`: ninguno se contó.

**Supuesto de `verify.py`:** que no se eliminó a ningún suscriptor con reproducciones. Al eliminar a uno se borra su `subscriber_song_play`, pero `song_daily_play` no cambia (ver `tests.sql`, c.6), y la comprobación 2 dejaría de cuadrar. Es el comportamiento esperado.

## Qué hace `tests.sql`

Cada sección se titula con `\echo` en la salida.

**a) Las preguntas de Laura**

| # | Pregunta | Resultado |
|---|---|---|
| 1 | ¿Qué canciones tiene la playlist 10, en orden, y quiénes son sus artistas? | 1 Ella Baila Sola (Eslabon Armado, Peso Pluma) · 2 TQG (Karol G, Shakira) · 3 Bzrp Music Sessions #53 (Bizarrap, Shakira) |
| 2 | ¿Cuántos suscriptores tiene cada suscripción, incluidas las que no tienen? | Premium 1 · Gratuita 1 · Familiar 2 · Estudiantes 0 (`LEFT JOIN` + `COUNT(columna)`) |
| 3 | ¿Qué canciones no están en ningún álbum? | 108 Calor de Agosto |
| 4 | ¿Qué tiene guardado cada suscriptor en su biblioteca? | Canciones y álbumes en una sola consulta (`UNION ALL` con columna `tipo`); marta aparece con una fila vacía |
| 5 | ¿Cuál es la canción más escuchada? | En la Tarea 3 no se podía responder; **ahora sí**: suma de `subscriber_song_play` por canción, con `FETCH FIRST 1 ROWS WITH TIES` por si hay empate |
| 6 | **Top 100 semanal** | Suma de `song_daily_play` de la última semana completa (lunes a domingo, UTC), con el lugar de cada canción. Muestra también qué semana es |
| 7 | **Las 20 más escuchadas de un suscriptor** (ana) | `subscriber_song_play` del suscriptor 1, ordenado por `num_rep` |

Con 8 canciones en el catálogo, el «top 100» y las «20 más escuchadas» muestran a lo más 8 filas. Las consultas son las mismas que con un catálogo completo.

**b) Intentos de romper las reglas.** 21 instrucciones que PostgreSQL debe rechazar con `ERROR`, al menos una por cada tipo de restricción y cada una con un comentario sobre la regla de negocio que protege: `PRIMARY KEY` simple y compuesta, `FOREIGN KEY` al insertar, borrar y actualizar, `NOT NULL`, `UNIQUE` simple y compuesto, y `CHECK`. Incluye dos sobre las tablas nuevas: un conteo diario de una canción que no existe (FK) y un conteo de 0 reproducciones (CHECK). Al final, un conteo confirma que ningún intento dejó cambios.

**c) Registro y eliminación de un suscriptor.** Transacciones todo o nada (`BEGIN ... COMMIT`/`ROLLBACK`):

1. **Registro fallido:** se insertan la suscriptora 5 (Sofía) y su perfil, pero la biblioteca reutiliza `library_id = 1` → error → `ROLLBACK`. Una consulta muestra que no quedó nada.
2. **Registro exitoso:** suscriptor, perfil y biblioteca 5 → `COMMIT`.
3. **Preparación:** Sofía crea la playlist 15 con dos canciones, guarda una canción y un álbum, y se le cargan conteos en `subscriber_song_play`. El simulador leyó los suscriptores al iniciar y no la conoce, así que no tiene reproducciones reales; los conteos se cargan solo en esa tabla, para que al borrarla las dos tablas vuelvan a cuadrar.
4. **Eliminación fallida:** con ana se borran sus reproducciones y dependencias, pero se intenta borrar `subscribers` antes que `libraries` y `profiles` → error de llave foránea → `ROLLBACK`. Los conteos antes y después son idénticos.
5. **Eliminación exitosa:** los **ocho** `DELETE` de Sofía en orden de dependencias (`subscriber_song_play`, `library_song`, `library_album`, `playlist_song`, `playlists`, `libraries`, `profiles`, `subscribers`) → `COMMIT`. El catálogo sigue con 8 canciones, 6 álbumes y 11 artistas.
6. **¿Cambia el top semanal al eliminar a un suscriptor? No.** `song_daily_play` guarda cuántas reproducciones tuvo cada canción cada día, pero no quién las hizo: es un agregado anónimo. Las reproducciones del suscriptor eliminado sí ocurrieron y siguen contando para la canción; tampoco se podrían restar, porque no se sabe cuáles fueron suyas. Lo que sí desaparece es su historial personal (sus 20 más escuchadas), y sus mensajes que todavía lleguen por Kafka se descartan. Para demostrarlo con un suscriptor que sí tiene reproducciones, se elimina a ana dentro de una transacción, se compara el top antes y después (**0 diferencias**) y se hace `ROLLBACK`.

**Repetibilidad.** Al terminar, las 14 tablas del catálogo quedan exactamente como las dejó `02_seed.sql`, así que `tests.sql` se puede ejecutar varias veces. Dos ejecuciones seguidas dan la misma salida. Entre ejecuciones separadas por minutos solo cambian los números de las preguntas 5, 6 y 7 y las filas de ana en `subscriber_song_play`, porque el processor sigue sumando reproducciones; la semana del top cambia cada lunes.

Después de ejecutar `tests.sql`, `docker compose logs postgres | grep ERROR` muestra los errores **intencionales** de las pruebas: los 21 intentos de romper las reglas y los dos fallos a propósito dentro de las transacciones.

## Supuestos

**Base de datos (Tarea 3)**

1. Una canción no se repite dentro de una playlist, y cada posición tiene una sola canción.
2. El título y la duración son datos de la canción; no cambian según la playlist o el álbum.
3. Un suscriptor tiene una sola suscripción a la vez, y todos los suscriptores de un plan pagan lo mismo.
4. Un artista aparece una sola vez en los créditos de una canción; su rol es principal o feat.
5. Cada canción tiene un solo género.
6. El código de país (ISO de dos letras) determina su nombre.
7. Una canción aparece una sola vez en un álbum, y cada álbum es de un solo disco: el número de pista no se repite.
8. Cada álbum lo publica un solo artista.
9. Guardar un álbum no equivale a guardar cada una de sus canciones.
10. La foto del perfil es opcional.
11. Se usan llaves sustitutas (`subscription_id`, `subscriber_id`, `profile_id`, `library_id`) porque el nombre del plan y el email pueden cambiar.
12. `profiles` y `libraries` no surgieron al normalizar (relación 1:1 con `subscribers`); se conservan por el diagrama conceptual unificado.
13. Los datos agregados (plan Estudiantes y artista A11) son de prueba, para cubrir casos límite que la base debe soportar.

**Ingesta de reproducciones (Tarea 4)**

14. Una reproducción es válida si `ms_played >= 30000`; las demás son *skips* y no cuentan.
15. Dos mensajes con el mismo `event_id` son la misma reproducción, y un duplicado llega a Kafka a lo más 5 minutos después que el original. El processor recuerda los `event_id` 30 minutos.
16. Los días y las semanas se definen en **UTC**: `play_date` es el día UTC de `played_at`, que es el momento en que ocurrió la reproducción y no el de llegada del mensaje. Un `played_at` sin zona horaria se descarta, porque no se puede saber su día UTC.
17. La semana va de lunes a domingo, y el top semanal es el de la última semana **completa**; la semana en curso no cuenta.
18. En el top semanal y en las 20 más escuchadas, los empates se desempatan por `song_id`, para que el orden sea siempre el mismo. En la pregunta 5 los empates se muestran todos.
19. Los mensajes de suscriptores o canciones que no existen en la base se descartan, incluidos los de un suscriptor ya eliminado.
20. Eliminar a un suscriptor borra su historial (`subscriber_song_play`), pero no cambia el top semanal: `song_daily_play` es un agregado anónimo por canción y día.
21. El simulador lee el catálogo solo al iniciar: un suscriptor o una canción nuevos entran a la simulación hasta que se reinicia el producer.

Los supuestos también están en los comentarios del SQL y de los programas, junto al código al que afectan.

## Estructura del repositorio

```
.
├── app_simulator/
│   └── producer.py            # Simula la app: publica reproducciones, skips y duplicados; escribe sent.log
├── ingestion/
│   ├── consumer.py            # Kafka → crudo, tal cual
│   ├── processor.py           # Crudo → conteos en PostgreSQL (cada 5 min con cron)
│   ├── verify.py              # Compara los conteos con sent.log
│   └── crontab                # Horario del processor: */5 * * * *
├── db/
│   ├── 01_schema.sql          # CREATE TABLE de las 14 tablas del catálogo, en orden de dependencias
│   ├── 02_seed.sql            # INSERT de los datos de Laura y los casos agregados
│   └── 03_play_counts.sql     # Migración: subscriber_song_play y song_daily_play
├── docs/
│   ├── diagrama_conceptual.png
│   └── diagrama_er.png        # Incluye las dos tablas nuevas
├── .env.example               # Plantilla de variables (el .env real no se sube)
├── .gitignore
├── .python-version            # Python 3.13, el de la imagen
├── Dockerfile                 # Imagen de los tres programas (python:3.13-slim + cron + uv)
├── docker-compose.yml         # Los cinco servicios y los volúmenes datos, crudo, logs y sent
├── pyproject.toml             # Dependencias: confluent-kafka y psycopg
├── uv.lock                    # Versiones exactas de las dependencias
├── tests.sql                  # Preguntas de Laura, intentos de romper reglas y transacciones
└── README.md
```

### Diagrama conceptual

Diagrama unificado con las entidades y relaciones, incluida `countries`, que surgió al normalizar (línea azul punteada).

![Diagrama conceptual](docs/diagrama_conceptual.png)

### Diagrama ER

Atributos, tipos de dato, PK y FK. Coincide con `db/01_schema.sql` y `db/03_play_counts.sql`. Las dos tablas nuevas son `subscriber_song_play` (entre `subscribers` y `songs`) y `song_daily_play` (abajo a la izquierda, ligada a `songs`).

![Diagrama ER](docs/diagrama_er.png)

## Cardinalidades y restricciones

Cada cardinalidad del diagrama se traduce en restricciones:

| Cardinalidad | Restricción |
|---|---|
| Mínimo 1 del lado «uno» (toda fila hija tiene padre) | FK `NOT NULL` (p. ej. `playlists.subscriber_id`, `subscribers.subscription_id`, `albums.artist_id`, `song_daily_play.song_id`) |
| Máximo 1 del lado dependiente de una 1:1 | `UNIQUE` en la FK (`profiles.subscriber_id`, `libraries.subscriber_id`) |
| Relaciones N:M | Tabla de unión con PK compuesta (el par no se repite) y una FK a cada lado (incluida `subscriber_song_play`) |

Otras reglas de negocio implementadas: `UNIQUE (playlist_id, position)` y `UNIQUE (album_id, track_number)`; emails, nombres de plan y nombres de país únicos; y `CHECK` para el precio ≥ 0, el formato del email, el código de país de dos letras mayúsculas, la duración > 0, el año entre 1900 y 2100, la posición y la pista > 0, el rol en `('principal', 'feat.')` y `num_rep > 0` en las dos tablas de conteos.

Ninguna llave foránea usa `ON DELETE CASCADE`: borrar un suscriptor exige borrar sus dependencias de forma explícita y en orden, y no se puede borrar del catálogo algo que está en uso.

### Cardinalidades que no se pueden garantizar con restricciones

- **Todo álbum tiene al menos una canción y toda canción al menos un artista** (mínimo 1 del lado «muchos» de `song_album` y `song_artist`). Forzarlo requeriría triggers, que están fuera del alcance. Se cumple en los datos cargados.
- **Todo suscriptor tiene perfil y biblioteca** (mínimo 1 del lado del suscriptor en las relaciones 1:1). Una FK solo puede ir en una dirección, así que se garantiza con la **transacción de registro** de `tests.sql`, que crea los tres o ninguno.

## Cambios respecto al diagrama ER

- **Tarea 3:** ninguno. El esquema implementó exactamente el diagrama ER diseñado previamente.
- **Tarea 4:** se agregaron `subscriber_song_play` y `song_daily_play` con la migración `db/03_play_counts.sql`, y el diagrama ER (`docs/diagrama_er.png`) se actualizó con las dos tablas y sus relaciones. Las 14 tablas anteriores no cambiaron (`01_schema.sql` y `02_seed.sql` no se editaron).
