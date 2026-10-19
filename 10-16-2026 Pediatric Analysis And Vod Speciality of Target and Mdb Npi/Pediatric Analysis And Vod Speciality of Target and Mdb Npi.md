# ADH and HCP Pediatric Specialty Data Documentation

**Document purpose:** Document the purpose, business logic, source data, output schemas, assumptions, SQL implementation, and validation approach for two HCP-level data products.

**Environment:** Databricks SQL  
**Documentation date:** 19 October 2026

---

# 1. ADH HCP Patient Metrics

## 1.1 Overview

| Attribute | Details |
|---|---|
| Output table | `comm_dev.pdm_dev_ml_experiments.adh_hcp_patient_metrics` |
| Version | `v1` |
| Last updated | `16 October 2026` |
| Grain | One row per HCP NPI in the MDB NPI universe |
| Primary purpose | Generate HCP-level ADH patient metrics for all time and for the period beginning 1 October 2023, including patients aged 16 years or older |

### Purpose

Generate HCP-level ADH patient metrics by attributing patients with qualifying E20 diagnosis activity to NPIs. Calculate total patient counts and counts for patients aged 16 years or older, both across all available history and for the in-window period beginning 1 October 2023.

The metrics support:
- NS-HPT patient counts — all time and post-October 2023.
- NS-HPT patient counts for patients aged 16 years or older — all time and post-October 2023.

## 1.2 Source tables

| Source table | Role |
|---|---|
| `comm_dev.commercial_dev_bronze.mdb_09_17` | Defines the HCP NPI universe |
| `comm_dev.pdm_dev_ml_experiments.adh_reliable_negative_ptnts` | Patient exclusion list |
| `bbio_comm_komodo_adh1.export.medical_events` | Medical claims and diagnosis activity |
| `bbio_comm_komodo_adh1.export.pharmacy_events` | Pharmacy claims and diagnosis activity |
| `bbio_comm_komodo_adh1.export.lab_results` | Lab claims and diagnosis activity |
| `bbio_comm_komodo_adh1.export.patient_demographics` | Patient year of birth for age calculations |

## 1.3 Business logic

1. **Define the HCP universe.** Select distinct, non-null NPIs from `mdb_09_17`.
2. **Define patient exclusions.** Identify patients in `adh_reliable_negative_ptnts`. Exclude these patients from the metrics.
3. **Standardize and identify E20 diagnosis activity.** Read medical, pharmacy, and lab records. Normalize diagnosis strings and match them against the qualifying E20 code set.
4. **Attribute activity to an HCP.** Use the available NPI from each source: rendering, referring, or billing NPI for medical events; prescriber NPI for pharmacy events; and ordering NPI for lab results. For medical events, the first non-empty NPI in rendering/referring/billing order is selected.
5. **Aggregate to NPI-patient level.** Combine claim records to calculate the latest claim date, whether a patient has qualifying E20 diagnosis activity, and whether claim activity occurred on or after 1 October 2023.
6. **Apply patient exclusions.** Remove excluded patients from the aggregated data.
7. **Restrict metrics to the MDB HCP universe.** Only NPIs present in the MDB cohort contribute to the output metrics.
8. **Calculate patient age.** Estimate age using the year of the patient's latest claim and the patient's year of birth. Flag patients whose calculated age is at least 16.
9. **Calculate all-time and in-window metrics.** In-window counts require both qualifying diagnosis activity and HCP claim activity on or after 1 October 2023.
10. **Retain all cohort NPIs.** Left join the metrics back to the complete HCP universe and replace missing metric values with zero.

## 1.4 Diagnosis code set and date window

The configured E20 diagnosis code pattern is:

```text
E20, E200, E208, E2081, E20810, E20811, E20812, E20818, E20819, E2089, E209
```

The SQL normalizes diagnosis strings before matching. Depending on the source, normalization includes uppercasing, trimming whitespace, removing periods, and converting `*` separators to `|`. The regular expression uses delimiters to match complete codes rather than unintended partial strings.

**In-window start date:** `2023-10-01`

## 1.5 Output columns

| Output column | Description |
|---|---|
| `npi` | HCP NPI from the MDB universe |
| `total_patients` | All-time count of qualifying patients attributed to the NPI |
| `patients_ge_16` | All-time count of qualifying patients aged 16 years or older |
| `total_patients_in_window` | Count of qualifying patients meeting the in-window diagnosis and claim-activity conditions |
| `patients_ge_16_in_window` | In-window count of qualifying patients aged 16 years or older |

