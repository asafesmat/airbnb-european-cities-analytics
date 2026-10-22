/* =====================================================================
   AirbnbDW pipeline: Bronze -> Silver -> Gold
   PART 1  setup      run once (it recreates the tables; the pipeline refills them)
   PART 2  procedures safe to re-run any time
   PART 3  run        loads everything from the CSV and checks the result
   ===================================================================== */

CREATE DATABASE AirbnbDW;
GO

USE AirbnbDW;
GO

/* ===================== PART 1: SETUP ===================== */

IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'bronze') EXEC('CREATE SCHEMA bronze');
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'silver') EXEC('CREATE SCHEMA silver');
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'gold')   EXEC('CREATE SCHEMA gold');
GO

-- Bronze: raw copy of the CSV, everything is text, no constraints
DROP TABLE IF EXISTS bronze.airbnb_listings_raw;
CREATE TABLE bronze.airbnb_listings_raw (
    city               NVARCHAR(100),
    room_id            NVARCHAR(50),
    name               NVARCHAR(500),
    total_price_eur    NVARCHAR(50),
    nights             NVARCHAR(50),
    rating             NVARCHAR(50),
    reviews            NVARCHAR(50),
    is_guest_favorite  NVARCHAR(50),
    is_superhost       NVARCHAR(50),
    url                NVARCHAR(500)
);
GO

-- load history: created only if missing, so the history is never wiped
IF OBJECT_ID('bronze.load_log', 'U') IS NULL
    CREATE TABLE bronze.load_log (
        load_id      INT IDENTITY(1,1) PRIMARY KEY,
        source_file  NVARCHAR(260),
        loaded_at    DATETIME2 DEFAULT SYSDATETIME(),
        rows_loaded  INT
    );
GO

-- Silver: typed, checked data + the rows that failed a check
DROP TABLE IF EXISTS silver.airbnb_listings;
CREATE TABLE silver.airbnb_listings (
    room_id              BIGINT         NOT NULL PRIMARY KEY,
    city                 NVARCHAR(50)   NOT NULL,
    name                 NVARCHAR(200)  NOT NULL,
    total_price_eur      INT            NOT NULL,
    nights               TINYINT        NOT NULL,
    price_per_night_eur  DECIMAL(10,2)  NOT NULL,
    rating               DECIMAL(3,2)   NOT NULL,
    reviews              INT            NOT NULL,
    is_guest_favorite    BIT            NOT NULL,
    is_superhost         BIT            NOT NULL,
    url                  NVARCHAR(100)  NOT NULL,
    loaded_at            DATETIME2      NOT NULL DEFAULT SYSDATETIME()
);

DROP TABLE IF EXISTS silver.airbnb_listings_rejected;
CREATE TABLE silver.airbnb_listings_rejected (
    reject_reason      NVARCHAR(100) NOT NULL,
    city               NVARCHAR(100),
    room_id            NVARCHAR(50),
    name               NVARCHAR(500),
    total_price_eur    NVARCHAR(50),
    nights             NVARCHAR(50),
    rating             NVARCHAR(50),
    reviews            NVARCHAR(50),
    is_guest_favorite  NVARCHAR(50),
    is_superhost       NVARCHAR(50),
    url                NVARCHAR(500),
    rejected_at        DATETIME2 NOT NULL DEFAULT SYSDATETIME()
);
GO

-- Gold: star schema
DROP TABLE IF EXISTS gold.fact_listing;
DROP TABLE IF EXISTS gold.dim_listing;
DROP TABLE IF EXISTS gold.dim_city;
GO

CREATE TABLE gold.dim_city (
    city_key   INT IDENTITY(1,1) NOT NULL,
    city_name  NVARCHAR(50) NOT NULL,
    country    NVARCHAR(50) NOT NULL,
    CONSTRAINT pk_dim_city PRIMARY KEY (city_key),
    CONSTRAINT uq_dim_city_name UNIQUE (city_name)
);

