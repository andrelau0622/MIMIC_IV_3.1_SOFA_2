-- generated; do not edit

-- source: sql/00_preflight.sql
BEGIN;
SET LOCAL lock_timeout = '10s';
SET LOCAL statement_timeout = '0';

CREATE SCHEMA IF NOT EXISTS mimic_sofa2;

DO $preflight$
DECLARE
    required_relation text;
BEGIN
    FOREACH required_relation IN ARRAY ARRAY[
        'mimiciv_icu.icustays',
        'mimiciv_icu.chartevents',
        'mimiciv_icu.procedureevents',
        'mimiciv_hosp.patients',
        'mimiciv_hosp.prescriptions',
        'mimiciv_derived.gcs',
        'mimiciv_derived.bg',
        'mimiciv_derived.oxygen_delivery',
        'mimiciv_derived.ventilation',
        'mimiciv_derived.vitalsign',
        'mimiciv_derived.vasoactive_agent',
        'mimiciv_derived.urine_output_rate',
        'mimiciv_derived.rrt',
        'mimiciv_derived.chemistry',
        'mimiciv_derived.complete_blood_count',
        'mimiciv_derived.enzyme',
        'mimiciv_derived.suspicion_of_infection',
        'mimiciv_derived.sepsis3'
    ] LOOP
        IF to_regclass(required_relation) IS NULL THEN
            RAISE EXCEPTION 'MIMIC-IV preflight failed: missing relation %', required_relation;
        END IF;
    END LOOP;
END
$preflight$;

DROP TABLE IF EXISTS mimic_sofa2.data_quality_report;
DROP TABLE IF EXISTS mimic_sofa2.pipeline_metadata;
DROP TABLE IF EXISTS mimic_sofa2.infection_associated_sofa2_events_exploratory;
DROP TABLE IF EXISTS mimic_sofa2.infection_associated_sofa2_hourly_exploratory;
DROP TABLE IF EXISTS mimic_sofa2.sepsis3_sofa1_reference;
DROP TABLE IF EXISTS mimic_sofa2.suspicion_of_infection;
DROP TABLE IF EXISTS mimic_sofa2.first_day_sofa2;
DROP TABLE IF EXISTS mimic_sofa2.sofa2_daily;
DROP TABLE IF EXISTS mimic_sofa2.sofa2_hourly_rolling_experimental;
DROP TABLE IF EXISTS mimic_sofa2.sofa2_hourly_raw;
DROP TABLE IF EXISTS mimic_sofa2.hourly_features;
DROP TABLE IF EXISTS mimic_sofa2.hour_grid;
DROP TABLE IF EXISTS mimic_sofa2.adult_stays;

-- source: sql/10_score_functions.sql
CREATE OR REPLACE FUNCTION mimic_sofa2.sofa2_brain(
    gcs double precision,
    motor_fallback integer,
    delirium_drug boolean
) RETURNS smallint
LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE AS $$
DECLARE
    score integer;
BEGIN
    IF gcs IS NOT NULL THEN
        score := CASE
            WHEN gcs >= 15 THEN 0
            WHEN gcs >= 13 THEN 1
            WHEN gcs >= 9 THEN 2
            WHEN gcs >= 6 THEN 3
            ELSE 4
        END;
    ELSIF motor_fallback IS NOT NULL THEN
        score := CASE
            WHEN motor_fallback >= 6 THEN 0
            WHEN motor_fallback = 5 THEN 1
            WHEN motor_fallback = 4 THEN 2
            WHEN motor_fallback = 3 THEN 3
            ELSE 4
        END;
    END IF;
    IF COALESCE(delirium_drug, false) THEN
        score := GREATEST(COALESCE(score, 0), 1);
    END IF;
    RETURN score::smallint;
END $$;

CREATE OR REPLACE FUNCTION mimic_sofa2.sofa2_respiratory(
    pf_ratio double precision,
    sf_ratio double precision,
    advanced_support boolean,
    respiratory_ecmo boolean,
    support_unavailable boolean
) RETURNS smallint
LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE AS $$
DECLARE
    supported boolean := COALESCE(advanced_support, false) OR COALESCE(support_unavailable, false);
BEGIN
    IF COALESCE(respiratory_ecmo, false) THEN RETURN 4; END IF;
    IF pf_ratio IS NOT NULL THEN
        RETURN CASE
            WHEN supported AND pf_ratio <= 75 THEN 4
            WHEN supported AND pf_ratio <= 150 THEN 3
            WHEN pf_ratio <= 225 THEN 2
            WHEN pf_ratio <= 300 THEN 1
            ELSE 0
        END;
    ELSIF sf_ratio IS NOT NULL THEN
        RETURN CASE
            WHEN supported AND sf_ratio <= 120 THEN 4
            WHEN supported AND sf_ratio <= 200 THEN 3
            WHEN sf_ratio <= 250 THEN 2
            WHEN sf_ratio <= 300 THEN 1
            ELSE 0
        END;
    END IF;
    RETURN NULL;
END $$;

CREATE OR REPLACE FUNCTION mimic_sofa2.sofa2_cardiovascular(
    map_value double precision,
    norepinephrine_base double precision,
    epinephrine double precision,
    other_agent boolean,
    dopamine double precision,
    mechanical_support boolean,
    drug_unavailable boolean
) RETURNS smallint
LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE AS $$
DECLARE
    catecholamine double precision := COALESCE(norepinephrine_base, 0) + COALESCE(epinephrine, 0);
    dopamine_value double precision := COALESCE(dopamine, 0);
    other_present boolean := COALESCE(other_agent, false) OR dopamine_value > 0;
BEGIN
    IF COALESCE(mechanical_support, false) THEN RETURN 4; END IF;
    IF catecholamine > 0.4 THEN RETURN 4; END IF;
    IF catecholamine > 0.2 THEN
        RETURN CASE WHEN other_present THEN 4 ELSE 3 END;
    END IF;
    IF catecholamine > 0 THEN
        RETURN CASE WHEN other_present THEN 3 ELSE 2 END;
    END IF;
    IF dopamine_value > 40 THEN RETURN 4; END IF;
    IF dopamine_value > 20 THEN RETURN 3; END IF;
    IF dopamine_value > 0 OR COALESCE(other_agent, false) THEN RETURN 2; END IF;
    IF map_value IS NULL THEN RETURN NULL; END IF;
    IF COALESCE(drug_unavailable, false) THEN
        RETURN CASE
            WHEN map_value >= 70 THEN 0
            WHEN map_value >= 60 THEN 1
            WHEN map_value >= 50 THEN 2
            WHEN map_value >= 40 THEN 3
            ELSE 4
        END;
    END IF;
    RETURN CASE WHEN map_value < 70 THEN 1 ELSE 0 END;
END $$;

CREATE OR REPLACE FUNCTION mimic_sofa2.sofa2_liver(bilirubin double precision)
RETURNS smallint LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    SELECT CASE
        WHEN bilirubin IS NULL THEN NULL
        WHEN bilirubin > 12 THEN 4
        WHEN bilirubin > 6 THEN 3
        WHEN bilirubin > 3 THEN 2
        WHEN bilirubin > 1.2 THEN 1
        ELSE 0
    END::smallint
$$;

CREATE OR REPLACE FUNCTION mimic_sofa2.sofa2_hemostasis(platelets double precision)
RETURNS smallint LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    SELECT CASE
        WHEN platelets IS NULL THEN NULL
        WHEN platelets <= 50 THEN 4
        WHEN platelets <= 80 THEN 3
        WHEN platelets <= 100 THEN 2
        WHEN platelets <= 150 THEN 1
        ELSE 0
    END::smallint
$$;

CREATE OR REPLACE FUNCTION mimic_sofa2.sofa2_kidney(
    creatinine double precision,
    uo_rate_6h double precision,
    uo_rate_12h double precision,
    uo_rate_24h double precision,
    anuria_12h boolean,
    rrt boolean,
    rrt_criteria boolean
) RETURNS smallint
LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE AS $$
DECLARE
    score integer;
BEGIN
    IF COALESCE(rrt, false) OR COALESCE(rrt_criteria, false) THEN RETURN 4; END IF;
    IF creatinine IS NOT NULL THEN
        score := CASE
            WHEN creatinine > 3.5 THEN 3
            WHEN creatinine > 2.0 THEN 2
            WHEN creatinine > 1.2 THEN 1
            ELSE 0
        END;
    END IF;
    IF COALESCE(anuria_12h, false) OR (uo_rate_24h IS NOT NULL AND uo_rate_24h < 0.3) THEN
        score := GREATEST(COALESCE(score, 0), 3);
    END IF;
    IF uo_rate_12h IS NOT NULL AND uo_rate_12h < 0.5 THEN
        score := GREATEST(COALESCE(score, 0), 2);
    END IF;
    IF uo_rate_6h IS NOT NULL AND uo_rate_6h < 0.5 THEN
        score := GREATEST(COALESCE(score, 0), 1);
    END IF;
    RETURN score::smallint;
END $$;

-- source: sql/20_hourly_features.sql
-- One row per adult ICU hour. Hour 0 is [ICU intime, ICU intime + 1 hour).
-- Negative hours exist only to support causal pre-ICU baselines.
CREATE TABLE mimic_sofa2.adult_stays AS
SELECT
    ie.subject_id,
    ie.hadm_id,
    ie.stay_id,
    ie.intime,
    ie.outtime,
    COALESCE(
        ie.outtime,
        CASE WHEN ie.los > 0 THEN ie.intime + ie.los * interval '1 day' END,
        ie.intime + interval '24 hours'
    ) AS outtime_effective,
    ie.outtime IS NULL AS outtime_imputed,
    ie.first_careunit,
    ie.last_careunit,
    ie.los,
    p.anchor_age,
    p.gender