## 1.6 Key logic and assumptions

- Diagnosis codes are standardized before matching against the E20 code set.
- Patients in the reliable negative patient list are excluded from all calculations.
- Age 16 or older is determined by subtracting year of birth from the year of the latest claim available for the NPI-patient pair. This is a year-based estimate, not an exact age calculated from full dates of birth.
- In-window metrics require qualifying diagnosis activity in the window and claim activity in the window.
- All NPIs in the MDB HCP universe are retained in the final output.
- Missing metric values are set to zero.
- The medical-event NPI attribution prioritizes rendering NPI, then referring NPI, then billing NPI.
- The code combines records from three claim sources using `UNION ALL`, then aggregates the combined data.

## 1.7 SQL implementation

```sql
%sql
DECLARE OR REPLACE VARIABLE dx_rx STRING
DEFAULT '[|](E20|E200|E208|E2081|E20810|E20811|E20812|E20818|E20819|E2089|E209)[|]';

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
             AND CONCAT('|', TRANSLATE(TRANSLATE(UPPER(TRIM(COALESCE(diagnosis_codes, ''))), '.', ''), '*', '|'), '|') RLIKE dx_rx
            THEN 1
            ELSE 0
        END AS dx_claim_flag,
        CASE WHEN service_date >= DATE '2023-10-01' THEN 1 ELSE 0 END AS in_window_flag
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
        CASE WHEN fill_date >= DATE '2023-10-01' THEN 1 ELSE 0 END AS in_window_flag
    FROM bbio_comm_komodo_adh1.export.pharmacy_events

    UNION ALL

    SELECT
        NULLIF(TRIM(CAST(ordering_npi AS STRING)), '') AS npi,
        patient_id,
        service_date AS claim_date,
        CASE
            WHEN INSTR(TRANSLATE(UPPER(TRIM(COALESCE(diagnosis_codes, ''))), '.', ''), 'E20') > 0
             AND CONCAT('|', TRANSLATE(TRANSLATE(UPPER(TRIM(COALESCE(diagnosis_codes, ''))), '.', ''), '*', '|'), '|') RLIKE dx_rx
            THEN 1
            ELSE 0
        END AS dx_claim_flag,
        CASE WHEN service_date >= DATE '2023-10-01' THEN 1 ELSE 0 END AS in_window_flag
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
        COUNT() AS int_total_patients,
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
```

## 1.8 Recommended validation checks

- Confirm that the output row count equals the distinct non-null NPI count in `mdb_09_17`.
- Confirm that `npi` is unique in the output.
- Confirm that all four metric columns are non-negative and non-null.
- Confirm that `patients_ge_16` does not exceed `total_patients`.
- Confirm that `patients_ge_16_in_window` does not exceed `total_patients_in_window`.
- Confirm that in-window counts do not exceed their corresponding all-time counts.
- Spot-check qualifying E20 diagnosis matching across medical, pharmacy, and lab sources.
- Verify that patients in the reliable negative list do not contribute to any metric.

**Validation status:** Not specified in the supplied documentation.

---

# 2. HCP VOD Pediatric Flag Validation

## 2.1 Overview

| Attribute | Details |
|---|---|
| Output table | `comm_dev.pdm_dev_ml_experiments.hcp_vod_ped_flag_validation` |
| Version | `v1` |
| Last updated | `16 October 2026` |
| Grain | One row per distinct NPI in the MDB NPI universe |
| Primary purpose | Identify pediatric HCPs and validate specialty alignment between HCP Demo and VOD |

### Purpose

Identify pediatric HCPs within the MDB NPI universe using specialty information from HCP Demo and VOD. Produce two pediatric flags—one using a hybrid of HCP Demo and VOD specialty positions, and one using VOD specialties only—and compare the first two specialty positions between the two systems.

## 2.2 Source tables

| Source table | Role |
|---|---|
| `comm_dev.commercial_dev_bronze.mdb_09_17` | Defines the NPI universe |
| `comm_dev.commercial_dev_bronze.vod_hcp` | Provides VOD specialty aliases and record metadata |
| `comm_dev.commercial_dev_bronze.vod_reference` | Maps VOD specialty aliases to readable specialty names |
| `comm_dev.pdm_dev_adh1_silver.hcp_demo` | Provides HCP Demo specialty positions 1 and 2 |

## 2.3 Business logic

