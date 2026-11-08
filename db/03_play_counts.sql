-- =====================================================================
-- 03_play_counts.sql · Migración: conteos de reproducciones
-- =====================================================================
-- Agrega las dos tablas que la app necesita para el top 100 semanal y
-- las 20 canciones más escuchadas de cada suscriptor.
--
--   * Las reproducciones NO se guardan aquí: cada mensaje de Kafka se
--     queda en el crudo (archivos fuera de la base). PostgreSQL solo
--     guarda los conteos que el processor actualiza cada 5 minutos.
--   * num_rep cuenta solo reproducciones válidas (ms_played >= 30000) y
--     sin duplicados (mismo event_id = misma reproducción).
--   * Los nombres de las dos tablas los fija el enunciado; siguen la
--     convención de las tablas de unión (singular_singular).
--   * Igual que en 01_schema.sql, ninguna FK lleva ON DELETE CASCADE.
--
-- Es una migración: se aplica sola cuando el volumen está vacío (después
-- de 01_ y 02_, por orden alfabético) y, con datos, a mano con psql. Por
-- eso puede ejecutarse dos veces sin error (IF NOT EXISTS) y, una vez
-- aplicada, no se edita: un cambio posterior va en 04_....
-- =====================================================================


-- ---------------------------------------------------------------------
-- subscriber_song_play: cuántas veces ha escuchado cada suscriptor cada
-- canción, desde siempre. Responde «las 20 más escuchadas» (regla 5).
-- subscribers 1..1 <-> 0..N y songs 1..1 <-> 0..N -> PK compuesta + 2 FK.
-- Solo existe una fila si el suscriptor tiene al menos una reproducción
-- válida de esa canción -> num_rep > 0.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS subscriber_song_play (
    subscriber_id integer NOT NULL,
    song_id       integer NOT NULL,
    num_rep       integer NOT NULL,
    CONSTRAINT subscriber_song_play_pkey             PRIMARY KEY (subscriber_id, song_id),
    CONSTRAINT subscriber_song_play_num_rep_positive CHECK (num_rep > 0),
    CONSTRAINT subscriber_song_play_subscriber_fkey  FOREIGN KEY (subscriber_id)
        REFERENCES subscribers (subscriber_id),
    CONSTRAINT subscriber_song_play_song_fkey        FOREIGN KEY (song_id)
        REFERENCES songs (song_id)
);


-- ---------------------------------------------------------------------
-- song_daily_play: cuántas reproducciones válidas tuvo cada canción cada
-- día. Responde el top 100 semanal (regla 4).
-- play_date es el día en UTC en que ocurrió la reproducción (played_at
-- convertido a UTC), no el día en que llegó el mensaje (regla 3).
-- No guarda quién escuchó: es un agregado anónimo por canción y día.
-- songs 1..1 <-> 0..N song_daily_play -> FK.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS song_daily_play (
    song_id   integer NOT NULL,
    play_date date    NOT NULL,
    num_rep   integer NOT NULL,
    CONSTRAINT song_daily_play_pkey             PRIMARY KEY (song_id, play_date),
    CONSTRAINT song_daily_play_num_rep_positive CHECK (num_rep > 0),
    CONSTRAINT song_daily_play_song_fkey        FOREIGN KEY (song_id)
        REFERENCES songs (song_id)
);

-- El top semanal filtra por un rango de fechas de todas las canciones;
-- la PK empieza por song_id y no sirve para ese filtro.
CREATE INDEX IF NOT EXISTS song_daily_play_play_date_idx
    ON song_daily_play (play_date);