FROM mimiciv_icu.icustays AS ie
INNER JOIN mimiciv_hosp.patients AS p
    ON p.subject_id = ie.subject_id
WHERE p.anchor_age >= 18;

ALTER TABLE mimic_sofa2.adult_stays
    ADD CONSTRAINT adult_stays_pk PRIMARY KEY (stay_id),
    ADD CONSTRAINT adult_stays_age_ck CHECK (anchor_age >= 18),
    ADD CONSTRAINT adult_stays_time_ck CHECK (outtime_effective > intime);

CREATE INDEX adult_stays_hadm_time_idx
    ON mimic_sofa2.adult_stays (hadm_id, intime, outtime_effective);

CREATE TABLE mimic_sofa2.hour_grid AS
SELECT
    s.subject_id,
    s.hadm_id,
    s.stay_id,
    h.hr,
    s.intime + h.hr * interval '1 hour' AS hour_start,
    CASE
        WHEN h.hr >= 0 THEN LEAST(
            s.intime + (h.hr + 1) * interval '1 hour',
            s.outtime_effective
        )
        ELSE s.intime + (h.hr + 1) * interval '1 hour'
    END AS hour_end
FROM mimic_sofa2.adult_stays AS s
CROSS JOIN LATERAL generate_series(
    -48,
    GREATEST(
        ceil(extract(epoch FROM (s.outtime_effective - s.intime)) / 3600.0)::integer - 1,
        0
    )
) AS h(hr);

ALTER TABLE mimic_sofa2.hour_grid
    ADD CONSTRAINT hour_grid_pk PRIMARY KEY (stay_id, hr),
    ADD CONSTRAINT hour_grid_time_ck CHECK (hour_end > hour_start);

CREATE INDEX hour_grid_stay_time_idx
    ON mimic_sofa2.hour_grid (stay_id, hour_start, hour_end);
CREATE INDEX hour_grid_hadm_time_idx
    ON mimic_sofa2.hour_grid (hadm_id, hour_start, hour_end);

-- Normalize recorded FiO2 to a fraction. No room-air or device-based FiO2 is imputed.
CREATE TEMP TABLE task_mimic_sofa2_fio2_events ON COMMIT DROP AS
WITH fio2_raw AS (
    SELECT
        ce.stay_id,
        ce.charttime,
        ce.valuenum AS fio2_value,
        'chartevents_223835'::text AS fio2_source,
        1 AS source_priority
    FROM mimiciv_icu.chartevents AS ce
    INNER JOIN mimic_sofa2.adult_stays AS s
        ON s.stay_id = ce.stay_id
       AND ce.charttime >= s.intime - interval '48 hours'
       AND ce.charttime <= s.outtime_effective
    WHERE ce.itemid = 223835
      AND ce.valuenum IS NOT NULL

    UNION ALL

    SELECT
        s.stay_id,
        bg.charttime,
        bg.fio2 AS fio2_value,
        'derived_bg_fio2'::text AS fio2_source,
        2 AS source_priority
    FROM mimiciv_derived.bg AS bg
    INNER JOIN mimic_sofa2.adult_stays AS s
        ON s.hadm_id = bg.hadm_id
       AND bg.charttime >= s.intime - interval '48 hours'
       AND bg.charttime <= s.outtime_effective
    WHERE bg.fio2 IS NOT NULL
), normalized AS (
    SELECT
        stay_id,
        charttime,
        CASE
            WHEN fio2_value BETWEEN 0.21 AND 1.00 THEN fio2_value
            WHEN fio2_value BETWEEN 21.0 AND 100.0 THEN fio2_value / 100.0
        END AS fio2,
        fio2_source,
        source_priority
    FROM fio2_raw
)
SELECT DISTINCT ON (stay_id, charttime)
    stay_id,
    charttime,
    fio2,
    fio2_source
FROM normalized
WHERE fio2 BETWEEN 0.21 AND 1.00
ORDER BY stay_id, charttime, source_priority;

CREATE INDEX task_mimic_sofa2_fio2_events_idx
    ON task_mimic_sofa2_fio2_events (stay_id, charttime);

-- Pair each arterial PaO2 or eligible SpO2 with the latest preceding FiO2 in six hours.
CREATE TEMP TABLE task_mimic_sofa2_oxygen_paired ON COMMIT DROP AS
WITH oxygen_observations AS (
    SELECT
        s.stay_id,
        floor(extract(epoch FROM (bg.charttime - s.intime)) / 3600.0)::integer AS hr,
        bg.charttime AS oxygen_time,
        'PF'::text AS ratio_type,
        bg.po2 AS oxygen_value
    FROM mimiciv_derived.bg AS bg
    INNER JOIN mimic_sofa2.adult_stays AS s
        ON s.hadm_id = bg.hadm_id
       AND bg.charttime >= s.intime - interval '48 hours'
       AND bg.charttime <= s.outtime_effective
    WHERE bg.specimen = 'ART.'
      AND bg.po2 > 0
      AND bg.po2 <= 1000

    UNION ALL

    SELECT
        v.stay_id,
        floor(extract(epoch FROM (v.charttime - s.intime)) / 3600.0)::integer AS hr,
        v.charttime AS oxygen_time,
        'SF'::text AS ratio_type,
        v.spo2 AS oxygen_value
    FROM mimiciv_derived.vitalsign AS v
    INNER JOIN mimic_sofa2.adult_stays AS s
        ON s.stay_id = v.stay_id
       AND v.charttime >= s.intime - interval '48 hours'
       AND v.charttime <= s.outtime_effective
    WHERE v.spo2 > 0
      AND v.spo2 < 98
)
SELECT
    o.stay_id,
    o.hr,
    o.oxygen_time,
    o.ratio_type,
    o.oxygen_value,
    f.charttime AS fio2_time,
    f.fio2,
    f.fio2_source,
    CASE WHEN f.fio2 IS NOT NULL THEN o.oxygen_value / f.fio2 END AS ratio_value
FROM oxygen_observations AS o
LEFT JOIN LATERAL (
    SELECT fe.charttime, fe.fio2, fe.fio2_source
    FROM task_mimic_sofa2_fio2_events AS fe
    WHERE fe.stay_id = o.stay_id
      AND fe.charttime <= o.oxygen_time
      AND fe.charttime >= o.oxygen_time - interval '6 hours'
    ORDER BY fe.charttime DESC
    LIMIT 1
) AS f ON true
WHERE o.hr >= -48;

CREATE INDEX task_mimic_sofa2_oxygen_paired_idx
    ON task_mimic_sofa2_oxygen_paired (stay_id, hr, ratio_type, ratio_value);

-- Convert the pivoted vasoactive table to continuous agent episodes. A drug is
-- eligible only when its episode lasts at least one hour, even if rate changes
-- split the episode into shorter source rows.
CREATE TEMP TABLE task_mimic_sofa2_vaso_segments ON COMMIT DROP AS
WITH agent_rows AS (
    SELECT va.stay_id, va.starttime, va.endtime, x.agent, x.rate
    FROM mimiciv_derived.vasoactive_agent AS va
    CROSS JOIN LATERAL (VALUES
        ('dopamine', va.dopamine),
        ('epinephrine', va.epinephrine),
        ('norepinephrine', va.norepinephrine),
        ('phenylephrine', va.phenylephrine),
        ('vasopressin', va.vasopressin),
        ('dobutamine', va.dobutamine),
        ('milrinone', va.milrinone)
    ) AS x(agent, rate)
    INNER JOIN mimic_sofa2.adult_stays AS s
        ON s.stay_id = va.stay_id
    WHERE x.rate > 0
      AND va.endtime > va.starttime
), ordered AS (
    SELECT
        a.*,
        max(endtime) OVER (
            PARTITION BY stay_id, agent
            ORDER BY starttime, endtime
            ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
        ) AS prior_max_end
    FROM agent_rows AS a
), grouped AS (
    SELECT
        o.*,
        sum(CASE WHEN prior_max_end IS NULL OR starttime > prior_max_end THEN 1 ELSE 0 END)
            OVER (PARTITION BY stay_id, agent ORDER BY starttime, endtime) AS episode_id
    FROM ordered AS o
), labeled AS (
    SELECT
        g.*,
        min(starttime) OVER (PARTITION BY stay_id, agent, episode_id) AS episode_start,
        max(endtime) OVER (PARTITION BY stay_id, agent, episode_id) AS episode_end
    FROM grouped AS g
)
SELECT
    stay_id,
    starttime,
    endtime,
    agent,
    rate,
    episode_start,
    episode_end,
    extract(epoch FROM (episode_end - episode_start)) / 60.0 AS episode_minutes
FROM labeled
WHERE episode_end - episode_start >= interval '1 hour';

CREATE INDEX task_mimic_sofa2_vaso_segments_idx
    ON task_mimic_sofa2_vaso_segments (stay_id, starttime, endtime);

