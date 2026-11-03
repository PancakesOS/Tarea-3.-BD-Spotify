-- =====================================================================
-- 02_seed.sql · Datos iniciales
-- =====================================================================
-- Carga TODOS los datos de las tablas A, B, C y D que entregó Laura
-- (exports del sistema anterior), conservando sus identificadores:
-- song_id, album_id, artist_id y playlist_id.
--
-- Transformaciones aplicadas a los datos de Laura:
--   * Duración «m:ss» -> segundos (p. ej. 2:45 -> 165).
--   * Anuncios «sí»/«no» -> true/false.
--   * Foto vacía -> NULL (la foto es opcional, supuesto 10).
--   * El rol se conserva tal cual: 'principal' o 'feat.'.
--   * subscriptions, subscribers, profiles y libraries usan IDs nuevos;
--     profile_id y library_id coinciden con subscriber_id.
--
-- Datos agregados para cubrir casos límite de la base (supuesto 13,
-- son datos de prueba):
--   * Suscripción sin suscriptores: plan «Estudiantes» (subscription_id 4).
--   * Artista sin canciones ni álbumes: A11 Natanael Cano.
-- Casos que ya existen en los datos de Laura:
--   * Playlist vacía: 13 (Viaje).
--   * Canción sin álbum: 108 (Calor de Agosto).
--
-- Se inserta en orden de dependencias (igual que 01_schema.sql).
-- Conteos esperados al terminar: 5 countries, 4 subscriptions,
-- 4 subscribers, 4 profiles, 4 libraries, 5 playlists, 8 songs,
-- 11 artists, 6 albums, 10 playlist_song, 12 song_artist, 8 song_album,
-- 5 library_song, 3 library_album.
-- =====================================================================


-- ---------------------------------------------------------------------
-- countries: los países que aparecen en las tablas B y D.
-- ---------------------------------------------------------------------
INSERT INTO countries (country_code, name) VALUES
    ('AR', 'Argentina'),
    ('CO', 'Colombia'),
    ('MX', 'México'),
    ('PR', 'Puerto Rico'),
    ('US', 'Estados Unidos');


-- ---------------------------------------------------------------------
-- subscriptions: los tres planes de la tabla A (precio en MXN al mes)
-- más «Estudiantes», el caso «suscripción sin suscriptores».
-- ---------------------------------------------------------------------
INSERT INTO subscriptions (subscription_id, name, monthly_price, has_ads) VALUES
    (1, 'Premium',     129.00, false),
    (2, 'Gratuita',      0.00, true),
    (3, 'Familiar',    199.00, false),
    (4, 'Estudiantes',  69.00, false);


-- ---------------------------------------------------------------------
-- subscribers, profiles y libraries: tabla D. Cada suscriptor recibe su
-- perfil y su biblioteca con el mismo ID.
-- ---------------------------------------------------------------------
INSERT INTO subscribers (subscriber_id, email, registered_at, subscription_id) VALUES
    (1, 'ana@mail.com',   '2025-11-02', 1),
    (2, 'luis@mail.com',  '2026-01-15', 2),
    (3, 'marta@mail.com', '2026-05-20', 3),
    (4, 'diego@mail.com', '2026-09-01', 3);

INSERT INTO profiles (profile_id, subscriber_id, display_name, photo, country_code) VALUES
    (1, 1, 'anaruiz', 'a1.jpg', 'MX'),
    (2, 2, 'luis.s',  'l2.jpg', 'MX'),
    (3, 3, 'marta_g', NULL,     'AR'),   -- Marta no tiene foto
    (4, 4, 'diegol',  'd4.jpg', 'MX');

INSERT INTO libraries (library_id, subscriber_id) VALUES
    (1, 1),
    (2, 2),
    (3, 3),   -- la biblioteca de Marta queda vacía
    (4, 4);


-- ---------------------------------------------------------------------
-- playlists: tabla A. La 13 (Viaje) es el caso «playlist vacía».
-- ---------------------------------------------------------------------
INSERT INTO playlists (playlist_id, name, created_at, subscriber_id) VALUES
    (10, 'Gym',           '2026-03-01', 1),
    (11, 'Para estudiar', '2026-04-10', 1),
    (12, 'Gym',           '2026-05-02', 2),
    (13, 'Viaje',         '2026-06-15', 3),
    (14, 'Favoritas',     '2026-06-20', 2);