1. **Define the NPI universe.** Select distinct NPIs from `mdb_09_17`.
2. **Select the latest VOD record.** For each NPI, rank records by `modified_date__v` descending and then `batch_id` descending, with nulls last. Retain the first record.
3. **Prepare the specialty reference.** Filter `vod_reference` to specialty reference rows and retain one readable name per `target_alias` to avoid join fan-out.
4. **Decode VOD specialties.** Map all ten VOD specialty aliases to readable specialty names.
5. **Identify pediatric specialties.** Match decoded specialty names case-insensitively against `pediatric` or `child`.
6. **Create pediatric source indicators.**
   - **Hybrid flag:** HCP Demo specialty positions 1–2 plus VOD specialty positions 3–10.
   - **VOD-only flag:** VOD specialty positions 1–10.
7. **Compare specialty positions 1 and 2.** Compare HCP Demo specialty 1 with VOD specialty 1, and HCP Demo specialty 2 with VOD specialty 2.
8. **Retain audit fields.** Include source specialty names and the positions that triggered each pediatric flag.

## 2.4 Pediatric flag definitions

| Output field | Definition |
|---|---|
| `vod_ped_flag_1` | `1` when the hybrid source identifies a pediatric specialty; otherwise `0` |
| `vod_ped_src_flag_1` | Specialty positions that triggered the hybrid flag, e.g. `S1`, `S2`, `S3`, etc. |
| `vod_ped_flag_2` | `1` when any of VOD specialty positions 1–10 identifies a pediatric specialty; otherwise `0` |
| `vod_ped_src_flag_2` | VOD specialty positions that triggered the VOD-only flag |

The pediatric keyword check is case-insensitive and searches for either `pediatric` or `child`.

## 2.5 Specialty mismatch definitions

| Output field | Definition |
|---|---|
| `spec1_mismatch` | `0` when HCP Demo specialty 1 matches VOD specialty 1 after trimming and case normalization, including null-safe equality; otherwise `1` |
| `spec2_mismatch` | `0` when HCP Demo specialty 2 matches VOD specialty 2 after trimming and case normalization, including null-safe equality; otherwise `1` |

A mismatch flag of `1` indicates that the corresponding specialty positions differ under the comparison logic.

## 2.6 Output columns

| Output column | Description |
|---|---|
| `npi` | NPI from the MDB universe |
| `vod_ped_flag_1` | Hybrid pediatric indicator |
| `vod_ped_src_flag_1` | Source positions triggering the hybrid pediatric indicator |
| `vod_ped_flag_2` | VOD-only pediatric indicator |
| `vod_ped_src_flag_2` | VOD specialty positions triggering the VOD-only pediatric indicator |
| `spec1_mismatch` | Specialty 1 mismatch indicator |
| `spec2_mismatch` | Specialty 2 mismatch indicator |
| `hcp_spec1` | HCP Demo specialty 1 |
| `hcp_spec2` | HCP Demo specialty 2 |
| `vod_spec1`–`vod_spec10` | Decoded VOD specialty names for positions 1–10 |

## 2.7 Key logic and assumptions

- Only NPIs in the MDB universe are included in the final output.
- The latest VOD record is selected using `modified_date__v DESC NULLS LAST`, followed by `batch_id DESC NULLS LAST`.
- The VOD specialty reference is grouped by `target_alias` and uses `MAX(target_alias_name)` to ensure one reference row per alias.
- Pediatric matching uses case-insensitive regular expressions for `pediatric` or `child`.
- The hybrid flag intentionally uses HCP Demo specialty positions 1–2 and VOD specialty positions 3–10. VOD positions 1–2 are not used for the hybrid flag.
- The VOD-only flag evaluates all ten decoded VOD specialty positions.
- Specialty comparisons are trimmed, case-insensitive, and null-safe.
- Source specialty values and pediatric trigger positions are retained for auditability.
- The query aggregates HCP Demo specialty values using `MAX()` by NPI. If multiple source rows exist for an NPI, the selected value is the maximum value under the database's ordering rules; this is not necessarily the latest record unless the source table guarantees one row per NPI.

## 2.8 SQL implementation