CREATE TABLE mimic_sofa2.hourly_features AS
WITH gcs_ranked AS MATERIALIZED (
    SELECT
        s.stay_id,
        floor(extract(epoch FROM (g.charttime - s.intime)) / 3600.0)::integer AS hr,
        CASE WHEN COALESCE(g.gcs_unable, 0) = 0 THEN g.gcs END AS gcs,
        g.gcs_motor::integer AS gcs_motor,
        g.charttime AS gcs_time,
        row_number() OVER (
            PARTITION BY s.stay_id,
                floor(extract(epoch FROM (g.charttime - s.intime)) / 3600.0)::integer
            ORDER BY mimic_sofa2.sofa2_brain(
                CASE WHEN COALESCE(g.gcs_unable, 0) = 0 THEN g.gcs END,
                g.gcs_motor::integer,
                false
            ) DESC NULLS LAST,
            g.charttime DESC
        ) AS rn
    FROM mimiciv_derived.gcs AS g
    INNER JOIN mimic_sofa2.adult_stays AS s
        ON s.stay_id = g.stay_id
       AND g.charttime >= s.intime - interval '48 hours'
       AND g.charttime <= s.outtime_effective
), gcs_hour AS MATERIALIZED (
    SELECT stay_id, hr, gcs, gcs_motor, gcs_time
    FROM gcs_ranked
    WHERE rn = 1 AND hr >= -48
), delirium_candidates AS MATERIALIZED (
    SELECT
        s.stay_id,
        s.intime,
        p.starttime,
        GREATEST(p.starttime, s.intime - interval '48 hours') AS active_start,
        LEAST(
            COALESCE(p.stoptime, p.starttime + interval '24 hours'),
            s.outtime_effective
        ) AS active_end
    FROM mimic_sofa2.adult_stays AS s
    INNER JOIN mimiciv_hosp.prescriptions AS p
        ON p.hadm_id = s.hadm_id
       AND p.starttime < s.outtime_effective
       AND COALESCE(p.stoptime, p.starttime + interval '24 hours') > s.intime - interval '48 hours'
    WHERE lower(p.drug) ~ '(haloperidol|quetiapine|seroquel|olanzapine|zyprexa|risperidone|risperdal|ziprasidone|geodon|clozapine|aripiprazole|abilify)'
      AND lower(p.drug) !~ 'topical'
), delirium_proxy AS MATERIALIZED (
    SELECT
        d.stay_id,
        x.hr,
        true AS delirium_drug_prescription_proxy,
        min(d.starttime) AS delirium_drug_time
    FROM delirium_candidates AS d
    CROSS JOIN LATERAL generate_series(
        floor(extract(epoch FROM (d.active_start - d.intime)) / 3600.0)::integer,
        floor(extract(epoch FROM (d.active_end - d.intime - interval '1 microsecond')) / 3600.0)::integer
    ) AS x(hr)
    WHERE d.active_end > d.active_start
      AND x.hr >= -48
    GROUP BY d.stay_id, x.hr
), pf_ranked AS MATERIALIZED (
    SELECT
        p.*,
        row_number() OVER (
            PARTITION BY stay_id, hr
            ORDER BY ratio_value ASC NULLS LAST, oxygen_time DESC
        ) AS rn
    FROM task_mimic_sofa2_oxygen_paired AS p
    WHERE ratio_type = 'PF' AND ratio_value IS NOT NULL
), sf_ranked AS MATERIALIZED (
    SELECT
        p.*,
        row_number() OVER (
            PARTITION BY stay_id, hr
            ORDER BY ratio_value ASC NULLS LAST, oxygen_time DESC
        ) AS rn
    FROM task_mimic_sofa2_oxygen_paired AS p
    WHERE ratio_type = 'SF' AND ratio_value IS NOT NULL
), oxygen_unpaired AS MATERIALIZED (
    SELECT stay_id, hr, bool_or(fio2 IS NULL) AS oxygen_without_prior_fio2
    FROM task_mimic_sofa2_oxygen_paired
    GROUP BY stay_id, hr
), respiratory_support AS MATERIALIZED (
    SELECT
        h.stay_id,
        h.hr,
        bool_or(v.ventilation_status IN (
            'InvasiveVent', 'NonInvasiveVent', 'Tracheostomy', 'HFNC'
        )) AS advanced_respiratory_support,
        string_agg(DISTINCT v.ventilation_status, ';' ORDER BY v.ventilation_status) AS respiratory_support_types
    FROM mimic_sofa2.hour_grid AS h
    INNER JOIN mimiciv_derived.ventilation AS v
        ON v.stay_id = h.stay_id
       AND v.starttime < h.hour_end
       AND v.endtime > h.hour_start
    GROUP BY h.stay_id, h.hr
), mechanical_basic AS MATERIALIZED (
    SELECT
        h.stay_id,
        h.hr,
        bool_or(pe.itemid IN (229529, 229530)) AS ecmo_active,
        bool_or(pe.itemid IN (224272, 228169, 228201, 228202)) AS other_mechanical_cv_support,
        string_agg(DISTINCT pe.itemid::text, ';' ORDER BY pe.itemid::text) AS mechanical_support_itemids
    FROM mimic_sofa2.hour_grid AS h
    INNER JOIN mimiciv_icu.procedureevents AS pe
        ON pe.stay_id = h.stay_id
       AND pe.itemid IN (224272, 228169, 228201, 228202, 229529, 229530)
       AND pe.starttime < h.hour_end
       AND pe.endtime > h.hour_start
    GROUP BY h.stay_id, h.hr
), mechanical AS MATERIALIZED (
    SELECT
        m.*,
        c.value AS ecmo_configuration,
        c.charttime AS ecmo_configuration_time,
        COALESCE(c.value ILIKE 'VA%' OR c.value ILIKE 'VAV%', false) AS va_ecmo,
        COALESCE(c.value ILIKE 'VV%', false) AS vv_ecmo,
        m.ecmo_active AND c.value IS NULL AS ecmo_indication_unresolved
    FROM mechanical_basic AS m
    INNER JOIN mimic_sofa2.hour_grid AS h
        ON h.stay_id = m.stay_id AND h.hr = m.hr
    LEFT JOIN LATERAL (
        SELECT ce.value, ce.charttime
        FROM mimiciv_icu.chartevents AS ce
        WHERE m.ecmo_active
          AND ce.stay_id = m.stay_id
          AND ce.itemid = 229268
          AND ce.charttime <= h.hour_end
          AND ce.charttime >= h.hour_end - interval '30 days'
        ORDER BY ce.charttime DESC
        LIMIT 1
    ) AS c ON true
), map_hour AS MATERIALIZED (
    SELECT
        v.stay_id,
        floor(extract(epoch FROM (v.charttime - s.intime)) / 3600.0)::integer AS hr,
        min(v.mbp) FILTER (WHERE v.mbp BETWEEN 20 AND 250) AS map_min,
        min(v.charttime) FILTER (WHERE v.mbp BETWEEN 20 AND 250) AS map_time
    FROM mimiciv_derived.vitalsign AS v
    INNER JOIN mimic_sofa2.adult_stays AS s
        ON s.stay_id = v.stay_id
       AND v.charttime >= s.intime - interval '48 hours'
       AND v.charttime <= s.outtime_effective
    GROUP BY v.stay_id, floor(extract(epoch FROM (v.charttime - s.intime)) / 3600.0)::integer
), vaso_hour AS MATERIALIZED (
    SELECT
        h.stay_id,
        h.hr,
        max(v.rate) FILTER (WHERE v.agent = 'norepinephrine') AS norepinephrine_base,
        max(v.rate) FILTER (WHERE v.agent = 'epinephrine') AS epinephrine,
        max(v.rate) FILTER (WHERE v.agent = 'dopamine') AS dopamine,
        max(v.rate) FILTER (WHERE v.agent = 'phenylephrine') AS phenylephrine,
        max(v.rate) FILTER (WHERE v.agent = 'vasopressin') AS vasopressin,
        max(v.rate) FILTER (WHERE v.agent = 'dobutamine') AS dobutamine,
        max(v.rate) FILTER (WHERE v.agent = 'milrinone') AS milrinone,
        max(v.episode_minutes) AS vasopressor_covered_minutes,
        min(v.starttime) AS vasopressor_evidence_time
    FROM mimic_sofa2.hour_grid AS h
    INNER JOIN task_mimic_sofa2_vaso_segments AS v
        ON v.stay_id = h.stay_id
       AND v.starttime < h.hour_end
       AND v.endtime > h.hour_start
    GROUP BY h.stay_id, h.hr
), chemistry_hour AS MATERIALIZED (
    SELECT
        s.stay_id,
        floor(extract(epoch FROM (c.charttime - s.intime)) / 3600.0)::integer AS hr,
        max(c.creatinine) FILTER (WHERE c.creatinine BETWEEN 0.1 AND 30) AS creatinine,
        max(c.potassium) FILTER (WHERE c.potassium BETWEEN 1 AND 15) AS potassium,
        min(c.bicarbonate) FILTER (WHERE c.bicarbonate BETWEEN 2 AND 60) AS bicarbonate,
        min(c.charttime) AS chemistry_time
    FROM mimiciv_derived.chemistry AS c
    INNER JOIN mimic_sofa2.adult_stays AS s
        ON s.hadm_id = c.hadm_id
       AND c.charttime >= s.intime - interval '48 hours'
       AND c.charttime <= s.outtime_effective
    GROUP BY s.stay_id, floor(extract(epoch FROM (c.charttime - s.intime)) / 3600.0)::integer
), renal_bg_hour AS MATERIALIZED (
    SELECT
        s.stay_id,
        floor(extract(epoch FROM (b.charttime - s.intime)) / 3600.0)::integer AS hr,
        max(b.potassium) FILTER (WHERE b.potassium BETWEEN 1 AND 15) AS potassium,
        min(b.ph) FILTER (WHERE b.ph BETWEEN 6.5 AND 8.0) AS ph,
        min(b.bicarbonate) FILTER (WHERE b.bicarbonate BETWEEN 2 AND 60) AS bicarbonate,
        min(b.charttime) AS bg_renal_time
    FROM mimiciv_derived.bg AS b
    INNER JOIN mimic_sofa2.adult_stays AS s
        ON s.hadm_id = b.hadm_id
       AND b.charttime >= s.intime - interval '48 hours'
       AND b.charttime <= s.outtime_effective
    GROUP BY s.stay_id, floor(extract(epoch FROM (b.charttime - s.intime)) / 3600.0)::integer
), platelet_hour AS MATERIALIZED (
    SELECT
        s.stay_id,
        floor(extract(epoch FROM (c.charttime - s.intime)) / 3600.0)::integer AS hr,
        min(c.platelet) FILTER (WHERE c.platelet BETWEEN 1 AND 2000) AS platelets,
        min(c.charttime) AS platelet_time
    FROM mimiciv_derived.complete_blood_count AS c
    INNER JOIN mimic_sofa2.adult_stays AS s
        ON s.hadm_id = c.hadm_id
       AND c.charttime >= s.intime - interval '48 hours'
       AND c.charttime <= s.outtime_effective
    GROUP BY s.stay_id, floor(extract(epoch FROM (c.charttime - s.intime)) / 3600.0)::integer
), bilirubin_hour AS MATERIALIZED (
    SELECT
        s.stay_id,
        floor(extract(epoch FROM (e.charttime - s.intime)) / 3600.0)::integer AS hr,
        max(e.bilirubin_total) FILTER (WHERE e.bilirubin_total BETWEEN 0 AND 80) AS bilirubin,
        min(e.charttime) AS bilirubin_time
    FROM mimiciv_derived.enzyme AS e
    INNER JOIN mimic_sofa2.adult_stays AS s
        ON s.hadm_id = e.hadm_id
       AND e.charttime >= s.intime - interval '48 hours'
       AND e.charttime <= s.outtime_effective
    GROUP BY s.stay_id, floor(extract(epoch FROM (e.charttime - s.intime)) / 3600.0)::integer
), urine_hour AS MATERIALIZED (
    SELECT
        u.stay_id,
        floor(extract(epoch FROM (u.charttime - s.intime)) / 3600.0)::integer AS hr,
        min(u.uo_mlkghr_6hr::double precision) AS uo_rate_6h,
        min(u.uo_mlkghr_12hr::double precision) AS uo_rate_12h,
        min(u.uo_mlkghr_24hr::double precision) AS uo_rate_24h,
        bool_or(u.urineoutput_12hr = 0 AND u.uo_tm_12hr >= 12) AS anuria_12h,
        min(u.charttime) AS urine_time
    FROM mimiciv_derived.urine_output_rate AS u
    INNER JOIN mimic_sofa2.adult_stays AS s
        ON s.stay_id = u.stay_id
       AND u.charttime >= s.intime - interval '48 hours'
       AND u.charttime <= s.outtime_effective
    GROUP BY u.stay_id, floor(extract(epoch FROM (u.charttime - s.intime)) / 3600.0)::integer
), rrt_hour AS MATERIALIZED (
    SELECT
        r.stay_id,
        floor(extract(epoch FROM (r.charttime - s.intime)) / 3600.0)::integer AS hr,
        bool_or(r.dialysis_present = 1 OR r.dialysis_active = 1) AS rrt,
        min(r.charttime) FILTER (WHERE r.dialysis_present = 1 OR r.dialysis_active = 1) AS rrt_time
    FROM mimiciv_derived.rrt AS r
    INNER JOIN mimic_sofa2.adult_stays AS s
        ON s.stay_id = r.stay_id
       AND r.charttime >= s.intime - interval '48 hours'
       AND r.charttime <= s.outtime_effective
    GROUP BY r.stay_id, floor(extract(epoch FROM (r.charttime - s.intime)) / 3600.0)::integer
)
SELECT
    h.subject_id,
    h.hadm_id,
    h.stay_id,
    h.hr,
    h.hour_start,
    h.hour_end,
    g.gcs,
    g.gcs_motor,
    g.gcs_time,
    COALESCE(d.delirium_drug_prescription_proxy, false) AS delirium_drug_prescription_proxy,
    d.delirium_drug_time,
    d.delirium_drug_prescription_proxy IS TRUE AS delirium_indication_unresolved,
    pf.oxygen_value AS pao2,
    pf.ratio_value AS pf_ratio,
    sf.oxygen_value AS spo2,
    sf.ratio_value AS sf_ratio,
    COALESCE(pf.fio2, sf.fio2) AS fio2,
    COALESCE(pf.oxygen_time, sf.oxygen_time) AS oxygen_time,
    COALESCE(pf.fio2_time, sf.fio2_time) AS fio2_time,
    COALESCE(pf.fio2_source, sf.fio2_source) AS fio2_source,
    COALESCE(ou.oxygen_without_prior_fio2, false) AS oxygen_without_prior_fio2,
    COALESCE(rs.advanced_respiratory_support, false) AS advanced_respiratory_support,
    rs.respiratory_support_types,
    false AS respiratory_support_unavailable,
    COALESCE(m.ecmo_active, false) AS ecmo_active,
    COALESCE(m.va_ecmo, false) AS va_ecmo,
    COALESCE(m.vv_ecmo, false) AS vv_ecmo,
    COALESCE(m.ecmo_indication_unresolved, false) AS ecmo_indication_unresolved,
    m.ecmo_configuration,
    m.ecmo_configuration_time,
    COALESCE(m.other_mechanical_cv_support, false) AS other_mechanical_cv_support,
    m.mechanical_support_itemids,
    mh.map_min,
    mh.map_time,
    vh.norepinephrine_base,
    vh.epinephrine,
    vh.dopamine,
    vh.phenylephrine,
    vh.vasopressin,
    vh.dobutamine,
    vh.milrinone,
    vh.norepinephrine_base IS NOT NULL AS norepinephrine_formulation_unresolved,
    vh.vasopressor_covered_minutes,
    vh.vasopressor_evidence_time,
    vh.vasopressor_covered_minutes IS NOT NULL AS vasopressor_observed,
    ch.creatinine,
    GREATEST(ch.potassium, rb.potassium) AS potassium,
    rb.ph,
    LEAST(ch.bicarbonate, rb.bicarbonate) AS bicarbonate,
    ch.chemistry_time,
    rb.bg_renal_time,
    ph.platelets,
    ph.platelet_time,
    bh.bilirubin,
    bh.bilirubin_time,
    uh.uo_rate_6h,
    uh.uo_rate_12h,
    uh.uo_rate_24h,
    COALESCE(uh.anuria_12h, false) AS anuria_12h,
    uh.urine_time,
    COALESCE(rh.rrt, false) AS rrt,
    rh.rrt_time,
    (
        (ch.creatinine > 1.2 OR uh.uo_rate_24h < 0.3 OR COALESCE(uh.anuria_12h, false))
        AND (
            GREATEST(ch.potassium, rb.potassium) >= 6.0
            OR (rb.ph <= 7.2 AND LEAST(ch.bicarbonate, rb.bicarbonate) <= 12)
        )
    ) IS TRUE AS rrt_criteria_proxy
