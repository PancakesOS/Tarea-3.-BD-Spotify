-- =====================================================================
-- 01_schema.sql · Esquema de la BD transaccional de Spotify
-- =====================================================================
-- Implementa el diagrama ER de la Tarea 2 (docs/diagrama_er.png), en 3FN:
--   * 14 tablas: 9 entidades (las 8 de negocio + countries, que surgió al
--     normalizar) y 5 tablas de unión.
--   * Las PK son enteras (o códigos) sin IDENTITY: los IDs se insertan
--     explícitamente en 02_seed.sql.
--   * Ninguna FK lleva ON DELETE CASCADE: borrar un suscriptor exige
--     borrar sus dependencias de forma explícita (ver tests.sql, sección c).
--   * Las tablas se crean en orden de dependencias: una tabla referenciada
--     va antes que la que la referencia.
--
-- Cómo se traduce cada cardinalidad:
--   * Mínimo 1 del lado "uno" (toda fila hija tiene padre) -> FK NOT NULL.
--   * Máximo 1 del lado "muchos" en una relación 1:1       -> UNIQUE en la FK.
--   * Relaciones N:M                                       -> tabla de unión
--     con PK compuesta (un par no se repite) y una FK a cada lado.
--
-- Cardinalidades que NO se pueden garantizar solo con restricciones
-- (requerirían triggers, fuera del alcance):
--   * Todo álbum tiene al menos 1 canción y toda canción al menos 1 artista
--     (mínimo 1 del lado "muchos"). Se cumple en los datos cargados.
--   * Todo suscriptor tiene perfil y biblioteca. Se garantiza con la
--     transacción de registro (tests.sql), que crea los tres o ninguno.
-- =====================================================================


-- ---------------------------------------------------------------------
-- countries: catálogo de países (ISO 3166-1 alfa-2).
-- Surgió al normalizar: el código de país determina su nombre
-- (supuesto 6), así que el nombre no se repite en artists ni profiles.
-- ---------------------------------------------------------------------
CREATE TABLE countries (
    country_code char(2)     NOT NULL,
    name         varchar(60) NOT NULL,
    CONSTRAINT countries_pkey          PRIMARY KEY (country_code),
    CONSTRAINT countries_name_key      UNIQUE (name),
    CONSTRAINT countries_code_format   CHECK (country_code ~ '^[A-Z]{2}$')
);


-- ---------------------------------------------------------------------
-- subscriptions: planes de Spotify (Premium, Gratuita, Familiar, ...).
-- Todos los suscriptores de un plan pagan lo mismo (supuesto 3), por eso
-- el precio y los anuncios son atributos del plan. Se usa llave sustituta
-- porque el nombre del plan puede cambiar (supuesto 11).
-- ---------------------------------------------------------------------
CREATE TABLE subscriptions (
    subscription_id integer      NOT NULL,
    name            varchar(30)  NOT NULL,
    monthly_price   numeric(6,2) NOT NULL,
    has_ads         boolean      NOT NULL,
    CONSTRAINT subscriptions_pkey              PRIMARY KEY (subscription_id),
    CONSTRAINT subscriptions_name_key          UNIQUE (name),
    CONSTRAINT subscriptions_price_nonnegative CHECK (monthly_price >= 0)
);


-- ---------------------------------------------------------------------
-- subscribers: cuentas de usuario.
-- subscriptions 1..1 <-> 0..N subscribers ("subscribe"): cada suscriptor
-- tiene exactamente un plan a la vez (supuesto 3) -> FK NOT NULL.
-- El email identifica a una sola cuenta -> UNIQUE; aun así se usa llave
-- sustituta porque el email puede cambiar (supuesto 11).
-- ---------------------------------------------------------------------
CREATE TABLE subscribers (
    subscriber_id   integer      NOT NULL,
    email           varchar(255) NOT NULL,
    registered_at   date         NOT NULL,
    subscription_id integer      NOT NULL,
    CONSTRAINT subscribers_pkey              PRIMARY KEY (subscriber_id),
    CONSTRAINT subscribers_email_key         UNIQUE (email),
    CONSTRAINT subscribers_email_format      CHECK (email LIKE '%_@_%'),
    CONSTRAINT subscribers_subscription_fkey FOREIGN KEY (subscription_id)
        REFERENCES subscriptions (subscription_id)
);


