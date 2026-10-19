%sql
DECLARE OR REPLACE VARIABLE dx_rx STRING
DEFAULT '[|]\(E20|E200|E208|E2081|E20810|E20811|E20812|E20818|E20819|E2089|E209)[|]';

CREATE OR REPLACE TABLE comm_dev.pdm_dev_ml_experiments.adh_hcp_patient_metrics AS

WITH hcp_cohort AS (
    SELECT DISTINCT CAST(npi AS STRING) AS npi
    FROM comm_dev.commercial_dev_bronze.mdb_09_17
    WHERE npi IS NOT NULL
),

excl AS (
    SELECT DISTINCT patient_id
    FROM comm_dev.pdm_dev_ml_experiments.adh_reliable_negative_ptnts
    WHERE patient_id IS NOT NULL
),

-- STEP 1: Single scan per source.
-- instr() pre-checks the exact cleaned string before regex matching.
claims AS (
    SELECT
        COALESCE(
            NULLIF(TRIM(CAST(rendering_npi AS STRING)), ''),
            NULLIF(TRIM(CAST(referring_npi AS STRING)), ''),
            NULLIF(TRIM(CAST(billing_npi AS STRING)), '')
        ) AS npi,
        patient_id,
        service_date AS claim_date,
        CASE
            WHEN INSTR(TRANSLATE(UPPER(TRIM(COALESCE(diagnosis_codes, ''))), '.', ''), 'E20') > 0
             AND CONCAT('|', TRANSLATE(TRANSLATE(UPPER(TRIM(COALESCE(diagnosis_codes, ''))), '.', ''), '\*', '|'), '|') RLIKE dx_rx
            THEN 1
            ELSE 0
        END AS dx_claim_flag,
        CASE
            WHEN service_date >= DATE '2023-10-01' THEN 1
            ELSE 0
        END AS in_window_flag
    FROM bbio_comm_komodo_adh1.export.medical_events

    UNION ALL

    SELECT
        NULLIF(TRIM(CAST(prescriber_npi AS STRING)), '') AS npi,
        patient_id,
        fill_date AS claim_date,
        CASE
            WHEN INSTR(UPPER(TRANSLATE(TRIM(COALESCE(DIAGNOSIS_CODE, '')), '.', '')), 'E20') > 0
             AND CONCAT('|', UPPER(TRANSLATE(TRIM(COALESCE(DIAGNOSIS_CODE, '')), '.', '')), '|') RLIKE dx_rx
            THEN 1
            ELSE 0
        END AS dx_claim_flag,
        CASE
            WHEN fill_date >= DATE '2023-10-01' THEN 1
            ELSE 0
        END AS in_window_flag
    FROM bbio_comm_komodo_adh1.export.pharmacy_events

    UNION ALL

    SELECT
        NULLIF(TRIM(CAST(ordering_npi AS STRING)), '') AS npi,
        patient_id,
        service_date AS claim_date,
        CASE
            WHEN INSTR(TRANSLATE(UPPER(TRIM(COALESCE(diagnosis_codes, ''))), '.', ''), 'E20') > 0
             AND CONCAT('|', TRANSLATE(TRANSLATE(UPPER(TRIM(COALESCE(diagnosis_codes, ''))), '.', ''), '\*', '|'), '|') RLIKE dx_rx
            THEN 1
            ELSE 0
        END AS dx_claim_flag,
        CASE
            WHEN service_date >= DATE '2023-10-01' THEN 1
            ELSE 0
        END AS in_window_flag
    FROM bbio_comm_komodo_adh1.export.lab_results
),

-- STEP 2: Collapse to (npi, patient) grain.
-- Retain NULL NPI rows for patient-level flags.
pair_agg AS (
    SELECT
        npi,
        patient_id,
        MAX(claim_date) AS latest_claim_any,
        MAX(dx_claim_flag) AS pair_dx_flag,
        MAX(CASE WHEN in_window_flag = 1 THEN dx_claim_flag END) AS pair_iw_dx_flag,
        MAX(in_window_flag) AS pair_claim_in_window_flag
    FROM claims
    GROUP BY npi, patient_id
),

-- STEP 3: Apply whole-patient exclusion after aggregation.
pair_clean AS (
    SELECT p.*
    FROM pair_agg p
    LEFT ANTI JOIN excl e
        ON e.patient_id = p.patient_id
),

-- STEP 4: Calculate patient-level flags on the aggregated data.
pair_flagged AS (
    SELECT
        npi,
        patient_id,
        latest_claim_any,
        in_window_dx_flag,
        pair_claim_in_window_flag
    FROM (
        SELECT
            npi,
            patient_id,
            latest_claim_any,
            pair_claim_in_window_flag,
            MAX(pair_dx_flag) OVER (PARTITION BY patient_id) AS patient_dx_flag,
            MAX(pair_iw_dx_flag) OVER (PARTITION BY patient_id) AS in_window_dx_flag
        FROM pair_clean
    ) x
    WHERE npi IS NOT NULL
      AND patient_dx_flag = 1
),

-- STEP 5: Restrict to cohort NPIs before demographics and metrics.
npi_pat AS (
    SELECT f.*
    FROM pair_flagged f
    LEFT SEMI JOIN hcp_cohort h
        ON h.npi = f.npi
),

-- STEP 6: One row per patient, limited to patients in scope.
pat_yob AS (
    SELECT DISTINCT
        d.patient_id,
        YEAR(d.patient_yob) AS yob
    FROM bbio_comm_komodo_adh1.export.patient_demographics d
    LEFT SEMI JOIN npi_pat n
        ON n.patient_id = d.patient_id
    WHERE d.patient_yob IS NOT NULL
      AND YEAR(d.patient_yob) >= 0
),

scored AS (
    SELECT
        f.npi,
        f.in_window_dx_flag,
        f.pair_claim_in_window_flag,
        CASE
            WHEN YEAR(f.latest_claim_any) - y.yob >= 16 THEN 1
            ELSE 0
        END AS ge_16
    FROM npi_pat f
    LEFT JOIN pat_yob y USING (patient_id)
),

npi_metrics AS (
    SELECT
        npi,
        -- ALL-TIME METRICS
        COUNT(*) AS int_total_patients,
        SUM(ge_16) AS int_patients_ge_16,

        -- IN-WINDOW METRICS
        SUM(
            CASE
                WHEN in_window_dx_flag = 1
                 AND pair_claim_in_window_flag = 1
                THEN 1
                ELSE 0
            END
        ) AS int_total_patients_after_oct_23,

        SUM(
            CASE
                WHEN in_window_dx_flag = 1
                 AND pair_claim_in_window_flag = 1
                THEN ge_16
                ELSE 0
            END
        ) AS int_patients_ge_16_after_oct_23
    FROM scored
    GROUP BY npi
)

SELECT
    h.npi,
    COALESCE(m.int_total_patients, 0) AS total_patients,
    COALESCE(m.int_patients_ge_16, 0) AS patients_ge_16,
    COALESCE(m.int_total_patients_after_oct_23, 0) AS total_patients_in_window,
    COALESCE(m.int_patients_ge_16_after_oct_23, 0) AS patients_ge_16_in_window
FROM hcp_cohort h
LEFT JOIN npi_metrics m USING (npi);