FROM mimic_sofa2.hour_grid AS h
LEFT JOIN gcs_hour AS g ON g.stay_id = h.stay_id AND g.hr = h.hr
LEFT JOIN delirium_proxy AS d ON d.stay_id = h.stay_id AND d.hr = h.hr
LEFT JOIN pf_ranked AS pf ON pf.stay_id = h.stay_id AND pf.hr = h.hr AND pf.rn = 1
LEFT JOIN sf_ranked AS sf ON sf.stay_id = h.stay_id AND sf.hr = h.hr AND sf.rn = 1
LEFT JOIN oxygen_unpaired AS ou ON ou.stay_id = h.stay_id AND ou.hr = h.hr
LEFT JOIN respiratory_support AS rs ON rs.stay_id = h.stay_id AND rs.hr = h.hr
LEFT JOIN mechanical AS m ON m.stay_id = h.stay_id AND m.hr = h.hr
LEFT JOIN map_hour AS mh ON mh.stay_id = h.stay_id AND mh.hr = h.hr
LEFT JOIN vaso_hour AS vh ON vh.stay_id = h.stay_id AND vh.hr = h.hr
LEFT JOIN chemistry_hour AS ch ON ch.stay_id = h.stay_id AND ch.hr = h.hr
LEFT JOIN renal_bg_hour AS rb ON rb.stay_id = h.stay_id AND rb.hr = h.hr
LEFT JOIN platelet_hour AS ph ON ph.stay_id = h.stay_id AND ph.hr = h.hr
LEFT JOIN bilirubin_hour AS bh ON bh.stay_id = h.stay_id AND bh.hr = h.hr
LEFT JOIN urine_hour AS uh ON uh.stay_id = h.stay_id AND uh.hr = h.hr
LEFT JOIN rrt_hour AS rh ON rh.stay_id = h.stay_id AND rh.hr = h.hr;

ALTER TABLE mimic_sofa2.hourly_features
    ADD CONSTRAINT hourly_features_pk PRIMARY KEY (stay_id, hr),
    ADD CONSTRAINT hourly_features_fio2_ck CHECK (fio2 IS NULL OR fio2 BETWEEN 0.21 AND 1.00),
    ADD CONSTRAINT hourly_features_pair_time_ck CHECK (
        oxygen_time IS NULL
        OR (fio2_time <= oxygen_time AND oxygen_time - fio2_time <= interval '6 hours')
    );

CREATE INDEX hourly_features_hadm_time_idx
    ON mimic_sofa2.hourly_features (hadm_id, hour_end);

COMMENT ON COLUMN mimic_sofa2.hourly_features.norepinephrine_base IS
    'MIMIC source rate used as a base-equivalent proxy; salt/base formulation is not encoded in the source field.';
COMMENT ON COLUMN mimic_sofa2.hourly_features.rrt_criteria_proxy IS
    'Exploratory electronic proxy for severe AKI plus hyperkalemia or severe metabolic acidosis; not a documented RRT treatment.';