-- ---------------------------------------------------------------------
-- profiles: perfil público de cada suscriptor (relación 1:1).
-- subscribers 1..1 <-> 1..1 profiles ("create"):
--   * todo perfil pertenece a un suscriptor  -> subscriber_id NOT NULL + FK
--   * un suscriptor tiene a lo más 1 perfil  -> subscriber_id UNIQUE
--   * el mínimo 1 del lado del suscriptor se garantiza con la transacción
--     de registro (tests.sql).
-- countries 1..1 <-> 0..N profiles ("is home to") -> country_code NOT NULL + FK.
-- La foto es opcional (supuesto 10): Marta no tiene.
-- profiles no surgió al normalizar; se conserva por el diagrama conceptual
-- unificado (supuesto 12).
-- ---------------------------------------------------------------------
CREATE TABLE profiles (
    profile_id    integer      NOT NULL,
    subscriber_id integer      NOT NULL,
    display_name  varchar(50)  NOT NULL,
    photo         varchar(255),
    country_code  char(2)      NOT NULL,
    CONSTRAINT profiles_pkey            PRIMARY KEY (profile_id),
    CONSTRAINT profiles_subscriber_key  UNIQUE (subscriber_id),
    CONSTRAINT profiles_subscriber_fkey FOREIGN KEY (subscriber_id)
        REFERENCES subscribers (subscriber_id),
    CONSTRAINT profiles_country_fkey    FOREIGN KEY (country_code)
        REFERENCES countries (country_code)
);


-- ---------------------------------------------------------------------
-- libraries: biblioteca de cada suscriptor (relación 1:1).
-- subscribers 1..1 <-> 1..1 libraries ("add to"): misma traducción que
-- profiles (NOT NULL + UNIQUE + FK; el mínimo 1 lo cubre el registro).
-- También se conserva por el diagrama conceptual unificado (supuesto 12).
-- ---------------------------------------------------------------------
CREATE TABLE libraries (
    library_id    integer NOT NULL,
    subscriber_id integer NOT NULL,
    CONSTRAINT libraries_pkey            PRIMARY KEY (library_id),
    CONSTRAINT libraries_subscriber_key  UNIQUE (subscriber_id),
    CONSTRAINT libraries_subscriber_fkey FOREIGN KEY (subscriber_id)
        REFERENCES subscribers (subscriber_id)
);


-- ---------------------------------------------------------------------
-- playlists: listas creadas por los suscriptores.
-- subscribers 1..1 <-> 0..N playlists ("create"): toda playlist tiene
-- dueño -> subscriber_id NOT NULL + FK. El nombre NO es UNIQUE: hay dos
-- playlists llamadas «Gym».
-- ---------------------------------------------------------------------
CREATE TABLE playlists (
    playlist_id   integer      NOT NULL,
    name          varchar(100) NOT NULL,
    created_at    date         NOT NULL,
    subscriber_id integer      NOT NULL,
    CONSTRAINT playlists_pkey            PRIMARY KEY (playlist_id),
    CONSTRAINT playlists_subscriber_fkey FOREIGN KEY (subscriber_id)
        REFERENCES subscribers (subscriber_id)
);


-- ---------------------------------------------------------------------
-- songs: catálogo de canciones.
-- El título y la duración son datos de la canción, no cambian según la
-- playlist o el álbum (supuesto 2). Cada canción tiene un solo género
-- (supuesto 5). La duración se guarda en segundos.
-- ---------------------------------------------------------------------
CREATE TABLE songs (
    song_id          integer      NOT NULL,
    title            varchar(200) NOT NULL,
    duration_seconds integer      NOT NULL,
    genre            varchar(50)  NOT NULL,
    CONSTRAINT songs_pkey              PRIMARY KEY (song_id),
    CONSTRAINT songs_duration_positive CHECK (duration_seconds > 0)
);


-- ---------------------------------------------------------------------
-- artists: catálogo de artistas (IDs de Laura: 'A1', 'A2', ...).
-- countries 1..1 <-> 0..N artists ("is home to") -> country_code NOT NULL + FK.
-- ---------------------------------------------------------------------
CREATE TABLE artists (
    artist_id    varchar(10)  NOT NULL,
    name         varchar(100) NOT NULL,
    country_code char(2)      NOT NULL,
    CONSTRAINT artists_pkey         PRIMARY KEY (artist_id),
    CONSTRAINT artists_country_fkey FOREIGN KEY (country_code)
        REFERENCES countries (country_code)
);


-- ---------------------------------------------------------------------
-- albums: catálogo de álbumes.
-- artists 1..1 <-> 0..N albums ("release"): cada álbum lo publica un solo
-- artista (supuesto 8) -> artist_id NOT NULL + FK.
-- ---------------------------------------------------------------------
CREATE TABLE albums (
    album_id     integer      NOT NULL,
    title        varchar(200) NOT NULL,
    release_year smallint     NOT NULL,
    cover        varchar(255) NOT NULL,
    artist_id    varchar(10)  NOT NULL,
    CONSTRAINT albums_pkey        PRIMARY KEY (album_id),
    CONSTRAINT albums_year_range  CHECK (release_year BETWEEN 1900 AND 2100),
    CONSTRAINT albums_artist_fkey FOREIGN KEY (artist_id)
        REFERENCES artists (artist_id)
);


