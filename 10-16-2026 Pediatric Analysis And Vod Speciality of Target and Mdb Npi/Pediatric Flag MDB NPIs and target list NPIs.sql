%sql
DECLARE OR REPLACE VARIABLE dx_rx STRING
DEFAULT '[|](E20|E200|E208|E2081|E20810|E20811|E20812|E20818|E20819|E2089|E209)[|]';

CREATE OR REPLACE TABLE comm_dev.pdm_dev_ml_experiments.adh_hcp_patient_metrics AS

WITH hcp_cohort AS (
    SELECT DISTINCT cast(npi AS string) AS npi
    FROM comm_dev.commercial_dev_bronze.mdb_09_17
    WHERE npi IS NOT NULL
),

excl AS (
    SELECT DISTINCT patient_id
    FROM comm_dev.pdm_dev_ml_experiments.adh_reliable_negative_ptnts
    WHERE patient_id IS NOT NULL
),

-- STEP 1: single scan per source.
-- instr() runs on the exact cleaned string the regex sees, so it is a strict
-- pre-check: regex only runs on rows that can possibly match.
claims AS (
    SELECT
        coalesce(
            nullif(trim(cast(rendering_npi AS string)), ''),
            nullif(trim(cast(referring_npi AS string)), ''),
            nullif(trim(cast(billing_npi   AS string)), '')
        ) AS npi,
        patient_id,
        service_date AS claim_date,
        CASE
            WHEN instr(translate(upper(trim(coalesce(diagnosis_codes,''))),'.',''),'E20') > 0
             AND concat('|',translate(translate(upper(trim(coalesce(diagnosis_codes,''))),'.',''),'*','|'),'|') RLIKE dx_rx
            THEN 1 ELSE 0
        END AS dx_claim_flag,
        CASE WHEN service_date >= DATE '2023-10-01' THEN 1 ELSE 0 END AS in_window_flag
    FROM bbio_comm_komodo_adh1.export.medical_events

    UNION ALL

    SELECT
        nullif(trim(cast(prescriber_npi AS string)), '') AS npi,
        patient_id,
        fill_date AS claim_date,
        CASE
            WHEN instr(upper(translate(trim(coalesce(DIAGNOSIS_CODE,'')),'.','')),'E20') > 0
             AND concat('|',upper(translate(trim(coalesce(DIAGNOSIS_CODE,'')),'.','')),'|') RLIKE dx_rx
            THEN 1 ELSE 0
        END AS dx_claim_flag,
        CASE WHEN fill_date >= DATE '2023-10-01' THEN 1 ELSE 0 END AS in_window_flag
    FROM bbio_comm_komodo_adh1.export.pharmacy_events

    UNION ALL

    SELECT
        nullif(trim(cast(ordering_npi AS string)), '') AS npi,
        patient_id,
        service_date AS claim_date,
        CASE
            WHEN instr(translate(upper(trim(coalesce(diagnosis_codes,''))),'.',''),'E20') > 0
             AND concat('|',translate(translate(upper(trim(coalesce(diagnosis_codes,''))),'.',''),'*','|'),'|') RLIKE dx_rx
            THEN 1 ELSE 0
        END AS dx_claim_flag,
        CASE WHEN service_date >= DATE '2023-10-01' THEN 1 ELSE 0 END AS in_window_flag
    FROM bbio_comm_komodo_adh1.export.lab_results
),

-- STEP 2: collapse to (npi, patient) grain immediately.
-- NULL npi rows are RETAINED so patient-level flags still see them (same as original).
pair_agg AS (
    SELECT
        npi,
        patient_id,
        max(claim_date)                                          AS latest_claim_any,
        max(dx_claim_flag)                                       AS pair_dx_flag,
        max(CASE WHEN in_window_flag = 1 THEN dx_claim_flag END) AS pair_iw_dx_flag,

        max(in_window_flag) AS pair_claim_in_window_flag
    FROM claims
    GROUP BY npi, patient_id
),

-- STEP 3: exclusion is whole-patient, so applying it post-aggregation is equivalent
pair_clean AS (
    SELECT p.*
    FROM pair_agg p
    LEFT ANTI JOIN excl e ON e.patient_id = p.patient_id
),

-- STEP 4: patient-level flags via window on the small aggregate.
-- Replaces pat_dx and pat_dx_in_window, which each re-scanned all claims.
pair_flagged AS (
    SELECT npi, patient_id, latest_claim_any, in_window_dx_flag,pair_claim_in_window_flag
    FROM (
        SELECT
            npi,
            patient_id,
            latest_claim_any,
            pair_claim_in_window_flag,
            max(pair_dx_flag)    OVER (PARTITION BY patient_id) AS patient_dx_flag,
            max(pair_iw_dx_flag) OVER (PARTITION BY patient_id) AS in_window_dx_flag
        FROM pair_clean
    ) x
    WHERE npi IS NOT NULL
      AND patient_dx_flag = 1
),

-- STEP 5: cohort pushed down BEFORE demographics join and metrics
npi_pat AS (
    SELECT f.*
    FROM pair_flagged f
    LEFT SEMI JOIN hcp_cohort h ON h.npi = f.npi
),

-- STEP 6: one row per patient (fixes NPI fan-out), limited to patients in scope
pat_yob AS (
    SELECT DISTINCT d.patient_id, year(d.patient_yob) AS yob
    FROM bbio_comm_komodo_adh1.export.patient_demographics d
    LEFT SEMI JOIN npi_pat n ON n.patient_id = d.patient_id
    WHERE d.patient_yob IS NOT NULL
      AND year(d.patient_yob) >= 0
),

scored AS (
    SELECT
        f.npi,
        f.in_window_dx_flag,
        f.pair_claim_in_window_flag,
        CASE WHEN year(f.latest_claim_any) - y.yob >= 16 THEN 1 ELSE 0 END AS ge_16
    FROM npi_pat f
    LEFT JOIN pat_yob y USING (patient_id)
),

npi_metrics AS (
    SELECT
        npi,
        -- ALL TIME METRICS
        count(*)                                                   AS int_total_patients,
        sum(ge_16)                                                 AS int_patients_ge_16,
        -- IN-WINDOW METRICS (patient-level in-window dx flag, same as original)
        sum(
    CASE
        WHEN in_window_dx_flag = 1
         AND pair_claim_in_window_flag = 1
        THEN 1
        ELSE 0
    END
) AS int_total_patients_after_oct_23 ,
        sum(
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
    coalesce(m.int_total_patients, 0)              AS total_patients,
    coalesce(m.int_patients_ge_16, 0)              AS patients_ge_16,
    coalesce(m.int_total_patients_after_oct_23, 0) AS total_patients_in_window,
    coalesce(m.int_patients_ge_16_after_oct_23, 0) AS patients_ge_16_in_window
FROM hcp_cohort h
LEFT JOIN npi_metrics m USING (npi);