-- ---------------------------------------------------------------------
-- songs: tabla B, con la duración convertida a segundos.
-- ---------------------------------------------------------------------
INSERT INTO songs (song_id, title, duration_seconds, genre) VALUES
    (101, 'Ella Baila Sola',         165, 'Regional mexicano'),  -- 2:45
    (102, 'TQG',                     197, 'Reguetón'),           -- 3:17
    (103, 'Bzrp Music Sessions #53', 213, 'Pop latino'),         -- 3:33
    (104, 'Flowers',                 200, 'Pop'),                -- 3:20
    (105, 'Kill Bill',               153, 'R&B'),                -- 2:33
    (106, 'Tití Me Preguntó',        243, 'Reguetón'),           -- 4:03
    (107, 'Me Porto Bonito',         178, 'Reguetón'),           -- 2:58
    (108, 'Calor de Agosto',         185, 'Regional mexicano');  -- 3:05


-- ---------------------------------------------------------------------
-- artists: los de la tabla B más A11, el caso «artista sin canciones ni
-- álbumes» (recién firmado).
-- ---------------------------------------------------------------------
INSERT INTO artists (artist_id, name, country_code) VALUES
    ('A1',  'Karol G',          'CO'),
    ('A2',  'Shakira',          'CO'),
    ('A3',  'Miley Cyrus',      'US'),
    ('A4',  'SZA',              'US'),
    ('A5',  'Bizarrap',         'AR'),
    ('A6',  'Eslabon Armado',   'US'),
    ('A7',  'Peso Pluma',       'MX'),
    ('A8',  'Bad Bunny',        'PR'),
    ('A9',  'Chencho Corleone', 'PR'),
    ('A10', 'Los del Pitic',    'MX'),
    ('A11', 'Natanael Cano',    'MX');


-- ---------------------------------------------------------------------
-- albums: tabla C, cada uno con el artista que lo publica.
-- ---------------------------------------------------------------------
INSERT INTO albums (album_id, title, release_year, cover, artist_id) VALUES
    (201, 'Desvelado',                2023, 'desvelado.jpg', 'A6'),
    (202, 'Mañana Será Bonito',       2023, 'msb.jpg',       'A1'),
    (203, 'Endless Summer Vacation',  2023, 'esv.jpg',       'A3'),
    (204, 'SOS',                      2022, 'sos.jpg',       'A4'),
    (205, 'Un Verano Sin Ti',         2022, 'uvst.jpg',      'A8'),
    (206, 'Las Mujeres Ya No Lloran', 2024, 'lmynl.jpg',     'A2');


-- ---------------------------------------------------------------------
-- playlist_song: tabla A. La posición es el orden de la canción en la
-- celda; added_at es la fecha en que se agregó.
-- ---------------------------------------------------------------------
INSERT INTO playlist_song (playlist_id, song_id, position, added_at) VALUES
    (10, 101, 1, '2026-03-01'),
    (10, 102, 2, '2026-03-01'),
    (10, 103, 3, '2026-03-04'),
    (11, 104, 1, '2026-04-10'),
    (11, 101, 2, '2026-04-12'),
    (12, 102, 1, '2026-05-02'),
    (12, 105, 2, '2026-05-02'),
    (14, 103, 1, '2026-06-20'),
    (14, 104, 2, '2026-06-21'),
    (14, 102, 3, '2026-06-22');


-- ---------------------------------------------------------------------
-- song_artist: créditos de la tabla B.
-- ---------------------------------------------------------------------
INSERT INTO song_artist (song_id, artist_id, role) VALUES
    (101, 'A6',  'principal'),
    (101, 'A7',  'feat.'),
    (102, 'A1',  'principal'),
    (102, 'A2',  'feat.'),
    (103, 'A5',  'principal'),
    (103, 'A2',  'feat.'),
    (104, 'A3',  'principal'),
    (105, 'A4',  'principal'),
    (106, 'A8',  'principal'),
    (107, 'A8',  'principal'),
    (107, 'A9',  'feat.'),
    (108, 'A10', 'principal');


-- ---------------------------------------------------------------------
-- song_album: pistas de la tabla C. La canción 108 no está en ningún
-- álbum (caso «canción sin álbum»).
-- ---------------------------------------------------------------------
INSERT INTO song_album (song_id, album_id, track_number) VALUES
    (101, 201,  6),
    (102, 202,  6),
    (104, 203,  1),
    (105, 204,  2),
    (107, 205,  3),
    (106, 205,  4),
    (103, 206, 11),
    (102, 206, 12);


-- ---------------------------------------------------------------------
-- library_song y library_album: canciones y álbumes guardados (tabla D).
-- La biblioteca 3 (Marta) queda vacía.
-- ---------------------------------------------------------------------
INSERT INTO library_song (library_id, song_id) VALUES
    (1, 102),
    (1, 104),
    (2, 103),
    (4, 101),
    (4, 108);

INSERT INTO library_album (library_id, album_id) VALUES
    (1, 205),
    (2, 204),
    (2, 206);