-- source: sql/30_hourly_raw.sql
CREATE TABLE mimic_sofa2.sofa2_hourly_raw AS
WITH scored AS (
    SELECT
        f.*,
        mimic_sofa2.sofa2_brain(
            f.gcs,
            f.gcs_motor,
            f.delirium_drug_prescription_proxy
        ) AS brain_score_proxy,
        mimic_sofa2.sofa2_brain(f.gcs, f.gcs_motor, false) AS brain_score_strict,
        mimic_sofa2.sofa2_respiratory(
            f.pf_ratio,
            f.sf_ratio,
            f.advanced_respiratory_support,
            f.ecmo_active,
            f.respiratory_support_unavailable
        ) AS respiratory_score_strict,
        mimic_sofa2.sofa2_cardiovascular(
            f.map_min,
            f.norepinephrine_base,
            f.epinephrine,
            COALESCE(f.phenylephrine, 0) > 0
                OR COALESCE(f.vasopressin, 0) > 0
                OR COALESCE(f.dobutamine, 0) > 0
                OR COALESCE(f.milrinone, 0) > 0,
            f.dopamine,
            f.other_mechanical_cv_support
                OR f.va_ecmo
                OR (f.ecmo_active AND f.ecmo_indication_unresolved),
            false
        ) AS cardiovascular_score_proxy,
        CASE
            WHEN f.norepinephrine_formulation_unresolved THEN NULL
            WHEN f.ecmo_indication_unresolved AND NOT f.other_mechanical_cv_support THEN NULL
            ELSE mimic_sofa2.sofa2_cardiovascular(
                f.map_min,
                f.norepinephrine_base,
                f.epinephrine,
                COALESCE(f.phenylephrine, 0) > 0
                    OR COALESCE(f.vasopressin, 0) > 0
                    OR COALESCE(f.dobutamine, 0) > 0
                    OR COALESCE(f.milrinone, 0) > 0,
                f.dopamine,
                f.other_mechanical_cv_support OR f.va_ecmo,
                false
            )
        END AS cardiovascular_score_strict,
        mimic_sofa2.sofa2_liver(f.bilirubin) AS liver_score_strict,
        mimic_sofa2.sofa2_kidney(
            f.creatinine,
            f.uo_rate_6h,
            f.uo_rate_12h,
            f.uo_rate_24h,
            f.anuria_12h,
            f.rrt,
            f.rrt_criteria_proxy
        ) AS kidney_score_proxy,
        mimic_sofa2.sofa2_kidney(
            f.creatinine,
            f.uo_rate_6h,
            f.uo_rate_12h,
            f.uo_rate_24h,
            f.anuria_12h,
            f.rrt,
            false
        ) AS kidney_score_strict,
        mimic_sofa2.sofa2_hemostasis(f.platelets) AS hemostasis_score_strict
    FROM mimic_sofa2.hourly_features AS f
), operational AS (
    SELECT
        s.*,
        COALESCE(s.brain_score_proxy, 0)::smallint AS brain_score_operational,
        COALESCE(s.respiratory_score_strict, 0)::smallint AS respiratory_score_operational,
        COALESCE(s.cardiovascular_score_proxy, 0)::smallint AS cardiovascular_score_operational,
        COALESCE(s.liver_score_strict, 0)::smallint AS liver_score_operational,
        COALESCE(s.kidney_score_proxy, 0)::smallint AS kidney_score_operational,
        COALESCE(s.hemostasis_score_strict, 0)::smallint AS hemostasis_score_operational
    FROM scored AS s
)
SELECT
    subject_id,
    hadm_id,
    stay_id,
    hr,
    hour_start,
    hour_end AS score_time,
    brain_score_strict,
    brain_score_proxy,
    respiratory_score_strict,
    cardiovascular_score_strict,
    cardiovascular_score_proxy,
    liver_score_strict,
    kidney_score_strict,
    kidney_score_proxy,
    hemostasis_score_strict,
    brain_score_operational,
    respiratory_score_operational,
    cardiovascular_score_operational,
    liver_score_operational,
    kidney_score_operational,
    hemostasis_score_operational,
    (
        brain_score_operational
        + respiratory_score_operational
        + cardiovascular_score_operational
        + liver_score_operational
        + kidney_score_operational
        + hemostasis_score_operational
    )::smallint AS sofa2_total_operational,
    CASE
        WHEN brain_score_strict IS NOT NULL
         AND respiratory_score_strict IS NOT NULL
         AND cardiovascular_score_strict IS NOT NULL
         AND liver_score_strict IS NOT NULL
         AND kidney_score_strict IS NOT NULL
         AND hemostasis_score_strict IS NOT NULL
        THEN (
            brain_score_strict
            + respiratory_score_strict
            + cardiovascular_score_strict
            + liver_score_strict
            + kidney_score_strict
            + hemostasis_score_strict
        )::smallint
    END AS sofa2_total_strict,
    brain_score_strict IS NOT NULL AS brain_observed,
    respiratory_score_strict IS NOT NULL AS respiratory_observed,
    cardiovascular_score_proxy IS NOT NULL AS cardiovascular_observed,
    liver_score_strict IS NOT NULL AS liver_observed,
    kidney_score_proxy IS NOT NULL AS kidney_observed,
    hemostasis_score_strict IS NOT NULL AS hemostasis_observed,
    delirium_indication_unresolved,
    norepinephrine_formulation_unresolved AS dose_unresolved,
    ecmo_indication_unresolved,
    rrt_criteria_proxy
FROM operational;

ALTER TABLE mimic_sofa2.sofa2_hourly_raw
    ADD CONSTRAINT sofa2_hourly_raw_pk PRIMARY KEY (stay_id, hr),
    ADD CONSTRAINT sofa2_hourly_raw_component_ck CHECK (
        brain_score_operational BETWEEN 0 AND 4
        AND respiratory_score_operational BETWEEN 0 AND 4
        AND cardiovascular_score_operational BETWEEN 0 AND 4
        AND liver_score_operational BETWEEN 0 AND 4
        AND kidney_score_operational BETWEEN 0 AND 4
        AND hemostasis_score_operational BETWEEN 0 AND 4
    ),
    ADD CONSTRAINT sofa2_hourly_raw_total_ck CHECK (sofa2_total_operational BETWEEN 0 AND 24);

CREATE INDEX sofa2_hourly_raw_hadm_time_idx
    ON mimic_sofa2.sofa2_hourly_raw (hadm_id, score_time);

COMMENT ON TABLE mimic_sofa2.sofa2_hourly_raw IS
    'Per-hour evidence scores. Operational fields zero-fill missing evidence and use named proxies; strict fields remain NULL when required evidence is absent or semantically unresolved.';

-- source: sql/40_daily_and_rolling.sql
-- Canonical SOFA-2: separate component maxima in ICU-aligned 24-hour days.
-- Day 1 missing components are zero; later missing days use LOCF and expose flags.
CREATE TABLE mimic_sofa2.sofa2_daily AS
WITH RECURSIVE day_raw AS MATERIALIZED (
    SELECT
        r.subject_id,
        r.hadm_id,
        r.stay_id,
        floor(r.hr / 24.0)::integer AS icu_day,
        min(r.hour_start) AS day_start,
        max(r.score_time) AS day_end,
        max(r.brain_score_proxy) AS brain_raw,
        max(r.respiratory_score_strict) AS respiratory_raw,
        max(r.cardiovascular_score_proxy) AS cardiovascular_raw,
        max(r.liver_score_strict) AS liver_raw,
        max(r.kidney_score_proxy) AS kidney_raw,
        max(r.hemostasis_score_strict) AS hemostasis_raw,
        max(r.brain_score_strict) AS brain_strict_raw,
        max(r.cardiovascular_score_strict) AS cardiovascular_strict_raw,
        max(r.kidney_score_strict) AS kidney_strict_raw,
        bool_or(r.delirium_indication_unresolved) AS delirium_indication_unresolved,
        bool_or(r.dose_unresolved) AS dose_unresolved,
        bool_or(r.ecmo_indication_unresolved) AS ecmo_indication_unresolved,
        bool_or(r.rrt_criteria_proxy) AS rrt_criteria_proxy
    FROM mimic_sofa2.sofa2_hourly_raw AS r
    WHERE r.hr >= 0
    GROUP BY r.subject_id, r.hadm_id, r.stay_id, floor(r.hr / 24.0)::integer
), filled AS (
    SELECT
        d.*,
        COALESCE(d.brain_raw, 0)::smallint AS brain,
        COALESCE(d.respiratory_raw, 0)::smallint AS respiratory,
        COALESCE(d.cardiovascular_raw, 0)::smallint AS cardiovascular,
        COALESCE(d.liver_raw, 0)::smallint AS liver,
        COALESCE(d.kidney_raw, 0)::smallint AS kidney,
        COALESCE(d.hemostasis_raw, 0)::smallint AS hemostasis,
        false AS brain_locf,
        false AS respiratory_locf,
        false AS cardiovascular_locf,
        false AS liver_locf,
        false AS kidney_locf,
        false AS hemostasis_locf
    FROM day_raw AS d
    WHERE d.icu_day = 0

    UNION ALL

    SELECT
        d.*,
        COALESCE(d.brain_raw, f.brain)::smallint,
        COALESCE(d.respiratory_raw, f.respiratory)::smallint,
        COALESCE(d.cardiovascular_raw, f.cardiovascular)::smallint,
        COALESCE(d.liver_raw, f.liver)::smallint,
        COALESCE(d.kidney_raw, f.kidney)::smallint,
        COALESCE(d.hemostasis_raw, f.hemostasis)::smallint,
        d.brain_raw IS NULL,
        d.respiratory_raw IS NULL,
        d.cardiovascular_raw IS NULL,
        d.liver_raw IS NULL,
        d.kidney_raw IS NULL,
        d.hemostasis_raw IS NULL
    FROM filled AS f
    INNER JOIN day_raw AS d
        ON d.stay_id = f.stay_id
       AND d.icu_day = f.icu_day + 1
)
SELECT
    subject_id,
    hadm_id,
    stay_id,
    icu_day,
    day_start,
    day_end,
    brain_raw,
    respiratory_raw,
    cardiovascular_raw,
    liver_raw,
    kidney_raw,
    hemostasis_raw,
    brain_strict_raw,
    cardiovascular_strict_raw,
    kidney_strict_raw,
    brain,
    respiratory,
    cardiovascular,
    liver,
    kidney,
    hemostasis,
    (brain + respiratory + cardiovascular + liver + kidney + hemostasis)::smallint
        AS sofa2_total_operational,
    CASE
        WHEN brain_strict_raw IS NOT NULL
         AND respiratory_raw IS NOT NULL
         AND cardiovascular_strict_raw IS NOT NULL
         AND liver_raw IS NOT NULL
         AND kidney_strict_raw IS NOT NULL
         AND hemostasis_raw IS NOT NULL
        THEN (
            brain_strict_raw + respiratory_raw + cardiovascular_strict_raw
            + liver_raw + kidney_strict_raw + hemostasis_raw
        )::smallint
    END AS sofa2_total_strict,
    brain_raw IS NOT NULL AS brain_observed,
    respiratory_raw IS NOT NULL AS respiratory_observed,
    cardiovascular_raw IS NOT NULL AS cardiovascular_observed,
    liver_raw IS NOT NULL AS liver_observed,
    kidney_raw IS NOT NULL AS kidney_observed,
    hemostasis_raw IS NOT NULL AS hemostasis_observed,
    brain_locf,
    respiratory_locf,
    cardiovascular_locf,
    liver_locf,
    kidney_locf,
    hemostasis_locf,
    icu_day = 0 AND brain_raw IS NULL AS brain_missing_day1,
    icu_day = 0 AND respiratory_raw IS NULL AS respiratory_missing_day1,
    icu_day = 0 AND cardiovascular_raw IS NULL AS cardiovascular_missing_day1,
    icu_day = 0 AND liver_raw IS NULL AS liver_missing_day1,
    icu_day = 0 AND kidney_raw IS NULL AS kidney_missing_day1,
    icu_day = 0 AND hemostasis_raw IS NULL AS hemostasis_missing_day1,
    delirium_indication_unresolved,
    dose_unresolved,
    ecmo_indication_unresolved,
    rrt_criteria_proxy,
    'canonical_daily_component_maxima'::text AS aggregation_definition