-- ---------------------------------------------------------------------
-- playlist_song: canciones de cada playlist, con su posición (N:M).
-- playlists 1..1 <-> 0..N y songs 1..1 <-> 0..N -> PK compuesta + 2 FK.
-- Supuesto 1: una canción no se repite dentro de una playlist (PK) y cada
-- posición tiene una sola canción (UNIQUE (playlist_id, position)).
-- ---------------------------------------------------------------------
CREATE TABLE playlist_song (
    playlist_id integer  NOT NULL,
    song_id     integer  NOT NULL,
    position    smallint NOT NULL,
    added_at    date     NOT NULL,
    CONSTRAINT playlist_song_pkey              PRIMARY KEY (playlist_id, song_id),
    CONSTRAINT playlist_song_position_key      UNIQUE (playlist_id, position),
    CONSTRAINT playlist_song_position_positive CHECK (position > 0),
    CONSTRAINT playlist_song_playlist_fkey     FOREIGN KEY (playlist_id)
        REFERENCES playlists (playlist_id),
    CONSTRAINT playlist_song_song_fkey         FOREIGN KEY (song_id)
        REFERENCES songs (song_id)
);


-- ---------------------------------------------------------------------
-- song_artist: créditos de cada canción (N:M).
-- songs 1..1 <-> 1..N y artists 1..1 <-> 0..N -> PK compuesta + 2 FK.
-- Supuesto 4: un artista aparece una sola vez en los créditos de una
-- canción (PK) y su rol es 'principal' o 'feat.' (CHECK).
-- El mínimo 1 (toda canción tiene artista) no se puede forzar aquí.
-- ---------------------------------------------------------------------
CREATE TABLE song_artist (
    song_id   integer     NOT NULL,
    artist_id varchar(10) NOT NULL,
    role      varchar(10) NOT NULL,
    CONSTRAINT song_artist_pkey        PRIMARY KEY (song_id, artist_id),
    CONSTRAINT song_artist_role_values CHECK (role IN ('principal', 'feat.')),
    CONSTRAINT song_artist_song_fkey   FOREIGN KEY (song_id)
        REFERENCES songs (song_id),
    CONSTRAINT song_artist_artist_fkey FOREIGN KEY (artist_id)
        REFERENCES artists (artist_id)
);


-- ---------------------------------------------------------------------
-- song_album: pistas de cada álbum (N:M).
-- songs 1..1 <-> 0..N y albums 1..1 <-> 1..N -> PK compuesta + 2 FK.
-- Supuesto 7: una canción aparece una sola vez en un álbum (PK) y, como
-- cada álbum es de un solo disco, el número de pista no se repite
-- (UNIQUE (album_id, track_number)).
-- El mínimo 1 (todo álbum tiene canción) no se puede forzar aquí.
-- ---------------------------------------------------------------------
CREATE TABLE song_album (
    song_id      integer  NOT NULL,
    album_id     integer  NOT NULL,
    track_number smallint NOT NULL,
    CONSTRAINT song_album_pkey           PRIMARY KEY (song_id, album_id),
    CONSTRAINT song_album_track_key      UNIQUE (album_id, track_number),
    CONSTRAINT song_album_track_positive CHECK (track_number > 0),
    CONSTRAINT song_album_song_fkey      FOREIGN KEY (song_id)
        REFERENCES songs (song_id),
    CONSTRAINT song_album_album_fkey     FOREIGN KEY (album_id)
        REFERENCES albums (album_id)
);


-- ---------------------------------------------------------------------
-- library_song: canciones guardadas en cada biblioteca (N:M).
-- libraries 1..1 <-> 0..N y songs 1..1 <-> 0..N -> PK compuesta + 2 FK.
-- ---------------------------------------------------------------------
CREATE TABLE library_song (
    library_id integer NOT NULL,
    song_id    integer NOT NULL,
    CONSTRAINT library_song_pkey         PRIMARY KEY (library_id, song_id),
    CONSTRAINT library_song_library_fkey FOREIGN KEY (library_id)
        REFERENCES libraries (library_id),
    CONSTRAINT library_song_song_fkey    FOREIGN KEY (song_id)
        REFERENCES songs (song_id)
);


-- ---------------------------------------------------------------------
-- library_album: álbumes guardados en cada biblioteca (N:M).
-- libraries 1..1 <-> 0..N y albums 1..1 <-> 0..N -> PK compuesta + 2 FK.
-- Guardar un álbum no equivale a guardar cada una de sus canciones
-- (supuesto 9), por eso es una tabla aparte de library_song.
-- ---------------------------------------------------------------------
CREATE TABLE library_album (
    library_id integer NOT NULL,
    album_id   integer NOT NULL,
    CONSTRAINT library_album_pkey         PRIMARY KEY (library_id, album_id),
    CONSTRAINT library_album_library_fkey FOREIGN KEY (library_id)
        REFERENCES libraries (library_id),
    CONSTRAINT library_album_album_fkey   FOREIGN KEY (album_id)
        REFERENCES albums (album_id)
);