CREATE TABLE gold.dim_listing (
    listing_key        INT IDENTITY(1,1) NOT NULL,
    room_id            BIGINT        NOT NULL,
    listing_name       NVARCHAR(200) NOT NULL,
    url                NVARCHAR(100) NOT NULL,
    is_superhost       BIT           NOT NULL,
    is_guest_favorite  BIT           NOT NULL,
    CONSTRAINT pk_dim_listing PRIMARY KEY (listing_key),
    CONSTRAINT uq_dim_listing_room UNIQUE (room_id)
);

CREATE TABLE gold.fact_listing (
    listing_key          INT           NOT NULL,
    city_key             INT           NOT NULL,
    total_price_eur      INT           NOT NULL,
    nights               TINYINT       NOT NULL,
    price_per_night_eur  DECIMAL(10,2) NOT NULL,
    rating               DECIMAL(3,2)  NOT NULL,
    reviews              INT           NOT NULL,
    CONSTRAINT pk_fact_listing PRIMARY KEY (listing_key),
    CONSTRAINT fk_fact_listing FOREIGN KEY (listing_key) REFERENCES gold.dim_listing (listing_key),
    CONSTRAINT fk_fact_city    FOREIGN KEY (city_key)    REFERENCES gold.dim_city (city_key)
);
GO

CREATE OR ALTER VIEW gold.vw_listings AS
SELECT c.city_name AS city, c.country,
       l.room_id, l.listing_name, l.url, l.is_superhost, l.is_guest_favorite,
       f.total_price_eur, f.nights, f.price_per_night_eur, f.rating, f.reviews,
       CASE WHEN f.reviews >= 5 THEN 1 ELSE 0 END AS is_rating_reliable
FROM gold.fact_listing f
JOIN gold.dim_listing  l ON l.listing_key = f.listing_key
JOIN gold.dim_city     c ON c.city_key    = f.city_key;
GO

CREATE OR ALTER VIEW gold.vw_city_summary AS
SELECT DISTINCT
    city, country,
    COUNT(*) OVER (PARTITION BY city)                                                     AS n_listings,
    CAST(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY price_per_night_eur)
         OVER (PARTITION BY city) AS DECIMAL(10,2))                                       AS median_price_per_night_eur,
    CAST(AVG(CAST(is_superhost AS DECIMAL(9,4)) * 100) OVER (PARTITION BY city) AS DECIMAL(5,2))      AS pct_superhost,
    CAST(AVG(CAST(is_guest_favorite AS DECIMAL(9,4)) * 100) OVER (PARTITION BY city) AS DECIMAL(5,2)) AS pct_guest_favorite,
    SUM(is_rating_reliable) OVER (PARTITION BY city)                                      AS n_rating_reliable,
    CAST(AVG(CASE WHEN is_rating_reliable = 1 THEN rating END) OVER (PARTITION BY city) AS DECIMAL(4,2)) AS avg_rating_reliable
FROM gold.vw_listings;
GO

/* ===================== PART 2: PROCEDURES ===================== */

CREATE OR ALTER PROCEDURE bronze.usp_load_airbnb_listings @file_path NVARCHAR(260)
AS
BEGIN
    SET NOCOUNT ON;
    TRUNCATE TABLE bronze.airbnb_listings_raw;

    DECLARE @sql NVARCHAR(MAX) = N'
        BULK INSERT bronze.airbnb_listings_raw
        FROM ''' + REPLACE(@file_path, '''', '''''') + N'''
        WITH (FORMAT = ''CSV'', FIRSTROW = 2, FIELDQUOTE = ''"'', FIELDTERMINATOR = '','',
              ROWTERMINATOR = ''\n'', CODEPAGE = ''65001'', TABLOCK);';
    EXEC sys.sp_executesql @sql;

    INSERT INTO bronze.load_log (source_file, rows_loaded)
    SELECT @file_path, COUNT(*) FROM bronze.airbnb_listings_raw;
END;
GO