FROM filled;

ALTER TABLE mimic_sofa2.sofa2_daily
    ADD CONSTRAINT sofa2_daily_pk PRIMARY KEY (stay_id, icu_day),
    ADD CONSTRAINT sofa2_daily_component_ck CHECK (
        brain BETWEEN 0 AND 4
        AND respiratory BETWEEN 0 AND 4
        AND cardiovascular BETWEEN 0 AND 4
        AND liver BETWEEN 0 AND 4
        AND kidney BETWEEN 0 AND 4
        AND hemostasis BETWEEN 0 AND 4
    ),
    ADD CONSTRAINT sofa2_daily_total_ck CHECK (sofa2_total_operational BETWEEN 0 AND 24);

CREATE INDEX sofa2_daily_hadm_day_idx
    ON mimic_sofa2.sofa2_daily (hadm_id, icu_day);

CREATE TABLE mimic_sofa2.first_day_sofa2 AS
SELECT
    subject_id,
    hadm_id,
    stay_id,
    day_start,
    day_end,
    brain,
    respiratory,
    cardiovascular,
    liver,
    kidney,
    hemostasis,
    sofa2_total_operational,
    sofa2_total_strict,
    brain_observed,
    respiratory_observed,
    cardiovascular_observed,
    liver_observed,
    kidney_observed,
    hemostasis_observed,
    brain_missing_day1,
    respiratory_missing_day1,
    cardiovascular_missing_day1,
    liver_missing_day1,
    kidney_missing_day1,
    hemostasis_missing_day1,
    delirium_indication_unresolved,
    dose_unresolved,
    ecmo_indication_unresolved,
    rrt_criteria_proxy
FROM mimic_sofa2.sofa2_daily
WHERE icu_day = 0;

ALTER TABLE mimic_sofa2.first_day_sofa2
    ADD CONSTRAINT first_day_sofa2_pk PRIMARY KEY (stay_id),
    ADD CONSTRAINT first_day_sofa2_total_ck CHECK (sofa2_total_operational BETWEEN 0 AND 24);

-- Research extension only: trailing 24 rows after hourly uniqueness is enforced.
CREATE TABLE mimic_sofa2.sofa2_hourly_rolling_experimental AS
WITH rolling AS (
    SELECT
        r.subject_id,
        r.hadm_id,
        r.stay_id,
        r.hr,
        r.score_time,
        max(r.brain_score_operational) OVER w AS brain,
        max(r.respiratory_score_operational) OVER w AS respiratory,
        max(r.cardiovascular_score_operational) OVER w AS cardiovascular,
        max(r.liver_score_operational) OVER w AS liver,
        max(r.kidney_score_operational) OVER w AS kidney,
        max(r.hemostasis_score_operational) OVER w AS hemostasis,
        max(r.brain_score_strict) OVER w AS brain_strict,
        max(r.respiratory_score_strict) OVER w AS respiratory_strict,
        max(r.cardiovascular_score_strict) OVER w AS cardiovascular_strict,
        max(r.liver_score_strict) OVER w AS liver_strict,
        max(r.kidney_score_strict) OVER w AS kidney_strict,
        max(r.hemostasis_score_strict) OVER w AS hemostasis_strict,
        bool_or(r.brain_observed) OVER w AS brain_observed,
        bool_or(r.respiratory_observed) OVER w AS respiratory_observed,
        bool_or(r.cardiovascular_observed) OVER w AS cardiovascular_observed,
        bool_or(r.liver_observed) OVER w AS liver_observed,
        bool_or(r.kidney_observed) OVER w AS kidney_observed,
        bool_or(r.hemostasis_observed) OVER w AS hemostasis_observed,
        bool_or(r.delirium_indication_unresolved) OVER w AS delirium_indication_unresolved,
        bool_or(r.dose_unresolved) OVER w AS dose_unresolved,
        bool_or(r.ecmo_indication_unresolved) OVER w AS ecmo_indication_unresolved,
        bool_or(r.rrt_criteria_proxy) OVER w AS rrt_criteria_proxy
    FROM mimic_sofa2.sofa2_hourly_raw AS r
    WINDOW w AS (
        PARTITION BY r.stay_id
        ORDER BY r.hr
        ROWS BETWEEN 23 PRECEDING AND CURRENT ROW
    )
)
SELECT
    subject_id,
    hadm_id,
    stay_id,
    hr,
    score_time,
    brain,
    respiratory,
    cardiovascular,
    liver,
    kidney,
    hemostasis,
    (brain + respiratory + cardiovascular + liver + kidney + hemostasis)::smallint
        AS sofa2_total_operational,
    brain_strict,
    respiratory_strict,
    cardiovascular_strict,
    liver_strict,
    kidney_strict,
    hemostasis_strict,
    CASE
        WHEN brain_strict IS NOT NULL
         AND respiratory_strict IS NOT NULL
         AND cardiovascular_strict IS NOT NULL
         AND liver_strict IS NOT NULL
         AND kidney_strict IS NOT NULL
         AND hemostasis_strict IS NOT NULL
        THEN (
            brain_strict + respiratory_strict + cardiovascular_strict
            + liver_strict + kidney_strict + hemostasis_strict
        )::smallint
    END AS sofa2_total_strict,
    brain_observed,
    respiratory_observed,
    cardiovascular_observed,
    liver_observed,
    kidney_observed,
    hemostasis_observed,
    delirium_indication_unresolved,
    dose_unresolved,
    ecmo_indication_unresolved,
    rrt_criteria_proxy,
    'experimental_trailing_24_hour_component_maxima'::text AS aggregation_definition
FROM rolling;

ALTER TABLE mimic_sofa2.sofa2_hourly_rolling_experimental
    ADD CONSTRAINT sofa2_hourly_rolling_pk PRIMARY KEY (stay_id, hr),
    ADD CONSTRAINT sofa2_hourly_rolling_total_ck CHECK (sofa2_total_operational BETWEEN 0 AND 24);

CREATE INDEX sofa2_hourly_rolling_hadm_time_idx
    ON mimic_sofa2.sofa2_hourly_rolling_experimental (hadm_id, score_time);

COMMENT ON TABLE mimic_sofa2.sofa2_daily IS
    'Canonical SOFA-2 daily aggregation: sum of the six separate daily component maxima.';
COMMENT ON TABLE mimic_sofa2.sofa2_hourly_rolling_experimental IS
    'Experimental research extension; not the canonical SOFA-2 daily definition.';

-- source: sql/50_infection_outputs.sql
-- Preserve the official MIMIC Sepsis-3 implementation as a SOFA-1 reference.
-- These fields are never relabeled as SOFA-2 sepsis.
CREATE TABLE mimic_sofa2.sepsis3_sofa1_reference AS
SELECT
    s.subject_id,
    a.hadm_id,
    s.stay_id,
    s.antibiotic_time,
    s.culture_time,
    s.suspected_infection_time,
    s.sofa_time,
    s.sofa_score,
    s.respiration,
    s.coagulation,
    s.liver,
    s.cardiovascular,
    s.cns,
    s.renal,
    s.sepsis3,
    'MIMIC-IV 3.1 official derived Sepsis-3 (SOFA-1)'::text AS definition
FROM mimiciv_derived.sepsis3 AS s
INNER JOIN mimic_sofa2.adult_stays AS a
    ON a.stay_id = s.stay_id;

ALTER TABLE mimic_sofa2.sepsis3_sofa1_reference
    ADD CONSTRAINT sepsis3_sofa1_reference_pk PRIMARY KEY (stay_id);