```sql
%sql
CREATE OR REPLACE TABLE comm_dev.pdm_dev_ml_experiments.hcp_vod_ped_flag_validation AS

WITH
-- 1. MDB universe (~123K NPIs)
npi_list AS (
    SELECT DISTINCT CAST(npi AS STRING) AS npi
    FROM comm_dev.commercial_dev_bronze.mdb_09_17
),

-- 2. Latest VOD record per NPI
vod AS (
    SELECT * FROM (
        SELECT
            CAST(v.npi_num__v AS STRING) AS npi,
            v.specialty_1__v, v.specialty_2__v, v.specialty_3__v, v.specialty_4__v, v.specialty_5__v,
            v.specialty_6__v, v.specialty_7__v, v.specialty_8__v, v.specialty_9__v, v.specialty_10__v,
            ROW_NUMBER() OVER (
                PARTITION BY v.npi_num__v
                ORDER BY v.modified_date__v DESC NULLS LAST,
                         TRY_CAST(v.batch_id AS BIGINT) DESC NULLS LAST
            ) AS rn
        FROM comm_dev.commercial_dev_bronze.vod_hcp v
        JOIN npi_list n
            ON CAST(v.npi_num__v AS STRING) = n.npi
    )
    WHERE rn = 1
),

-- 3. vod_reference: one specialty name per alias (prevents join fan-out)
ref AS (
    SELECT target_alias, MAX(target_alias_name) AS spec_name
    FROM comm_dev.commercial_dev_bronze.vod_reference
    WHERE reference_type ILIKE 'specialty'
    GROUP BY target_alias
),

-- 4. Decode all 10 VOD specialties
vod_dec AS (
    SELECT
        v.npi,
        r1.spec_name AS vs1,
        r2.spec_name AS vs2,
        r3.spec_name AS vs3,
        r4.spec_name AS vs4,
        r5.spec_name AS vs5,
        r6.spec_name AS vs6,
        r7.spec_name AS vs7,
        r8.spec_name AS vs8,
        r9.spec_name AS vs9,
        r10.spec_name AS vs10
    FROM vod v
    LEFT JOIN ref r1 ON v.specialty_1__v = r1.target_alias
    LEFT JOIN ref r2 ON v.specialty_2__v = r2.target_alias
    LEFT JOIN ref r3 ON v.specialty_3__v = r3.target_alias
    LEFT JOIN ref r4 ON v.specialty_4__v = r4.target_alias
    LEFT JOIN ref r5 ON v.specialty_5__v = r5.target_alias
    LEFT JOIN ref r6 ON v.specialty_6__v = r6.target_alias
    LEFT JOIN ref r7 ON v.specialty_7__v = r7.target_alias
    LEFT JOIN ref r8 ON v.specialty_8__v = r8.target_alias
    LEFT JOIN ref r9 ON v.specialty_9__v = r9.target_alias
    LEFT JOIN ref r10 ON v.specialty_10__v = r10.target_alias
),

-- 5. Pediatric source strings from decoded VOD specialties
vod_ped AS (
    SELECT
        npi,
        vs1, vs2, vs3, vs4, vs5, vs6, vs7, vs8, vs9, vs10,
        NULLIF(
            CONCAT_WS(',',
                CASE WHEN vs3 RLIKE '(?i)pediatric|child' THEN 'S3' END,
                CASE WHEN vs4 RLIKE '(?i)pediatric|child' THEN 'S4' END,
                CASE WHEN vs5 RLIKE '(?i)pediatric|child' THEN 'S5' END,
                CASE WHEN vs6 RLIKE '(?i)pediatric|child' THEN 'S6' END,
                CASE WHEN vs7 RLIKE '(?i)pediatric|child' THEN 'S7' END,
                CASE WHEN vs8 RLIKE '(?i)pediatric|child' THEN 'S8' END,
                CASE WHEN vs9 RLIKE '(?i)pediatric|child' THEN 'S9' END,
                CASE WHEN vs10 RLIKE '(?i)pediatric|child' THEN 'S10' END
            ),
            ''
        ) AS src_3_10,
        NULLIF(
            CONCAT_WS(',',
                CASE WHEN vs1 RLIKE '(?i)pediatric|child' THEN 'S1' END,
                CASE WHEN vs2 RLIKE '(?i)pediatric|child' THEN 'S2' END,
                CASE WHEN vs3 RLIKE '(?i)pediatric|child' THEN 'S3' END,
                CASE WHEN vs4 RLIKE '(?i)pediatric|child' THEN 'S4' END,
                CASE WHEN vs5 RLIKE '(?i)pediatric|child' THEN 'S5' END,
                CASE WHEN vs6 RLIKE '(?i)pediatric|child' THEN 'S6' END,
                CASE WHEN vs7 RLIKE '(?i)pediatric|child' THEN 'S7' END,
                CASE WHEN vs8 RLIKE '(?i)pediatric|child' THEN 'S8' END,
                CASE WHEN vs9 RLIKE '(?i)pediatric|child' THEN 'S9' END,
                CASE WHEN vs10 RLIKE '(?i)pediatric|child' THEN 'S10' END
            ),
            ''
        ) AS src_vod
    FROM vod_dec
),

-- 6. HCP Demo specialties 1 and 2
demo AS (
    SELECT
        CAST(npi AS STRING) AS npi,
        MAX(vod_specialty_1) AS ds1,
        MAX(vod_specialty_2) AS ds2
    FROM comm_dev.pdm_dev_adh1_silver.hcp_demo
    GROUP BY 1
),

-- 7. Combine
base AS (
    SELECT
        n.npi,
        d.ds1, d.ds2,
        v.vs1, v.vs2, v.vs3, v.vs4, v.vs5, v.vs6, v.vs7, v.vs8, v.vs9, v.vs10,
        v.src_vod,
        NULLIF(
            CONCAT_WS(',',
                CASE WHEN d.ds1 RLIKE '(?i)pediatric|child' THEN 'S1' END,
                CASE WHEN d.ds2 RLIKE '(?i)pediatric|child' THEN 'S2' END,
                v.src_3_10
            ),
            ''
        ) AS src_hybrid
    FROM npi_list n
    LEFT JOIN demo d ON n.npi = d.npi
    LEFT JOIN vod_ped v ON n.npi = v.npi
)

SELECT
    npi,
    -- Pediatric flags
    CASE WHEN src_hybrid IS NOT NULL THEN 1 ELSE 0 END AS vod_ped_flag_1,
    src_hybrid AS vod_ped_src_flag_1,
    CASE WHEN src_vod IS NOT NULL THEN 1 ELSE 0 END AS vod_ped_flag_2,
    src_vod AS vod_ped_src_flag_2,

    -- Specialty 1/2 consistency checks
    CASE WHEN UPPER(TRIM(ds1)) <=> UPPER(TRIM(vs1)) THEN 0 ELSE 1 END AS spec1_mismatch,
    CASE WHEN UPPER(TRIM(ds2)) <=> UPPER(TRIM(vs2)) THEN 0 ELSE 1 END AS spec2_mismatch,

    -- HCP Demo specialties
    ds1 AS hcp_spec1,
    ds2 AS hcp_spec2,

    -- VOD decoded specialties
    vs1 AS vod_spec1,
    vs2 AS vod_spec2,
    vs3 AS vod_spec3,
    vs4 AS vod_spec4,
    vs5 AS vod_spec5,
    vs6 AS vod_spec6,
    vs7 AS vod_spec7,
    vs8 AS vod_spec8,
    vs9 AS vod_spec9,
    vs10 AS vod_spec10
FROM base;
```

