-- =====================================================================
-- tests.sql · Pruebas de la BD de Spotify
-- =====================================================================
-- Ejecutar con:
--   docker compose exec postgres psql -U admin -d spotify -f /tests.sql
--
-- Secciones:
--   a) Las 5 preguntas de Laura.
--   b) Intentos de romper las reglas: cada uno DEBE terminar en ERROR.
--   c) Registro y eliminación de un suscriptor con transacciones
--      todo o nada (caso exitoso, caso fallido y verificación).
--
-- No se activa ON_ERROR_STOP: fuera de una transacción, un error solo
-- cancela esa instrucción y psql sigue con la siguiente.
--
-- El archivo se puede ejecutar varias veces con la misma salida: lo que
-- se modifica con éxito (la suscriptora 5, Sofía) se borra al final, y
-- la base termina exactamente como la dejó db/02_seed.sql.
-- =====================================================================


\echo
\echo '#####################################################################'
\echo '# a) LAS PREGUNTAS DE LAURA'
\echo '#####################################################################'

-- ---------------------------------------------------------------------
-- Pregunta 1: ¿Qué canciones tiene la playlist 10, en orden, y quiénes
-- son sus artistas?
-- Se recorre playlist_song -> songs -> song_artist -> artists y se
-- agregan los artistas de cada canción en una sola celda, con el
-- principal primero.
-- Esperado: 1 Ella Baila Sola, 2 TQG, 3 Bzrp Music Sessions #53.
-- ---------------------------------------------------------------------
\echo
\echo '=== Pregunta 1: canciones de la playlist 10, en orden, con sus artistas ==='
SELECT ps.position AS posicion,
       s.title     AS cancion,
       string_agg(a.name || ' (' || sa.role || ')', ', '
                  ORDER BY sa.role <> 'principal', a.name) AS artistas
FROM playlist_song ps
JOIN songs       s  ON s.song_id    = ps.song_id
JOIN song_artist sa ON sa.song_id   = s.song_id
JOIN artists     a  ON a.artist_id  = sa.artist_id
WHERE ps.playlist_id = 10
GROUP BY ps.position, s.title
ORDER BY ps.position;

-- ---------------------------------------------------------------------
-- Pregunta 2: ¿Cuántos suscriptores tiene cada suscripción? Que
-- aparezcan también las que no tienen ninguno.
-- LEFT JOIN conserva las suscripciones sin suscriptores, y
-- COUNT(sb.subscriber_id) no cuenta los NULL que deja el LEFT JOIN
-- (COUNT(*) contaría 1 para «Estudiantes»).
-- Esperado: Premium 1, Gratuita 1, Familiar 2, Estudiantes 0.
-- ---------------------------------------------------------------------
\echo
\echo '=== Pregunta 2: suscriptores por suscripción (incluye las que no tienen) ==='
SELECT su.name                   AS suscripcion,
       COUNT(sb.subscriber_id)   AS suscriptores
FROM subscriptions su
LEFT JOIN subscribers sb ON sb.subscription_id = su.subscription_id
GROUP BY su.subscription_id, su.name
ORDER BY su.subscription_id;

-- ---------------------------------------------------------------------
-- Pregunta 3: ¿Qué canciones no están en ningún álbum?
-- Canciones sin ninguna fila en song_album.
-- Esperado: solo la 108, Calor de Agosto.
-- ---------------------------------------------------------------------
\echo
\echo '=== Pregunta 3: canciones que no están en ningún álbum ==='
SELECT s.song_id, s.title AS cancion
FROM songs s
WHERE NOT EXISTS (SELECT 1 FROM song_album sa WHERE sa.song_id = s.song_id)
ORDER BY s.song_id;