-- Collapse antibiotic/culture combinations that share a stay and infection
-- anchor into one stable clinical episode while retaining source provenance.
CREATE TABLE mimic_sofa2.suspicion_of_infection AS
WITH mapped AS (
    SELECT
        a.subject_id,
        a.hadm_id,
        a.stay_id,
        si.ab_id,
        si.antibiotic,
        si.antibiotic_time,
        si.suspected_infection_time,
        si.culture_time,
        si.specimen,
        si.positive_culture
    FROM mimiciv_derived.suspicion_of_infection AS si
    INNER JOIN mimic_sofa2.adult_stays AS a
        ON a.stay_id = si.stay_id
    WHERE si.suspected_infection = 1

    UNION ALL

    SELECT
        a.subject_id,
        a.hadm_id,
        a.stay_id,
        si.ab_id,
        si.antibiotic,
        si.antibiotic_time,
        si.suspected_infection_time,
        si.culture_time,
        si.specimen,
        si.positive_culture
    FROM mimiciv_derived.suspicion_of_infection AS si
    INNER JOIN mimic_sofa2.adult_stays AS a
        ON a.hadm_id = si.hadm_id
       AND si.suspected_infection_time >= a.intime - interval '48 hours'
       AND si.suspected_infection_time <= a.outtime_effective + interval '24 hours'
    WHERE si.suspected_infection = 1
      AND si.stay_id IS NULL
), episodes AS (
    SELECT
        subject_id,
        hadm_id,
        stay_id,
        suspected_infection_time,
        min(antibiotic_time) AS antibiotic_time,
        min(culture_time) AS culture_time,
        min(ab_id) AS first_ab_id,
        count(*) AS source_record_count,
        string_agg(DISTINCT antibiotic, '; ' ORDER BY antibiotic) AS antibiotics,
        string_agg(DISTINCT specimen, '; ' ORDER BY specimen) AS specimens,
        bool_or(positive_culture = 1) AS any_positive_culture,
        array_agg(DISTINCT ab_id ORDER BY ab_id) AS source_ab_ids
    FROM mapped
    GROUP BY subject_id, hadm_id, stay_id, suspected_infection_time
)
SELECT
    subject_id,
    hadm_id,
    stay_id,
    row_number() OVER (
        PARTITION BY stay_id
        ORDER BY suspected_infection_time, antibiotic_time, culture_time, first_ab_id
    ) AS event_number,
    suspected_infection_time,
    antibiotic_time,
    culture_time,
    antibiotics,
    specimens,
    any_positive_culture,
    source_record_count,
    source_ab_ids
FROM episodes;

ALTER TABLE mimic_sofa2.suspicion_of_infection
    ADD CONSTRAINT suspicion_of_infection_pk PRIMARY KEY (stay_id, event_number);

CREATE INDEX suspicion_of_infection_anchor_idx
    ON mimic_sofa2.suspicion_of_infection (stay_id, suspected_infection_time);

-- Fixed causal baseline: lowest rolling score from the 48 hours strictly
-- before the infection anchor. Source time is retained for leakage audits.
CREATE TEMP TABLE task_mimic_sofa2_event_baseline ON COMMIT DROP AS
SELECT
    e.stay_id,
    e.event_number,
    op.sofa2_total_operational AS baseline_sofa2_operational,
    op.score_time AS baseline_source_time,
    st.sofa2_total_strict AS baseline_sofa2_strict,
    st.score_time AS strict_baseline_source_time
FROM mimic_sofa2.suspicion_of_infection AS e
LEFT JOIN LATERAL (
    SELECT r.sofa2_total_operational, r.score_time
    FROM mimic_sofa2.sofa2_hourly_rolling_experimental AS r
    WHERE r.stay_id = e.stay_id
      AND r.score_time >= e.suspected_infection_time - interval '48 hours'
      AND r.score_time < e.suspected_infection_time
    ORDER BY r.sofa2_total_operational ASC, r.score_time DESC
    LIMIT 1
) AS op ON true
LEFT JOIN LATERAL (
    SELECT r.sofa2_total_strict, r.score_time
    FROM mimic_sofa2.sofa2_hourly_rolling_experimental AS r
    WHERE r.stay_id = e.stay_id
      AND r.score_time >= e.suspected_infection_time - interval '48 hours'
      AND r.score_time < e.suspected_infection_time
      AND r.sofa2_total_strict IS NOT NULL
    ORDER BY r.sofa2_total_strict ASC, r.score_time DESC
    LIMIT 1
) AS st ON true;

CREATE UNIQUE INDEX task_mimic_sofa2_event_baseline_pk
    ON task_mimic_sofa2_event_baseline (stay_id, event_number);

CREATE TABLE mimic_sofa2.infection_associated_sofa2_hourly_exploratory AS
SELECT
    e.subject_id,
    e.hadm_id,
    e.stay_id,
    e.event_number,
    e.suspected_infection_time,
    e.antibiotic_time,
    e.culture_time,
    r.hr,
    r.score_time,
    r.brain,
    r.respiratory,
    r.cardiovascular,
    r.liver,
    r.kidney,
    r.hemostasis,
    r.sofa2_total_operational,
    r.sofa2_total_strict,
    b.baseline_sofa2_operational,
    b.baseline_source_time,
    b.baseline_sofa2_strict,
    b.strict_baseline_source_time,
    CASE
        WHEN b.baseline_sofa2_operational IS NOT NULL
        THEN r.sofa2_total_operational - b.baseline_sofa2_operational
    END AS delta_observed_baseline,
    r.sofa2_total_operational AS delta_zero_baseline_sensitivity,
    CASE
        WHEN b.baseline_sofa2_strict IS NOT NULL AND r.sofa2_total_strict IS NOT NULL
        THEN r.sofa2_total_strict - b.baseline_sofa2_strict
    END AS delta_strict_observed_baseline,
    COALESCE(
        r.sofa2_total_operational - b.baseline_sofa2_operational >= 2,
        false
    ) AS infection_associated_delta_ge2_observed_baseline,
    r.sofa2_total_operational >= 2
        AS infection_associated_delta_ge2_zero_baseline_sensitivity,
    b.baseline_sofa2_operational IS NULL AS baseline_unobserved,
    r.aggregation_definition
FROM mimic_sofa2.suspicion_of_infection AS e
INNER JOIN mimic_sofa2.sofa2_hourly_rolling_experimental AS r
    ON r.stay_id = e.stay_id
   AND r.score_time >= e.suspected_infection_time
   AND r.score_time <= e.suspected_infection_time + interval '24 hours'
LEFT JOIN task_mimic_sofa2_event_baseline AS b
    ON b.stay_id = e.stay_id
   AND b.event_number = e.event_number;

ALTER TABLE mimic_sofa2.infection_associated_sofa2_hourly_exploratory
    ADD CONSTRAINT infection_associated_sofa2_hourly_pk
        PRIMARY KEY (stay_id, event_number, score_time),
    ADD CONSTRAINT infection_associated_sofa2_hourly_causal_ck CHECK (
        baseline_source_time IS NULL
        OR (baseline_source_time < suspected_infection_time
            AND baseline_source_time < score_time)
    );

CREATE INDEX infection_associated_sofa2_hourly_hadm_idx
    ON mimic_sofa2.infection_associated_sofa2_hourly_exploratory
        (hadm_id, suspected_infection_time);

CREATE TABLE mimic_sofa2.infection_associated_sofa2_events_exploratory AS
SELECT
    e.subject_id,
    e.hadm_id,
    e.stay_id,
    e.event_number,
    e.suspected_infection_time,
    e.antibiotic_time,
    e.culture_time,
    e.antibiotics,
    e.specimens,
    e.any_positive_culture,
    e.source_record_count,
    b.baseline_sofa2_operational,
    b.baseline_source_time,
    b.baseline_sofa2_strict,
    b.strict_baseline_source_time,
    max(h.sofa2_total_operational) AS peak_sofa2_operational,
    max(h.sofa2_total_strict) AS peak_sofa2_strict,
    max(h.delta_observed_baseline) AS delta_observed_baseline,
    max(h.delta_zero_baseline_sensitivity) AS delta_zero_baseline_sensitivity,
    max(h.delta_strict_observed_baseline) AS delta_strict_observed_baseline,
    bool_or(h.infection_associated_delta_ge2_observed_baseline)
        AS infection_associated_delta_ge2_observed_baseline,
    bool_or(h.infection_associated_delta_ge2_zero_baseline_sensitivity)
        AS infection_associated_delta_ge2_zero_baseline_sensitivity,
    min(h.score_time) FILTER (
        WHERE h.infection_associated_delta_ge2_observed_baseline
    ) AS first_delta_ge2_time_observed_baseline,
    min(h.score_time) FILTER (
        WHERE h.infection_associated_delta_ge2_zero_baseline_sensitivity
    ) AS first_delta_ge2_time_zero_baseline_sensitivity,
    count(h.score_time) AS observed_postinfection_hours,
    b.baseline_sofa2_operational IS NULL AS baseline_unobserved,
    'exploratory infection-associated SOFA-2; not Sepsis-3'::text AS interpretation
FROM mimic_sofa2.suspicion_of_infection AS e
LEFT JOIN task_mimic_sofa2_event_baseline AS b
    ON b.stay_id = e.stay_id
   AND b.event_number = e.event_number
LEFT JOIN mimic_sofa2.infection_associated_sofa2_hourly_exploratory AS h
    ON h.stay_id = e.stay_id
   AND h.event_number = e.event_number
GROUP BY
    e.subject_id, e.hadm_id, e.stay_id, e.event_number,
    e.suspected_infection_time, e.antibiotic_time, e.culture_time,
    e.antibiotics, e.specimens, e.any_positive_culture, e.source_record_count,
    b.baseline_sofa2_operational, b.baseline_source_time,
    b.baseline_sofa2_strict, b.strict_baseline_source_time;