CREATE OR ALTER PROCEDURE silver.usp_load_airbnb_listings
AS
BEGIN
    SET NOCOUNT ON;

    TRUNCATE TABLE silver.airbnb_listings;
    TRUNCATE TABLE silver.airbnb_listings_rejected;
    DROP TABLE IF EXISTS #stg;

    WITH typed AS (
        SELECT
            b.city AS r_city, b.room_id AS r_room_id, b.name AS r_name,
            b.total_price_eur AS r_price, b.nights AS r_nights, b.rating AS r_rating,
            b.reviews AS r_reviews, b.is_guest_favorite AS r_fav, b.is_superhost AS r_host, b.url AS r_url,
            LTRIM(RTRIM(b.city))                  AS city,
            TRY_CAST(b.room_id AS BIGINT)         AS room_id,
            LTRIM(RTRIM(b.name))                  AS name,
            TRY_CAST(b.total_price_eur AS INT)    AS total_price_eur,
            TRY_CAST(b.nights AS TINYINT)         AS nights,
            TRY_CAST(b.rating AS DECIMAL(3,2))    AS rating,
            TRY_CAST(b.reviews AS INT)            AS reviews,
            TRY_CAST(b.is_guest_favorite AS BIT)  AS is_guest_favorite,
            TRY_CAST(b.is_superhost AS BIT)       AS is_superhost,
            LTRIM(RTRIM(b.url))                   AS url
        FROM bronze.airbnb_listings_raw b
    ),
    numbered AS (
        SELECT *, ROW_NUMBER() OVER (PARTITION BY room_id ORDER BY (SELECT NULL)) AS rn
        FROM typed
    )
    SELECT *,
        CASE
            WHEN city IS NULL OR city = '' OR LEN(city) > 50              THEN 'city blank or too long'
            WHEN room_id IS NULL                                          THEN 'room_id is not a number'
            WHEN name IS NULL OR name = '' OR LEN(name) > 200             THEN 'name blank or too long'
            WHEN total_price_eur IS NULL OR total_price_eur <= 0          THEN 'price is not a positive number'
            WHEN nights IS NULL OR nights NOT BETWEEN 1 AND 30            THEN 'nights invalid'
            WHEN rating IS NULL OR rating NOT BETWEEN 1 AND 5             THEN 'rating invalid'
            WHEN reviews IS NULL OR reviews < 0                           THEN 'reviews invalid'
            WHEN is_guest_favorite IS NULL OR is_superhost IS NULL        THEN 'flag is not 0/1'
            WHEN url IS NULL OR LEN(url) > 100
                 OR url <> 'https://www.airbnb.com/rooms/' + CAST(room_id AS NVARCHAR(30))
                                                                          THEN 'url does not match room_id'
            WHEN rn > 1                                                   THEN 'duplicate room_id'
        END AS reject_reason
    INTO #stg
    FROM numbered;

    INSERT INTO silver.airbnb_listings
        (room_id, city, name, total_price_eur, nights, price_per_night_eur,
         rating, reviews, is_guest_favorite, is_superhost, url)
    SELECT room_id, city, name, total_price_eur, nights,
           CAST(total_price_eur * 1.0 / nights AS DECIMAL(10,2)),
           rating, reviews, is_guest_favorite, is_superhost, url
    FROM #stg
    WHERE reject_reason IS NULL;

    INSERT INTO silver.airbnb_listings_rejected
        (reject_reason, city, room_id, name, total_price_eur, nights,
         rating, reviews, is_guest_favorite, is_superhost, url)
    SELECT reject_reason, r_city, r_room_id, r_name, r_price, r_nights,
           r_rating, r_reviews, r_fav, r_host, r_url
    FROM #stg
    WHERE reject_reason IS NOT NULL;

    SELECT (SELECT COUNT(*) FROM silver.airbnb_listings)          AS rows_loaded,
           (SELECT COUNT(*) FROM silver.airbnb_listings_rejected) AS rows_rejected;
END;
GO