-- ---------------------------------------------------------------------
-- Pregunta 4: ¿Qué tiene guardado cada suscriptor en su biblioteca,
-- tanto canciones como álbumes?
-- UNION ALL junta canciones y álbumes guardados en una sola lista con
-- una columna «tipo». Esa lista se une con LEFT JOIN desde cada
-- suscriptor, así quien no tiene nada guardado (Marta) aparece con una
-- fila vacía.
-- Esperado: ana (TQG, Flowers, Un Verano Sin Ti), luis (Bzrp Music
-- Sessions #53, SOS, Las Mujeres Ya No Lloran), marta (nada),
-- diego (Ella Baila Sola, Calor de Agosto).
-- ---------------------------------------------------------------------
\echo
\echo '=== Pregunta 4: biblioteca de cada suscriptor (canciones y álbumes) ==='
SELECT sb.email      AS suscriptor,
       guardado.tipo,
       guardado.titulo
FROM subscribers sb
JOIN libraries l ON l.subscriber_id = sb.subscriber_id
LEFT JOIN (
    SELECT ls.library_id, 'canción' AS tipo, s.title AS titulo
    FROM library_song ls
    JOIN songs s ON s.song_id = ls.song_id
    UNION ALL
    SELECT la.library_id, 'álbum' AS tipo, al.title AS titulo
    FROM library_album la
    JOIN albums al ON al.album_id = la.album_id
) AS guardado ON guardado.library_id = l.library_id
ORDER BY sb.subscriber_id, guardado.tipo <> 'canción', guardado.titulo;

-- ---------------------------------------------------------------------
-- Pregunta 5: ¿Cuál es la canción más escuchada?
-- NO SE PUEDE RESPONDER con esta base: no guarda reproducciones. Solo
-- sabemos en qué playlists y bibliotecas está cada canción, y eso no
-- dice cuántas veces se escuchó.
--
-- Haría falta una tabla de reproducciones, por ejemplo:
--
--   CREATE TABLE plays (
--       play_id       bigint    PRIMARY KEY,
--       subscriber_id integer   NOT NULL REFERENCES subscribers (subscriber_id),
--       song_id       integer   NOT NULL REFERENCES songs (song_id),
--       played_at     timestamp NOT NULL
--   );
--
-- y con ella la consulta sería:
--
--   SELECT s.song_id, s.title, COUNT(*) AS reproducciones
--   FROM plays p
--   JOIN songs s ON s.song_id = p.song_id
--   GROUP BY s.song_id, s.title
--   ORDER BY reproducciones DESC
--   LIMIT 1;
--
-- No se ejecuta nada aquí porque la tabla plays no existe.
-- ---------------------------------------------------------------------
\echo
\echo '=== Pregunta 5: ¿cuál es la canción más escuchada? ==='
\echo 'No se puede responder: la base no guarda reproducciones.'
\echo 'Haría falta una tabla plays(play_id, subscriber_id, song_id, played_at);'
\echo 'la tabla propuesta y la consulta de ejemplo están comentadas en tests.sql.'


\echo
\echo '#####################################################################'
\echo '# b) INTENTOS DE ROMPER LAS REGLAS (todos deben mostrar ERROR)'
\echo '#####################################################################'

-- ---------------------------------------------------------------------
-- PRIMARY KEY: cada canción se identifica de forma única.
-- Ya existe la canción 101.
-- ---------------------------------------------------------------------
\echo
\echo '--- PRIMARY KEY: otra canción con song_id = 101 ---'
INSERT INTO songs (song_id, title, duration_seconds, genre)
VALUES (101, 'Canción duplicada', 180, 'Pop');

-- ---------------------------------------------------------------------
-- PRIMARY KEY compuesta: una canción no se repite dentro de una
-- playlist (supuesto 1). (10, 101) ya existe; la posición 9 está libre,
-- así que lo único que se viola es la PK.
-- ---------------------------------------------------------------------
\echo
\echo '--- PRIMARY KEY compuesta: repetir (10, 101) en playlist_song ---'
INSERT INTO playlist_song (playlist_id, song_id, position, added_at)
VALUES (10, 101, 9, '2026-11-01');

-- ---------------------------------------------------------------------
-- FOREIGN KEY (insert): toda playlist pertenece a un suscriptor que
-- existe. No hay suscriptor 999.
-- ---------------------------------------------------------------------
\echo
\echo '--- FOREIGN KEY (insert): playlist de un suscriptor que no existe (999) ---'
INSERT INTO playlists (playlist_id, name, created_at, subscriber_id)
VALUES (99, 'Playlist fantasma', '2026-11-01', 999);

-- ---------------------------------------------------------------------
-- FOREIGN KEY (delete): no se borra del catálogo algo que está en uso.
-- La canción 102 está en playlists, álbumes, créditos y bibliotecas;
-- sin ON DELETE CASCADE, PostgreSQL rechaza el borrado.
-- ---------------------------------------------------------------------
\echo
\echo '--- FOREIGN KEY (delete): borrar la canción 102, que está en uso ---'
DELETE FROM songs WHERE song_id = 102;

-- ---------------------------------------------------------------------
-- FOREIGN KEY (update): un suscriptor no puede cambiarse a un plan que
-- no existe.
-- ---------------------------------------------------------------------
\echo
\echo '--- FOREIGN KEY (update): mover a ana a una suscripción inexistente (99) ---'
UPDATE subscribers SET subscription_id = 99 WHERE subscriber_id = 1;

-- ---------------------------------------------------------------------
-- NOT NULL: mínimo 1 de subscribers -> playlists; toda playlist tiene
-- dueño.
-- ---------------------------------------------------------------------
\echo
\echo '--- NOT NULL: playlist sin subscriber_id ---'
INSERT INTO playlists (playlist_id, name, created_at, subscriber_id)
VALUES (98, 'Playlist sin dueño', '2026-11-01', NULL);

-- ---------------------------------------------------------------------
-- UNIQUE: máximo 1 en subscribers -> profiles; un suscriptor tiene un
-- solo perfil.
-- ---------------------------------------------------------------------
\echo
\echo '--- UNIQUE: segundo perfil para el suscriptor 1 ---'
INSERT INTO profiles (profile_id, subscriber_id, display_name, photo, country_code)
VALUES (99, 1, 'ana_otra', NULL, 'MX');

-- ---------------------------------------------------------------------
-- UNIQUE: máximo 1 en subscribers -> libraries; un suscriptor tiene una
-- sola biblioteca.
-- ---------------------------------------------------------------------
\echo
\echo '--- UNIQUE: segunda biblioteca para el suscriptor 1 ---'
INSERT INTO libraries (library_id, subscriber_id)
VALUES (99, 1);

-- ---------------------------------------------------------------------
-- UNIQUE: el email identifica a una sola cuenta.
-- ---------------------------------------------------------------------
\echo
\echo '--- UNIQUE: otro suscriptor con ana@mail.com ---'
INSERT INTO subscribers (subscriber_id, email, registered_at, subscription_id)
VALUES (99, 'ana@mail.com', '2026-11-01', 1);

-- ---------------------------------------------------------------------
-- UNIQUE: no hay dos planes con el mismo nombre.
-- ---------------------------------------------------------------------
\echo
\echo '--- UNIQUE: otra suscripción llamada Premium ---'
INSERT INTO subscriptions (subscription_id, name, monthly_price, has_ads)
VALUES (99, 'Premium', 99.00, false);

-- ---------------------------------------------------------------------
-- UNIQUE compuesto: cada posición de una playlist tiene una sola canción
-- (supuesto 1). La posición 1 de la playlist 10 ya está ocupada.
-- ---------------------------------------------------------------------
\echo
\echo '--- UNIQUE (playlist_id, position): otra canción en la posición 1 de la playlist 10 ---'
INSERT INTO playlist_song (playlist_id, song_id, position, added_at)
VALUES (10, 104, 1, '2026-11-01');

-- ---------------------------------------------------------------------
-- UNIQUE compuesto: el número de pista no se repite en un álbum
-- (supuesto 7). La pista 3 de Un Verano Sin Ti ya existe.
-- ---------------------------------------------------------------------
\echo
\echo '--- UNIQUE (album_id, track_number): repetir la pista 3 del álbum 205 ---'
INSERT INTO song_album (song_id, album_id, track_number)
VALUES (108, 205, 3);

-- ---------------------------------------------------------------------
-- CHECK: un plan no puede costar menos de 0.
-- ---------------------------------------------------------------------
\echo
\echo '--- CHECK: suscripción con precio negativo ---'
INSERT INTO subscriptions (subscription_id, name, monthly_price, has_ads)
VALUES (98, 'Plan pirata', -10.00, true);

-- ---------------------------------------------------------------------
-- CHECK: el rol en los créditos solo puede ser 'principal' o 'feat.'
-- (supuesto 4).
-- ---------------------------------------------------------------------
\echo
\echo '--- CHECK: rol productor en song_artist ---'
INSERT INTO song_artist (song_id, artist_id, role)
VALUES (104, 'A11', 'productor');

-- ---------------------------------------------------------------------
-- CHECK: el email debe tener la forma algo@algo.
-- ---------------------------------------------------------------------
\echo
\echo '--- CHECK: email sin arroba ---'
INSERT INTO subscribers (subscriber_id, email, registered_at, subscription_id)
VALUES (98, 'correo-sin-arroba', '2026-11-01', 1);

-- ---------------------------------------------------------------------
-- CHECK: el código de país son dos letras mayúsculas (ISO alfa-2).
-- ---------------------------------------------------------------------
\echo
\echo '--- CHECK: código de país en minúsculas ---'
INSERT INTO countries (country_code, name)
VALUES ('cl', 'Chile');

-- ---------------------------------------------------------------------
-- CHECK: una canción dura más de 0 segundos.
-- ---------------------------------------------------------------------
\echo
\echo '--- CHECK: duración de 0 segundos ---'
UPDATE songs SET duration_seconds = 0 WHERE song_id = 104;

-- ---------------------------------------------------------------------
-- CHECK: el año de lanzamiento debe ser razonable (1900-2100).
-- ---------------------------------------------------------------------
\echo
\echo '--- CHECK: álbum del año 2500 ---'
INSERT INTO albums (album_id, title, release_year, cover, artist_id)
VALUES (299, 'Álbum del futuro', 2500, 'futuro.jpg', 'A11');

-- ---------------------------------------------------------------------
-- CHECK: las posiciones dentro de una playlist empiezan en 1.
-- ---------------------------------------------------------------------
\echo
\echo '--- CHECK: posición 0 en una playlist ---'
UPDATE playlist_song SET position = 0 WHERE playlist_id = 10 AND song_id = 101;

-- ---------------------------------------------------------------------
-- Verificación: ninguno de los intentos anteriores dejó cambios.
-- Deben verse los mismos conteos que dejó 02_seed.sql.
-- ---------------------------------------------------------------------
\echo
\echo '--- Verificación: ningún intento dejó cambios (conteos del seed) ---'
SELECT (SELECT count(*) FROM countries)     AS countries,
       (SELECT count(*) FROM subscriptions) AS subscriptions,
       (SELECT count(*) FROM subscribers)   AS subscribers,
       (SELECT count(*) FROM profiles)      AS profiles,
       (SELECT count(*) FROM libraries)     AS libraries,
       (SELECT count(*) FROM playlists)     AS playlists,
       (SELECT count(*) FROM songs)         AS songs,
       (SELECT count(*) FROM albums)        AS albums,
       (SELECT count(*) FROM song_album)    AS song_album,
       (SELECT count(*) FROM playlist_song) AS playlist_song,
       (SELECT count(*) FROM song_artist)   AS song_artist;


\echo
\echo '#####################################################################'
\echo '# c) REGISTRO Y ELIMINACIÓN DE UN SUSCRIPTOR (transacciones todo o nada)'
\echo '#####################################################################'

-- =====================================================================
-- REGISTRO: crea al suscriptor, su perfil y su biblioteca en una sola
-- transacción. Nunca puede quedar un suscriptor sin perfil o sin
-- biblioteca: si cualquiera de los tres INSERT falla, ROLLBACK deshace
-- los tres.
-- =====================================================================

-- ---------------------------------------------------------------------
-- c.1 Registro fallido: el suscriptor y el perfil se insertan bien,
-- pero la biblioteca usa library_id = 1 (ya es de ana) y viola la PK.
-- La transacción queda abortada y ROLLBACK deshace también al
-- suscriptor y su perfil.
-- ---------------------------------------------------------------------
\echo
\echo '=== c.1 Registro fallido de Sofía (la biblioteca reutiliza library_id = 1) ==='
BEGIN;
INSERT INTO subscribers (subscriber_id, email, registered_at, subscription_id)
VALUES (5, 'sofia@mail.com', '2026-11-02', 2);
INSERT INTO profiles (profile_id, subscriber_id, display_name, photo, country_code)
VALUES (5, 5, 'sofi.m', 's5.jpg', 'MX');
INSERT INTO libraries (library_id, subscriber_id)
VALUES (1, 5);
ROLLBACK;

\echo '--- Verificación: Sofía no quedó registrada a medias (todo en 0) ---'
SELECT (SELECT count(*) FROM subscribers WHERE subscriber_id = 5) AS subscribers,
       (SELECT count(*) FROM profiles    WHERE subscriber_id = 5) AS profiles,
       (SELECT count(*) FROM libraries   WHERE subscriber_id = 5) AS libraries;

-- ---------------------------------------------------------------------
-- c.2 Registro exitoso: suscriptor 5, perfil 5 y biblioteca 5.
-- ---------------------------------------------------------------------
\echo
\echo '=== c.2 Registro exitoso de Sofía ==='
BEGIN;
INSERT INTO subscribers (subscriber_id, email, registered_at, subscription_id)
VALUES (5, 'sofia@mail.com', '2026-11-02', 2);
INSERT INTO profiles (profile_id, subscriber_id, display_name, photo, country_code)
VALUES (5, 5, 'sofi.m', 's5.jpg', 'MX');
INSERT INTO libraries (library_id, subscriber_id)
VALUES (5, 5);
COMMIT;

\echo '--- Verificación: existen el suscriptor, su perfil y su biblioteca ---'
SELECT sb.subscriber_id, sb.email, su.name AS suscripcion,
       p.profile_id, p.display_name, l.library_id
FROM subscribers sb
JOIN subscriptions su ON su.subscription_id = sb.subscription_id
JOIN profiles      p  ON p.subscriber_id    = sb.subscriber_id
JOIN libraries     l  ON l.subscriber_id    = sb.subscriber_id
WHERE sb.subscriber_id = 5;

-- ---------------------------------------------------------------------
-- c.3 Preparación: Sofía crea la playlist 15 con dos canciones y guarda
-- una canción y un álbum, para que su eliminación tenga qué borrar.
-- ---------------------------------------------------------------------
\echo
\echo '=== c.3 Preparación: playlist 15 y biblioteca de Sofía ==='
INSERT INTO playlists (playlist_id, name, created_at, subscriber_id)
VALUES (15, 'Para correr', '2026-11-02', 5);
INSERT INTO playlist_song (playlist_id, song_id, position, added_at) VALUES
    (15, 105, 1, '2026-11-02'),
    (15, 106, 2, '2026-11-02');
INSERT INTO library_song (library_id, song_id)   VALUES (5, 107);
INSERT INTO library_album (library_id, album_id) VALUES (5, 203);

-- =====================================================================
-- ELIMINACIÓN: borra al suscriptor y todo lo que depende de él, sin
-- ON DELETE CASCADE: cada DELETE es explícito y va en orden de
-- dependencias (primero las filas que apuntan a otras):
--   library_song, library_album, playlist_song, playlists, libraries,
--   profiles, subscribers.
-- Solo se borran filas del suscriptor; ninguna canción, álbum ni
-- artista del catálogo.
-- =====================================================================

-- ---------------------------------------------------------------------
-- c.4 Eliminación fallida (ana, suscriptora 1): se borran sus
-- canciones y álbumes guardados y sus playlists, pero se intenta borrar
-- al suscriptor ANTES que su biblioteca y su perfil. La FK lo rechaza y
-- ROLLBACK deshace también lo que ya se había borrado.
-- ---------------------------------------------------------------------
\echo
\echo '=== c.4 Eliminación fallida de ana (se borra subscribers antes que libraries y profiles) ==='
\echo '--- Filas de ana ANTES ---'
SELECT t.tabla, t.filas
FROM (VALUES
    (1, 'library_song',  (SELECT count(*) FROM library_song  WHERE library_id  IN (SELECT library_id  FROM libraries WHERE subscriber_id = 1))),
    (2, 'library_album', (SELECT count(*) FROM library_album WHERE library_id  IN (SELECT library_id  FROM libraries WHERE subscriber_id = 1))),
    (3, 'playlist_song', (SELECT count(*) FROM playlist_song WHERE playlist_id IN (SELECT playlist_id FROM playlists WHERE subscriber_id = 1))),
    (4, 'playlists',     (SELECT count(*) FROM playlists     WHERE subscriber_id = 1)),
    (5, 'libraries',     (SELECT count(*) FROM libraries     WHERE subscriber_id = 1)),
    (6, 'profiles',      (SELECT count(*) FROM profiles      WHERE subscriber_id = 1)),
    (7, 'subscribers',   (SELECT count(*) FROM subscribers   WHERE subscriber_id = 1))
) AS t(orden, tabla, filas)
ORDER BY t.orden;

BEGIN;
DELETE FROM library_song  WHERE library_id  IN (SELECT library_id  FROM libraries WHERE subscriber_id = 1);
DELETE FROM library_album WHERE library_id  IN (SELECT library_id  FROM libraries WHERE subscriber_id = 1);
DELETE FROM playlist_song WHERE playlist_id IN (SELECT playlist_id FROM playlists WHERE subscriber_id = 1);
DELETE FROM playlists     WHERE subscriber_id = 1;
-- Error a medio camino: libraries y profiles todavía apuntan a ana.
DELETE FROM subscribers   WHERE subscriber_id = 1;
ROLLBACK;

\echo '--- Filas de ana DESPUÉS (deben ser idénticas a ANTES) ---'
SELECT t.tabla, t.filas
FROM (VALUES
    (1, 'library_song',  (SELECT count(*) FROM library_song  WHERE library_id  IN (SELECT library_id  FROM libraries WHERE subscriber_id = 1))),
    (2, 'library_album', (SELECT count(*) FROM library_album WHERE library_id  IN (SELECT library_id  FROM libraries WHERE subscriber_id = 1))),
    (3, 'playlist_song', (SELECT count(*) FROM playlist_song WHERE playlist_id IN (SELECT playlist_id FROM playlists WHERE subscriber_id = 1))),
    (4, 'playlists',     (SELECT count(*) FROM playlists     WHERE subscriber_id = 1)),
    (5, 'libraries',     (SELECT count(*) FROM libraries     WHERE subscriber_id = 1)),
    (6, 'profiles',      (SELECT count(*) FROM profiles      WHERE subscriber_id = 1)),
    (7, 'subscribers',   (SELECT count(*) FROM subscribers   WHERE subscriber_id = 1))
) AS t(orden, tabla, filas)
ORDER BY t.orden;

-- ---------------------------------------------------------------------
-- c.5 Eliminación exitosa (Sofía, suscriptora 5): los siete DELETE en
-- orden de dependencias. Al terminar, la base queda igual que después
-- de 02_seed.sql, y por eso tests.sql se puede volver a ejecutar.
-- ---------------------------------------------------------------------
\echo
\echo '=== c.5 Eliminación exitosa de Sofía (siete DELETE en orden) ==='
BEGIN;
DELETE FROM library_song  WHERE library_id  IN (SELECT library_id  FROM libraries WHERE subscriber_id = 5);
DELETE FROM library_album WHERE library_id  IN (SELECT library_id  FROM libraries WHERE subscriber_id = 5);
DELETE FROM playlist_song WHERE playlist_id IN (SELECT playlist_id FROM playlists WHERE subscriber_id = 5);
DELETE FROM playlists     WHERE subscriber_id = 5;
DELETE FROM libraries     WHERE subscriber_id = 5;
DELETE FROM profiles      WHERE subscriber_id = 5;
DELETE FROM subscribers   WHERE subscriber_id = 5;
COMMIT;

\echo '--- Verificación: no queda nada de Sofía (todo en 0) ---'
SELECT (SELECT count(*) FROM subscribers   WHERE subscriber_id = 5) AS subscribers,
       (SELECT count(*) FROM profiles      WHERE subscriber_id = 5) AS profiles,
       (SELECT count(*) FROM libraries     WHERE library_id    = 5) AS libraries,
       (SELECT count(*) FROM library_song  WHERE library_id    = 5) AS library_song,
       (SELECT count(*) FROM library_album WHERE library_id    = 5) AS library_album,
       (SELECT count(*) FROM playlists     WHERE playlist_id   = 15) AS playlists,
       (SELECT count(*) FROM playlist_song WHERE playlist_id   = 15) AS playlist_song;

\echo '--- Verificación: el catálogo sigue completo (8 canciones, 6 álbumes, 11 artistas) ---'
SELECT (SELECT count(*) FROM songs)   AS songs,
       (SELECT count(*) FROM albums)  AS albums,
       (SELECT count(*) FROM artists) AS artists;


\echo
\echo '#####################################################################'
\echo '# ESTADO FINAL: igual que después de 02_seed.sql'
\echo '#####################################################################'

-- ---------------------------------------------------------------------
-- Conteo de las 14 tablas. Debe coincidir con los conteos del seed:
-- 5, 4, 4, 4, 4, 5, 8, 11, 6, 10, 12, 8, 5, 3.
-- ---------------------------------------------------------------------
SELECT t.tabla, t.filas
FROM (VALUES
    ( 1, 'countries',     (SELECT count(*) FROM countries)),
    ( 2, 'subscriptions', (SELECT count(*) FROM subscriptions)),
    ( 3, 'subscribers',   (SELECT count(*) FROM subscribers)),
    ( 4, 'profiles',      (SELECT count(*) FROM profiles)),
    ( 5, 'libraries',     (SELECT count(*) FROM libraries)),
    ( 6, 'playlists',     (SELECT count(*) FROM playlists)),
    ( 7, 'songs',         (SELECT count(*) FROM songs)),
    ( 8, 'artists',       (SELECT count(*) FROM artists)),
    ( 9, 'albums',        (SELECT count(*) FROM albums)),
    (10, 'playlist_song', (SELECT count(*) FROM playlist_song)),
    (11, 'song_artist',   (SELECT count(*) FROM song_artist)),
    (12, 'song_album',    (SELECT count(*) FROM song_album)),
    (13, 'library_song',  (SELECT count(*) FROM library_song)),
    (14, 'library_album', (SELECT count(*) FROM library_album))
) AS t(orden, tabla, filas)
ORDER BY t.orden;