ALTER TABLE mimic_sofa2.infection_associated_sofa2_events_exploratory
    ADD CONSTRAINT infection_associated_sofa2_events_pk PRIMARY KEY (stay_id, event_number);

COMMENT ON TABLE mimic_sofa2.infection_associated_sofa2_events_exploratory IS
    'Exploratory infection-associated SOFA-2 deltas. This is not an official Sepsis-3 definition.';

-- source: sql/60_quality_and_metadata.sql
CREATE TABLE mimic_sofa2.data_quality_report (
    check_name text PRIMARY KEY,
    severity text NOT NULL,
    passed boolean NOT NULL,
    observed_value text NOT NULL,
    expected_value text NOT NULL,
    detail text NOT NULL,
    checked_at timestamp with time zone NOT NULL DEFAULT current_timestamp
);

WITH checks AS (
    SELECT
        'adult_stays_nonempty'::text AS check_name,
        count(*)::bigint AS violations,
        'adult_stays must contain at least one row'::text AS detail
    FROM mimic_sofa2.adult_stays
    HAVING count(*) = 0

    UNION ALL

    SELECT
        'hour_grid_raw_row_identity',
        abs(
            (SELECT count(*) FROM mimic_sofa2.hour_grid)
            - (SELECT count(*) FROM mimic_sofa2.sofa2_hourly_raw)
        ),
        'hour grid and raw score tables must have identical row counts'

    UNION ALL

    SELECT
        'hourly_key_duplicates',
        count(*),
        'one raw score row per stay and hour'
    FROM (
        SELECT stay_id, hr
        FROM mimic_sofa2.sofa2_hourly_raw
        GROUP BY 1, 2 HAVING count(*) > 1
    ) AS d

    UNION ALL

    SELECT
        'hourly_score_range',
        count(*),
        'all operational components are 0-4 and total is 0-24'
    FROM mimic_sofa2.sofa2_hourly_raw
    WHERE brain_score_operational NOT BETWEEN 0 AND 4
       OR respiratory_score_operational NOT BETWEEN 0 AND 4
       OR cardiovascular_score_operational NOT BETWEEN 0 AND 4
       OR liver_score_operational NOT BETWEEN 0 AND 4
       OR kidney_score_operational NOT BETWEEN 0 AND 4
       OR hemostasis_score_operational NOT BETWEEN 0 AND 4
       OR sofa2_total_operational NOT BETWEEN 0 AND 24

    UNION ALL

    SELECT
        'fio2_temporal_pairing',
        count(*),
        'FiO2 must be prior to oxygen evidence and no more than six hours old'
    FROM mimic_sofa2.hourly_features
    WHERE oxygen_time IS NOT NULL
      AND (fio2_time IS NULL
           OR fio2_time > oxygen_time
           OR oxygen_time - fio2_time > interval '6 hours')

    UNION ALL

    SELECT
        'daily_total_identity',
        count(*),
        'canonical daily total equals sum of separate component maxima'
    FROM mimic_sofa2.sofa2_daily
    WHERE sofa2_total_operational <>
        brain + respiratory + cardiovascular + liver + kidney + hemostasis

    UNION ALL

    SELECT
        'rolling_total_identity',
        count(*),
        'experimental rolling total equals sum of rolling component maxima'
    FROM mimic_sofa2.sofa2_hourly_rolling_experimental
    WHERE sofa2_total_operational <>
        brain + respiratory + cardiovascular + liver + kidney + hemostasis

    UNION ALL

    SELECT
        'infection_baseline_causality',
        count(*),
        'baseline source must precede both infection anchor and scored hour'
    FROM mimic_sofa2.infection_associated_sofa2_hourly_exploratory
    WHERE baseline_source_time >= suspected_infection_time
       OR baseline_source_time >= score_time

    UNION ALL

    SELECT
        'infection_event_key_duplicates',
        count(*),
        'infection event number must be stable and unique within stay'
    FROM (
        SELECT stay_id, event_number
        FROM mimic_sofa2.suspicion_of_infection
        GROUP BY 1, 2 HAVING count(*) > 1
    ) AS d

    UNION ALL

    SELECT
        'adult_age_scope',
        count(*),
        'SOFA-2 cohort is restricted to anchor age 18 or older'
    FROM mimic_sofa2.adult_stays
    WHERE anchor_age < 18
)
INSERT INTO mimic_sofa2.data_quality_report (
    check_name, severity, passed, observed_value, expected_value, detail
)
SELECT
    check_name,
    CASE WHEN violations = 0 THEN 'pass' ELSE 'blocker' END,
    violations = 0,
    violations::text,
    '0',
    detail
FROM checks;

INSERT INTO mimic_sofa2.data_quality_report (
    check_name, severity, passed, observed_value, expected_value, detail
)
SELECT
    metric,
    'info',
    true,
    value,
    'reported',
    detail
FROM (
    SELECT
        'coverage_brain_percent'::text AS metric,
        round(100.0 * count(*) FILTER (WHERE brain_observed) / NULLIF(count(*), 0), 2)::text AS value,
        'ICU-hour coverage of observed brain evidence'::text AS detail
    FROM mimic_sofa2.sofa2_hourly_raw WHERE hr >= 0

    UNION ALL
    SELECT
        'coverage_respiratory_percent',
        round(100.0 * count(*) FILTER (WHERE respiratory_observed) / NULLIF(count(*), 0), 2)::text,
        'ICU-hour coverage of paired respiratory evidence'
    FROM mimic_sofa2.sofa2_hourly_raw WHERE hr >= 0

    UNION ALL
    SELECT
        'coverage_cardiovascular_percent',
        round(100.0 * count(*) FILTER (WHERE cardiovascular_observed) / NULLIF(count(*), 0), 2)::text,
        'ICU-hour coverage of MAP, qualifying drugs, or mechanical support'
    FROM mimic_sofa2.sofa2_hourly_raw WHERE hr >= 0

    UNION ALL
    SELECT
        'coverage_liver_percent',
        round(100.0 * count(*) FILTER (WHERE liver_observed) / NULLIF(count(*), 0), 2)::text,
        'ICU-hour coverage of bilirubin evidence'
    FROM mimic_sofa2.sofa2_hourly_raw WHERE hr >= 0

    UNION ALL
    SELECT
        'coverage_kidney_percent',
        round(100.0 * count(*) FILTER (WHERE kidney_observed) / NULLIF(count(*), 0), 2)::text,
        'ICU-hour coverage of creatinine, mature urine windows, or RRT evidence'
    FROM mimic_sofa2.sofa2_hourly_raw WHERE hr >= 0

    UNION ALL
    SELECT
        'coverage_hemostasis_percent',
        round(100.0 * count(*) FILTER (WHERE hemostasis_observed) / NULLIF(count(*), 0), 2)::text,
        'ICU-hour coverage of platelet evidence'
    FROM mimic_sofa2.sofa2_hourly_raw WHERE hr >= 0

    UNION ALL
    SELECT
        'unresolved_norepinephrine_hours',
        count(*)::text,
        'qualifying norepinephrine hours with source formulation not encoded'
    FROM mimic_sofa2.sofa2_hourly_raw WHERE dose_unresolved

    UNION ALL
    SELECT
        'unresolved_ecmo_indication_hours',
        count(*)::text,
        'ECMO hours without VA/VV configuration evidence'
    FROM mimic_sofa2.sofa2_hourly_raw WHERE ecmo_indication_unresolved

    UNION ALL
    SELECT
        'infection_events_without_observed_baseline',
        count(*)::text,
        'infection episodes with no causal rolling score in the prior 48 hours'
    FROM mimic_sofa2.infection_associated_sofa2_events_exploratory
    WHERE baseline_unobserved
) AS metrics;

CREATE TABLE mimic_sofa2.pipeline_metadata (
    pipeline_name text PRIMARY KEY,
    definition_version text NOT NULL,
    source_database text NOT NULL,
    source_version text NOT NULL,
    canonical_output text NOT NULL,
    experimental_output text NOT NULL,
    target_schema text NOT NULL,
    source_relation_rows jsonb NOT NULL,
    limitations jsonb NOT NULL,
    built_at timestamp with time zone NOT NULL DEFAULT current_timestamp
);

INSERT INTO mimic_sofa2.pipeline_metadata (
    pipeline_name,
    definition_version,
    source_database,
    source_version,
    canonical_output,
    experimental_output,
    target_schema,
    source_relation_rows,
    limitations
)
SELECT
    'MIMIC-IV SOFA-2',
    'SOFA-2 JAMA 2025; audit 2026-08-03',
    current_database(),
    'MIMIC-IV 3.1',
    'mimic_sofa2.sofa2_daily',
    'mimic_sofa2.sofa2_hourly_rolling_experimental',
    'mimic_sofa2',
    jsonb_build_object(
        'adult_stays', (SELECT count(*) FROM mimic_sofa2.adult_stays),
        'hourly_rows', (SELECT count(*) FROM mimic_sofa2.sofa2_hourly_raw),
        'daily_rows', (SELECT count(*) FROM mimic_sofa2.sofa2_daily),
        'infection_episodes', (SELECT count(*) FROM mimic_sofa2.suspicion_of_infection)
    ),
    jsonb_build_object(
        'norepinephrine', 'source rate treated as base-equivalent proxy; strict cardiovascular score is NULL when exposed',
        'delirium', 'prescription is a proxy because treatment indication is not encoded',
        'ecmo', 'cardiovascular strict score is NULL when VA/VV indication is unresolved',
        'infection', 'SOFA-2 infection association is exploratory and is not Sepsis-3'
    );

COMMENT ON TABLE mimic_sofa2.pipeline_metadata IS
    'Reproducibility metadata and explicit semantic limitations for the generated SOFA-2 outputs.';

COMMIT;