CREATE OR ALTER PROCEDURE gold.usp_load_gold
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        BEGIN TRAN;

        DELETE FROM gold.fact_listing;
        DELETE FROM gold.dim_listing;
        DELETE FROM gold.dim_city;
        DBCC CHECKIDENT ('gold.dim_listing', RESEED, 0) WITH NO_INFOMSGS;
        DBCC CHECKIDENT ('gold.dim_city',    RESEED, 0) WITH NO_INFOMSGS;

        INSERT INTO gold.dim_city (city_name, country)
        SELECT v.city_name, v.country
        FROM (VALUES ('Amsterdam', 'Netherlands'), ('Athens', 'Greece'), ('Barcelona', 'Spain'),
                     ('Berlin', 'Germany'), ('Budapest', 'Hungary'), ('Lisbon', 'Portugal'),
                     ('London', 'United Kingdom'), ('Paris', 'France'), ('Rome', 'Italy'),
                     ('Vienna', 'Austria')) AS v (city_name, country);

        INSERT INTO gold.dim_listing (room_id, listing_name, url, is_superhost, is_guest_favorite)
        SELECT room_id, name, url, is_superhost, is_guest_favorite
        FROM silver.airbnb_listings;

        INSERT INTO gold.fact_listing (listing_key, city_key, total_price_eur, nights, price_per_night_eur, rating, reviews)
        SELECT l.listing_key, c.city_key, s.total_price_eur, s.nights, s.price_per_night_eur, s.rating, s.reviews
        FROM silver.airbnb_listings s
        JOIN gold.dim_listing l ON l.room_id   = s.room_id
        JOIN gold.dim_city    c ON c.city_name = s.city;

        COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_run_pipeline @file_path NVARCHAR(260)
AS
BEGIN
    SET NOCOUNT ON;

    EXEC bronze.usp_load_airbnb_listings @file_path;
    EXEC silver.usp_load_airbnb_listings;

    IF EXISTS (SELECT 1 FROM silver.airbnb_listings_rejected)
        THROW 50001, 'Silver rejected some rows. Check silver.airbnb_listings_rejected. Gold was NOT loaded.', 1;

    EXEC gold.usp_load_gold;

    SELECT (SELECT COUNT(*) FROM bronze.airbnb_listings_raw)       AS bronze_rows,    -- 500
           (SELECT COUNT(*) FROM silver.airbnb_listings)           AS silver_rows,    -- 500
           (SELECT COUNT(*) FROM silver.airbnb_listings_rejected)  AS rejected_rows,  -- 0
           (SELECT COUNT(*) FROM gold.dim_city)                    AS dim_city,       -- 10
           (SELECT COUNT(*) FROM gold.dim_listing)                 AS dim_listing,    -- 500
           (SELECT COUNT(*) FROM gold.fact_listing)                AS fact_listing;   -- 500
END;
GO

/* ===================== PART 3: RUN AND CHECK ===================== */

-- ASCII-only path on purpose: a path with Arabic letters / OneDrive can break BULK INSERT
EXEC dbo.usp_run_pipeline @file_path = 'C:\Users\Asaf\OneDrive\سطح المكتب\Airbnb-Data-Analysis\Data\Airbnb_Listings.csv';
GO

SELECT * FROM silver.airbnb_listings_rejected;                  -- expected: empty

SELECT * FROM gold.vw_city_summary ORDER BY city;               -- 10 rows, n_listings = 50 for each

SELECT COUNT(*) AS rows_differ_from_silver FROM (               -- expected: 0
    SELECT room_id, city, name, total_price_eur, nights, price_per_night_eur, rating, reviews,
           is_guest_favorite, is_superhost, url
    FROM silver.airbnb_listings
    EXCEPT
    SELECT room_id, city, listing_name, total_price_eur, nights, price_per_night_eur, rating, reviews,
           is_guest_favorite, is_superhost, url
    FROM gold.vw_listings
) x;

-- The first-version table is no longer needed. Drop it only after the run above is verified:
DROP TABLE dbo.Airbnb_Listings;