## 2.9 Recommended validation checks

- Confirm that the output row count equals the distinct NPI count in `mdb_09_17`.
- Confirm that `npi` is unique in the output.
- Compare the number of records with `vod_ped_flag_1 = 1` and `vod_ped_flag_2 = 1`.
- Review the pediatric trigger-source columns to confirm that each positive flag is supported by the expected specialty positions.
- Calculate counts for `spec1_mismatch = 1` and `spec2_mismatch = 1`.
- Spot-check specialty alias decoding against `vod_reference`.
- Confirm that latest-record selection produces no more than one VOD row per NPI.
- Review NPIs with missing HCP Demo or VOD specialty data, since null-versus-non-null comparisons are treated as mismatches by the null-safe comparison.

**Validation status:** Pending.

---

# 3. Change log

| Version | Last updated | Description |
|---|---|---|
| v1 | 16 October 2026 | Initial documentation for ADH HCP patient metrics and HCP VOD pediatric flag validation |

---

# 4. Implementation notes

This document preserves the supplied SQL logic while formatting it for readability and documenting the intended business rules. Before production sign-off, validate the implementation against the checks above.

**Important review note — ADH in-window aggregation:** In the supplied ADH SQL, `pair_iw_dx_flag` is aggregated at the `(npi, patient_id)` grain and then rolled up across all NPIs for a patient. Review whether this patient-level in-window diagnosis flag is intended to qualify every attributed NPI for that patient, or whether diagnosis and claim activity must both be present for the same NPI-patient pair. The current query applies the patient-level diagnosis flag alongside the NPI-patient claim-window flag.

**Important review note — age-based counts:** The ADH query joins year-of-birth records using `SELECT DISTINCT patient_id, YEAR(patient_yob)`. If the demographics source contains multiple distinct birth years for a patient, the join can produce multiple rows for that patient. Confirm that `patient_demographics` provides a consistent year of birth per patient or define a deterministic record-selection rule.
