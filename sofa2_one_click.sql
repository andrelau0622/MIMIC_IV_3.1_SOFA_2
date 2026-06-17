-- =================================================================
-- 步骤 0: 环境配置与清理
-- =================================================================
SET work_mem = '2047MB';
SET maintenance_work_mem = '2047MB';
SET max_parallel_workers = 24;
SET max_parallel_workers_per_gather = 12;
SET enable_partitionwise_join = on;
SET enable_partitionwise_aggregate = on;
SET enable_parallel_hash = on;
SET jit = off;

DROP TABLE IF EXISTS mimiciv_derived.sofa2_stage1_sedation CASCADE;
DROP TABLE IF EXISTS mimiciv_derived.sofa2_stage1_vent CASCADE;
DROP TABLE IF EXISTS mimiciv_derived.sofa2_stage1_sf CASCADE;
DROP TABLE IF EXISTS mimiciv_derived.sofa2_stage1_mech CASCADE;
DROP TABLE IF EXISTS mimiciv_derived.sofa2_stage1_bilirubin CASCADE;
DROP TABLE IF EXISTS mimiciv_derived.sofa2_stage1_kidney_labs CASCADE;
DROP TABLE IF EXISTS mimiciv_derived.sofa2_stage1_rrt CASCADE;
DROP TABLE IF EXISTS mimiciv_derived.sofa2_stage1_urine CASCADE;
DROP TABLE IF EXISTS mimiciv_derived.sofa2_stage1_platelets CASCADE;
DROP TABLE IF EXISTS mimiciv_derived.sofa2_hourly_raw CASCADE;
DROP TABLE IF EXISTS mimiciv_derived.sofa2_stage1_delirium CASCADE;
DROP TABLE IF EXISTS mimiciv_derived.sofa2_stage1_brain CASCADE;
DROP TABLE IF EXISTS mimiciv_derived.sofa2_stage1_resp_support CASCADE;
DROP TABLE IF EXISTS mimiciv_derived.sofa2_stage1_oxygen CASCADE;
DROP TABLE IF EXISTS mimiciv_derived.sofa2_stage1_coag CASCADE;
DROP TABLE IF EXISTS mimiciv_derived.sofa2_stage1_liver CASCADE;

-- =================================================================
-- 步骤 1: 创建基于ICU入院时间的hourly表
-- =================================================================
DROP TABLE IF EXISTS mimiciv_derived.icustay_hourly_basedon_icuintime CASCADE;

CREATE OR REPLACE TEMP VIEW last_icu_time AS
SELECT stay_id, MAX(charttime) as last_charttime
FROM mimiciv_icu.chartevents
WHERE stay_id IN (SELECT stay_id FROM mimiciv_icu.icustays WHERE outtime IS NULL)
GROUP BY stay_id;

CREATE TABLE mimiciv_derived.icustay_hourly_basedon_icuintime AS
WITH all_hours AS (
  SELECT ie.stay_id,
    CASE WHEN DATE_TRUNC('HOUR', ie.intime) = ie.intime THEN ie.intime
      ELSE DATE_TRUNC('HOUR', ie.intime) + INTERVAL '1 HOUR' END AS endtime,
    CASE WHEN ie.outtime IS NOT NULL THEN
        ARRAY(SELECT * FROM GENERATE_SERIES(-24, CAST(CEIL(EXTRACT(EPOCH FROM (ie.outtime - ie.intime)) / 3600.0) AS INT)))
      ELSE
        ARRAY(SELECT * FROM GENERATE_SERIES(-24, GREATEST(CAST(CEIL(EXTRACT(EPOCH FROM (COALESCE(lt.last_charttime, ie.intime + INTERVAL '7 days')) - ie.intime)) / 3600.0 AS INT), 24)))
    END AS hrs
  FROM mimiciv_icu.icustays ie
  LEFT JOIN last_icu_time lt ON ie.stay_id = lt.stay_id
)
SELECT stay_id, CAST(hr_unnested AS BIGINT) AS hr, endtime + CAST(hr_unnested AS BIGINT) * INTERVAL '1 HOUR' AS endtime
FROM all_hours CROSS JOIN UNNEST(all_hours.hrs) AS _t0(hr_unnested);

CREATE INDEX idx_icustay_hourly_basedon_icuintime_stay_hr ON mimiciv_derived.icustay_hourly_basedon_icuintime(stay_id, hr);
CREATE INDEX idx_icustay_hourly_basedon_icuintime_endtime ON mimiciv_derived.icustay_hourly_basedon_icuintime(endtime);
DROP VIEW IF EXISTS last_icu_time;

-- =================================================================
-- 步骤 2: 生成各组件中间表 (已打补丁)
-- =================================================================
CREATE UNLOGGED TABLE mimiciv_derived.sofa2_stage1_sedation AS
SELECT stay_id, starttime, endtime FROM mimiciv_icu.inputevents
WHERE itemid IN (222168, 221668, 229420, 225150, 221385, 221712, 221756, 225156) AND amount > 0;
CREATE INDEX idx_st1_sedation ON mimiciv_derived.sofa2_stage1_sedation(stay_id, starttime, endtime);

CREATE UNLOGGED TABLE mimiciv_derived.sofa2_stage1_delirium AS
SELECT ih.stay_id, ih.hr, MAX(1) AS on_delirium_med
FROM mimiciv_derived.icustay_hourly_basedon_icuintime ih
JOIN mimiciv_icu.icustays ie ON ih.stay_id = ie.stay_id
JOIN mimiciv_hosp.prescriptions pr ON ie.hadm_id = pr.hadm_id
WHERE (pr.drug ILIKE '%haloperidol%' OR pr.drug ILIKE '%quetiapine%' OR pr.drug ILIKE '%seroquel%' 
    OR pr.drug ILIKE '%olanzapine%' OR pr.drug ILIKE '%zyprexa%' OR pr.drug ILIKE '%risperidone%' 
    OR pr.drug ILIKE '%risperdal%' OR pr.drug ILIKE '%ziprasidone%' OR pr.drug ILIKE '%geodon%' 
    OR pr.drug ILIKE '%clozapine%' OR pr.drug ILIKE '%aripiprazole%' OR pr.drug ILIKE '%abilify%')
AND pr.drug NOT ILIKE '%TOPICAL%' AND pr.starttime <= ih.endtime AND COALESCE(pr.stoptime, pr.starttime + INTERVAL '24 hours') >= ih.endtime - INTERVAL '1 HOUR'
GROUP BY ih.stay_id, ih.hr;
CREATE INDEX idx_st1_delirium ON mimiciv_derived.sofa2_stage1_delirium(stay_id, hr);

CREATE UNLOGGED TABLE mimiciv_derived.sofa2_stage1_brain AS
WITH gcs_base AS (
    SELECT g.stay_id, g.charttime, 
        CASE WHEN g.gcs_unable = 1 THEN CASE WHEN g.gcs_motor <= 2 THEN 4 WHEN g.gcs_motor = 3 THEN 3 WHEN g.gcs_motor = 4 THEN 2 WHEN g.gcs_motor = 5 THEN 1 WHEN g.gcs_motor = 6 THEN 0 ELSE NULL END
             ELSE COALESCE(
                CASE WHEN g.gcs <= 5 THEN 4 WHEN g.gcs <= 8 THEN 3 WHEN g.gcs <= 12 THEN 2 WHEN g.gcs <= 14 THEN 1 WHEN g.gcs = 15 THEN 0 ELSE NULL END,
                CASE WHEN g.gcs_motor <= 2 THEN 4 WHEN g.gcs_motor = 3 THEN 3 WHEN g.gcs_motor = 4 THEN 2 WHEN g.gcs_motor = 5 THEN 1 WHEN g.gcs_motor = 6 THEN 0 ELSE NULL END
             ) END AS brain_score_raw,
        CASE WHEN s.stay_id IS NOT NULL THEN 1 ELSE 0 END AS is_sedated
    FROM mimiciv_derived.gcs g
    LEFT JOIN mimiciv_derived.sofa2_stage1_sedation s ON g.stay_id = s.stay_id AND g.charttime >= s.starttime AND g.charttime <= s.endtime
),
gcs_grouping AS (
    SELECT stay_id, charttime, is_sedated, CASE WHEN is_sedated = 0 THEN brain_score_raw ELSE NULL END AS valid_score,
        COUNT(CASE WHEN is_sedated = 0 THEN 1 END) OVER (PARTITION BY stay_id ORDER BY charttime) as grp
    FROM gcs_base
),
gcs_resolved AS (
    SELECT stay_id, charttime, FIRST_VALUE(valid_score) OVER (PARTITION BY stay_id, grp ORDER BY charttime) AS effective_score FROM gcs_grouping
)
SELECT stay_id, charttime AS starttime, LEAD(charttime, 1, 'infinity'::timestamp) OVER (PARTITION BY stay_id ORDER BY charttime) AS endtime,
    COALESCE(effective_score, 0) AS brain_score_final FROM gcs_resolved;
CREATE INDEX idx_st1_brain ON mimiciv_derived.sofa2_stage1_brain(stay_id, starttime, endtime);

CREATE UNLOGGED TABLE mimiciv_derived.sofa2_stage1_resp_support AS
SELECT ih.stay_id, ih.hr, MAX(1) AS with_resp_support
FROM mimiciv_derived.icustay_hourly_basedon_icuintime ih JOIN mimiciv_derived.ventilation v ON ih.stay_id = v.stay_id
WHERE ih.endtime > v.starttime AND ih.endtime - INTERVAL '1 HOUR' < v.endtime AND v.ventilation_status IN ('InvasiveVent', 'NonInvasiveVent', 'Tracheostomy', 'HFNC')
GROUP BY ih.stay_id, ih.hr;
CREATE INDEX idx_st1_resp_sup ON mimiciv_derived.sofa2_stage1_resp_support(stay_id, hr);

CREATE UNLOGGED TABLE mimiciv_derived.sofa2_stage1_mech AS
SELECT ih.stay_id, ih.hr,
    MAX(CASE WHEN ce.itemid IN (224660, 229270, 229277, 229280, 229278, 229363, 229364, 229365, 228193) THEN 1 ELSE 0 END) AS is_ecmo,
    MAX(CASE WHEN ce.itemid = 229268 AND ce.value = 'VV' THEN 1 ELSE 0 END) AS is_vv_ecmo,
    MAX(CASE WHEN ce.itemid = 229268 AND ce.value IN ('VA', 'VAV') THEN 1 ELSE 0 END) AS is_va_ecmo,
    MAX(CASE WHEN ce.itemid = 229268 AND (ce.value = '---' OR ce.value IS NULL OR ce.value = '') THEN 1 ELSE 0 END) AS is_ecmo_unknown_type,
    MAX(CASE WHEN ce.itemid IN (224322, 227980, 225980, 228866, 228154, 229671, 229897, 229898, 229899, 229900, 220125, 220128, 229254, 229262, 229255, 229263) THEN 1 ELSE 0 END) AS is_other_mech
FROM mimiciv_derived.icustay_hourly_basedon_icuintime ih
LEFT JOIN mimiciv_icu.chartevents ce ON ih.stay_id = ce.stay_id AND ce.charttime >= ih.endtime - INTERVAL '1 HOUR' AND ce.charttime <= ih.endtime
AND ce.itemid IN (224660, 229270, 229277, 229280, 229278, 229363, 229364, 229365, 228193, 229268, 224322, 227980, 225980, 228866, 228154, 229671, 229897, 229898, 229899, 229900, 220125, 220128, 229254, 229262, 229255, 229263)
GROUP BY ih.stay_id, ih.hr;
CREATE INDEX idx_st1_mech ON mimiciv_derived.sofa2_stage1_mech(stay_id, hr);

CREATE UNLOGGED TABLE mimiciv_derived.sofa2_stage1_oxygen AS
WITH fio2_raw AS (
    SELECT stay_id, charttime, fio2, source, ROW_NUMBER() OVER (PARTITION BY stay_id, charttime ORDER BY priority) as rn
    FROM (
        SELECT ie.stay_id, bg.charttime, bg.fio2, 'bg' as source, 1 as priority FROM mimiciv_derived.bg bg JOIN mimiciv_icu.icustays ie ON bg.hadm_id = ie.hadm_id AND bg.charttime >= ie.intime AND bg.charttime <= ie.outtime WHERE bg.fio2 IS NOT NULL
        UNION ALL
        SELECT stay_id, charttime, valuenum AS fio2, 'ce' as source, 2 as priority FROM mimiciv_icu.chartevents WHERE itemid = 223835 AND valuenum > 0
    ) x
),
fio2_all AS (SELECT stay_id, charttime, fio2 FROM fio2_raw WHERE rn = 1),
spo2_all AS (SELECT stay_id, charttime, valuenum AS spo2 FROM mimiciv_icu.chartevents WHERE itemid = 220277 AND valuenum > 0 AND valuenum <= 100),
pao2_all AS (SELECT ie.stay_id, bg.charttime, bg.po2 AS pao2 FROM mimiciv_derived.bg bg JOIN mimiciv_icu.icustays ie ON bg.hadm_id = ie.hadm_id AND bg.charttime >= ie.intime AND bg.charttime <= ie.outtime WHERE bg.specimen = 'ART.' AND bg.po2 IS NOT NULL)
SELECT ih.stay_id, ih.hr,
    ((ARRAY_AGG(p.pao2 ORDER BY p.charttime DESC))[1] / NULLIF(COALESCE((ARRAY_AGG(f.fio2 ORDER BY f.charttime DESC))[1], 21), 0) * 100) AS pf_ratio,
    ((ARRAY_AGG(s.spo2 ORDER BY s.charttime DESC))[1] / NULLIF(COALESCE((ARRAY_AGG(f.fio2 ORDER BY f.charttime DESC))[1], 21), 0) * 100) AS sf_ratio,
    (ARRAY_AGG(s.spo2 ORDER BY s.charttime DESC))[1] AS raw_spo2
FROM mimiciv_derived.icustay_hourly_basedon_icuintime ih
LEFT JOIN pao2_all p ON ih.stay_id = p.stay_id AND p.charttime > ih.endtime - INTERVAL '1 HOUR' AND p.charttime <= ih.endtime
LEFT JOIN spo2_all s ON ih.stay_id = s.stay_id AND s.charttime > ih.endtime - INTERVAL '1 HOUR' AND s.charttime <= ih.endtime
LEFT JOIN fio2_all f ON ih.stay_id = f.stay_id AND f.charttime > ih.endtime - INTERVAL '1 HOUR' AND f.charttime <= ih.endtime
WHERE ih.hr >= -24 GROUP BY ih.stay_id, ih.hr;
CREATE INDEX idx_st1_oxy ON mimiciv_derived.sofa2_stage1_oxygen(stay_id, hr);

CREATE UNLOGGED TABLE mimiciv_derived.sofa2_stage1_kidney_labs AS
SELECT ih.stay_id, ih.hr, MAX(chem.creatinine) AS creatinine, GREATEST(MAX(chem.potassium), MAX(bg.potassium)) AS potassium, MIN(bg.ph) AS ph, LEAST(MIN(chem.bicarbonate), MIN(bg.bicarbonate)) AS bicarbonate
FROM mimiciv_derived.icustay_hourly_basedon_icuintime ih INNER JOIN mimiciv_icu.icustays ie ON ih.stay_id = ie.stay_id
LEFT JOIN mimiciv_derived.chemistry chem ON ie.hadm_id = chem.hadm_id AND chem.charttime > ih.endtime - INTERVAL '1 HOUR' AND chem.charttime <= ih.endtime
LEFT JOIN mimiciv_derived.bg bg ON ie.hadm_id = bg.hadm_id AND bg.charttime > ih.endtime - INTERVAL '1 HOUR' AND bg.charttime <= ih.endtime
WHERE ih.hr >= -24 GROUP BY ih.stay_id, ih.hr;
CREATE INDEX idx_st1_klabs ON mimiciv_derived.sofa2_stage1_kidney_labs(stay_id, hr);

CREATE UNLOGGED TABLE mimiciv_derived.sofa2_stage1_rrt AS
SELECT ih.stay_id, ih.hr, MAX(CASE WHEN rrt.dialysis_present = 1 OR rrt.dialysis_active = 1 THEN 1 ELSE 0 END) AS on_rrt
FROM mimiciv_derived.icustay_hourly_basedon_icuintime ih LEFT JOIN mimiciv_derived.rrt rrt ON ih.stay_id = rrt.stay_id AND rrt.charttime >= ih.endtime - INTERVAL '1 HOUR' AND rrt.charttime <= ih.endtime
WHERE ih.hr >= -24 GROUP BY ih.stay_id, ih.hr;
CREATE INDEX idx_st1_rrt ON mimiciv_derived.sofa2_stage1_rrt(stay_id, hr);

-- 尿量：已应用肾脏补丁，输出三个窗口的速率
CREATE UNLOGGED TABLE mimiciv_derived.sofa2_stage1_urine AS
WITH weight_avg_whole_stay AS (SELECT stay_id, AVG(weight) as weight_full_avg FROM mimiciv_derived.weight_durations WHERE weight > 0 GROUP BY stay_id),
weight_from_ce AS (SELECT stay_id, AVG(CASE WHEN itemid = 226531 THEN valuenum * 0.453592 ELSE valuenum END) as weight_ce FROM mimiciv_icu.chartevents WHERE itemid IN (224639, 226512, 226531) AND valuenum > 0 AND ((itemid IN (224639, 226512) AND valuenum BETWEEN 20 AND 300) OR (itemid = 226531 AND valuenum BETWEEN 44 AND 660)) GROUP BY stay_id),
weight_final AS (SELECT ie.stay_id, COALESCE(fd.weight_admit, fd.weight, ws.weight_full_avg, ce.weight_ce, CASE WHEN p.gender = 'F' THEN 70.0 ELSE 83.3 END) AS weight FROM mimiciv_icu.icustays ie JOIN mimiciv_hosp.patients p ON ie.subject_id = p.subject_id LEFT JOIN mimiciv_derived.first_day_weight fd ON ie.stay_id = fd.stay_id LEFT JOIN weight_avg_whole_stay ws ON ie.stay_id = ws.stay_id LEFT JOIN weight_from_ce ce ON ie.stay_id = ce.stay_id),
uo_grid AS (SELECT ih.stay_id, ih.hr, ih.endtime, SUM(uo.urineoutput) AS uo_vol_hourly FROM mimiciv_derived.icustay_hourly_basedon_icuintime ih LEFT JOIN mimiciv_derived.urine_output uo ON ih.stay_id = uo.stay_id AND uo.charttime > ih.endtime - INTERVAL '1 HOUR' AND uo.charttime <= ih.endtime WHERE ih.hr >= -24 GROUP BY ih.stay_id, ih.hr, ih.endtime)
SELECT g.stay_id, g.hr, w.weight,
    SUM(uo_vol_hourly) OVER w6 AS uo_sum_6h, SUM(uo_vol_hourly) OVER w12 AS uo_sum_12h, SUM(uo_vol_hourly) OVER w24 AS uo_sum_24h,
    COUNT(*) OVER w6 AS cnt_6h, COUNT(*) OVER w12 AS cnt_12h, COUNT(*) OVER w24 AS cnt_24h,
    CASE WHEN g.hr >= 6  AND w.weight > 0 THEN SUM(uo_vol_hourly) OVER w6  / w.weight / 6 END AS rate_6h,
    CASE WHEN g.hr >= 12 AND w.weight > 0 THEN SUM(uo_vol_hourly) OVER w12 / w.weight / 12 END AS rate_12h,
    CASE WHEN g.hr >= 24 AND w.weight > 0 THEN SUM(uo_vol_hourly) OVER w24 / w.weight / 24 END AS rate_24h
FROM uo_grid g JOIN weight_final w ON g.stay_id = w.stay_id
WINDOW w6  AS (PARTITION BY g.stay_id ORDER BY g.hr ROWS BETWEEN 5 PRECEDING AND CURRENT ROW),
       w12 AS (PARTITION BY g.stay_id ORDER BY g.hr ROWS BETWEEN 11 PRECEDING AND CURRENT ROW),
       w24 AS (PARTITION BY g.stay_id ORDER BY g.hr ROWS BETWEEN 23 PRECEDING AND CURRENT ROW);
CREATE INDEX idx_st1_urine ON mimiciv_derived.sofa2_stage1_urine(stay_id, hr);

CREATE UNLOGGED TABLE mimiciv_derived.sofa2_stage1_coag AS
WITH plt_raw AS (SELECT hadm_id, charttime, platelet FROM mimiciv_derived.complete_blood_count WHERE platelet IS NOT NULL)
SELECT ih.stay_id, ih.hr, MIN(p.platelet) AS platelet_min FROM mimiciv_derived.icustay_hourly_basedon_icuintime ih JOIN mimiciv_icu.icustays ie ON ih.stay_id = ie.stay_id LEFT JOIN plt_raw p ON ie.hadm_id = p.hadm_id AND p.charttime > ih.endtime - INTERVAL '48 HOUR' AND p.charttime <= ih.endtime WHERE ih.hr >= -24 GROUP BY ih.stay_id, ih.hr;
CREATE INDEX idx_st1_coag ON mimiciv_derived.sofa2_stage1_coag(stay_id, hr);

CREATE UNLOGGED TABLE mimiciv_derived.sofa2_stage1_liver AS
WITH bili_raw AS (SELECT hadm_id, charttime, bilirubin_total FROM mimiciv_derived.enzyme WHERE bilirubin_total IS NOT NULL)
SELECT ih.stay_id, ih.hr, MAX(b.bilirubin_total) AS bilirubin_max FROM mimiciv_derived.icustay_hourly_basedon_icuintime ih JOIN mimiciv_icu.icustays ie ON ih.stay_id = ie.stay_id LEFT JOIN bili_raw b ON ie.hadm_id = b.hadm_id AND b.charttime > ih.endtime - INTERVAL '48 HOUR' AND b.charttime <= ih.endtime WHERE ih.hr >= -24 GROUP BY ih.stay_id, ih.hr;
CREATE INDEX idx_st1_liver ON mimiciv_derived.sofa2_stage1_liver(stay_id, hr);


-- =================================================================
-- 步骤 3: 计算每小时原始评分 (已打补丁)
-- =================================================================
CREATE TABLE mimiciv_derived.sofa2_hourly_raw AS
WITH co AS (
    SELECT ih.stay_id, ie.hadm_id, ie.subject_id, hr, ih.endtime - INTERVAL '1 HOUR' AS starttime, ih.endtime
    FROM mimiciv_derived.icustay_hourly_basedon_icuintime ih INNER JOIN mimiciv_icu.icustays ie ON ih.stay_id = ie.stay_id
),
brain_sofa AS (
    SELECT co.stay_id, co.hr, CASE WHEN COALESCE(br.brain_score_final, 0) = 0 AND COALESCE(ds.on_delirium_med, 0) = 1 THEN 1 ELSE COALESCE(br.brain_score_final, 0) END AS brain_score
    FROM co LEFT JOIN mimiciv_derived.sofa2_stage1_brain br ON co.stay_id = br.stay_id AND co.endtime > br.starttime AND co.endtime <= br.endtime
    LEFT JOIN mimiciv_derived.sofa2_stage1_delirium ds ON co.stay_id = ds.stay_id AND co.hr = ds.hr
),
resp_sofa AS (
    SELECT co.stay_id, co.hr, CASE
        WHEN ec.is_ecmo = 1 OR ec.is_vv_ecmo = 1 OR ec.is_va_ecmo = 1 OR ec.is_ecmo_unknown_type = 1 THEN 4
        WHEN ox.pf_ratio IS NOT NULL THEN CASE WHEN ox.pf_ratio <= 75 AND rs.with_resp_support = 1 THEN 4 WHEN ox.pf_ratio <= 150 AND rs.with_resp_support = 1 THEN 3 WHEN ox.pf_ratio <= 225 THEN 2 WHEN ox.pf_ratio <= 300 THEN 1 ELSE 0 END
        WHEN ox.sf_ratio IS NOT NULL AND ox.raw_spo2 < 98 THEN CASE WHEN ox.sf_ratio <= 120 AND rs.with_resp_support = 1 THEN 4 WHEN ox.sf_ratio <= 200 AND rs.with_resp_support = 1 THEN 3 WHEN ox.sf_ratio <= 250 THEN 2 WHEN ox.sf_ratio <= 300 THEN 1 ELSE 0 END
        ELSE 0 END AS respiratory_score
    FROM co LEFT JOIN mimiciv_derived.sofa2_stage1_resp_support rs ON co.stay_id = rs.stay_id AND co.hr = rs.hr LEFT JOIN mimiciv_derived.sofa2_stage1_oxygen ox ON co.stay_id = ox.stay_id AND co.hr = ox.hr LEFT JOIN mimiciv_derived.sofa2_stage1_mech ec ON co.stay_id = ec.stay_id AND co.hr = ec.hr
),
cv_data AS (
    SELECT co.stay_id, co.hr, MAX(mech.is_ecmo) as has_ecmo, MAX(mech.is_va_ecmo) as has_va_ecmo, MAX(mech.is_vv_ecmo) as has_vv_ecmo, MAX(mech.is_ecmo_unknown_type) as has_ecmo_unknown, MAX(mech.is_other_mech) as has_other_mech, MIN(vs.mbp) as mbp_min, MAX(va.norepinephrine) as rate_nor, MAX(va.epinephrine) as rate_epi, MAX(va.dopamine) as rate_dop, MAX(va.dobutamine) as rate_dob, MAX(va.vasopressin) as rate_vas, MAX(va.phenylephrine) as rate_phe, MAX(va.milrinone) as rate_mil
    FROM co LEFT JOIN mimiciv_derived.sofa2_stage1_mech mech ON co.stay_id = mech.stay_id AND co.hr = mech.hr LEFT JOIN mimiciv_derived.vitalsign vs ON co.stay_id = vs.stay_id AND vs.charttime BETWEEN co.starttime AND co.endtime LEFT JOIN mimiciv_derived.vasoactive_agent va ON co.stay_id = va.stay_id AND va.starttime < co.endtime AND COALESCE(va.endtime, co.endtime) > co.starttime AND co.endtime >= va.starttime + INTERVAL '1 HOUR'
    GROUP BY co.stay_id, co.hr
),
cv_sofa AS (
    SELECT stay_id, hr, CASE
        WHEN COALESCE(has_other_mech, 0) = 1 THEN 4
        WHEN COALESCE(has_va_ecmo, 0) = 1 THEN 4
        WHEN COALESCE(has_ecmo, 0) = 1 AND COALESCE(has_vv_ecmo, 0) = 0 THEN 4
        WHEN COALESCE(has_ecmo_unknown, 0) = 1 THEN 4
        WHEN (COALESCE(rate_nor,0) + COALESCE(rate_epi,0)) > 0.4 THEN 4
        WHEN (COALESCE(rate_nor,0) + COALESCE(rate_epi,0)) > 0.2 AND other_drug = 1 THEN 4
        WHEN dop_score = 4 THEN 4
        WHEN (COALESCE(rate_nor,0) + COALESCE(rate_epi,0)) > 0.2 THEN 3
        WHEN (COALESCE(rate_nor,0) + COALESCE(rate_epi,0)) > 0 AND other_drug = 1 THEN 3
        WHEN dop_score = 3 THEN 3
        WHEN (COALESCE(rate_nor,0) + COALESCE(rate_epi,0)) > 0 THEN 2
        WHEN other_drug = 1 THEN 2
        WHEN dop_score = 2 THEN 2
        WHEN COALESCE(mbp_min, 70) < 40 THEN 4
        WHEN COALESCE(mbp_min, 70) < 50 THEN 3
        WHEN COALESCE(mbp_min, 70) < 60 THEN 2
        WHEN COALESCE(mbp_min, 70) < 70 THEN 1
        ELSE 0 END AS cardiovascular_score
    FROM (SELECT *, CASE WHEN rate_dop > 40 THEN 4 WHEN rate_dop > 20 THEN 3 WHEN rate_dop > 0 THEN 2 ELSE 0 END as dop_score, CASE WHEN (COALESCE(rate_dob,0) > 0 OR COALESCE(rate_vas,0) > 0 OR COALESCE(rate_phe,0) > 0 OR COALESCE(rate_mil,0) > 0 OR COALESCE(rate_dop,0) > 0) THEN 1 ELSE 0 END as other_drug FROM cv_data) x
),
coag_sofa AS (
    SELECT co.stay_id, co.hr, CASE WHEN cg.platelet_min <= 50 THEN 4 WHEN cg.platelet_min <= 80 THEN 3 WHEN cg.platelet_min <= 100 THEN 2 WHEN cg.platelet_min <= 150 THEN 1 ELSE 0 END AS coagulation_score
    FROM co LEFT JOIN mimiciv_derived.sofa2_stage1_coag cg ON co.stay_id = cg.stay_id AND co.hr = cg.hr
),
liver_sofa AS (
    SELECT co.stay_id, co.hr, CASE WHEN liv.bilirubin_max > 12.0 THEN 4 WHEN liv.bilirubin_max > 6.0 THEN 3 WHEN liv.bilirubin_max > 3.0 THEN 2 WHEN liv.bilirubin_max > 1.2 THEN 1 ELSE 0 END AS liver_score
    FROM co LEFT JOIN mimiciv_derived.sofa2_stage1_liver liv ON co.stay_id = liv.stay_id AND co.hr = liv.hr
),
-- 肾脏评分：已应用三窗口及 Virtual RRT 修复补丁
kidney_sofa AS (
    SELECT co.stay_id, co.hr, CASE
            WHEN r.on_rrt = 1 THEN 4
            WHEN l.creatinine > 1.2 AND (l.potassium >= 6.0 OR (l.ph <= 7.2 AND l.bicarbonate <= 12)) THEN 4
            WHEN COALESCE(u.rate_6h, u.rate_12h, u.rate_24h) < 0.3 AND (l.potassium >= 6.0 OR (l.ph <= 7.2 AND l.bicarbonate <= 12)) THEN 4
            WHEN l.creatinine > 3.5 THEN 3
            WHEN u.rate_24h < 0.3 THEN 3
            WHEN u.uo_sum_12h = 0 AND u.cnt_12h >= 12 THEN 3
            WHEN l.creatinine > 2.0 THEN 2
            WHEN u.rate_12h < 0.5 THEN 2
            WHEN l.creatinine > 1.2 THEN 1
            WHEN u.rate_6h < 0.5 THEN 1
            ELSE 0
        END AS kidney_score
    FROM co
    LEFT JOIN mimiciv_derived.sofa2_stage1_kidney_labs l ON co.stay_id = l.stay_id AND co.hr = l.hr
    LEFT JOIN mimiciv_derived.sofa2_stage1_rrt r ON co.stay_id = r.stay_id AND co.hr = r.hr
    LEFT JOIN mimiciv_derived.sofa2_stage1_urine u ON co.stay_id = u.stay_id AND co.hr = u.hr
)
SELECT co.stay_id, co.hadm_id, co.subject_id, co.hr, co.starttime, co.endtime,
    COALESCE(br.brain_score, 0) AS brain_score,
    COALESCE(rs.respiratory_score, 0) AS respiratory_score,
    COALESCE(cv.cardiovascular_score, 0) AS cardiovascular_score,
    COALESCE(lv.liver_score, 0) AS liver_score,
    COALESCE(kd.kidney_score, 0) AS kidney_score,
    COALESCE(cg.coagulation_score, 0) AS hemostasis_score
FROM co
LEFT JOIN brain_sofa br ON co.stay_id = br.stay_id AND co.hr = br.hr
LEFT JOIN resp_sofa rs ON co.stay_id = rs.stay_id AND co.hr = rs.hr
LEFT JOIN cv_sofa cv ON co.stay_id = cv.stay_id AND co.hr = cv.hr
LEFT JOIN liver_sofa lv ON co.stay_id = lv.stay_id AND co.hr = lv.hr
LEFT JOIN kidney_sofa kd ON co.stay_id = kd.stay_id AND co.hr = kd.hr
LEFT JOIN coag_sofa cg ON co.stay_id = cg.stay_id AND co.hr = cg.hr;

CREATE INDEX idx_sofa2_raw_calc ON mimiciv_derived.sofa2_hourly_raw(stay_id, hr);

-- =================================================================
-- 步骤 4: 24小时滑动窗口最差分
-- =================================================================
DROP TABLE IF EXISTS mimiciv_derived.sofa2_scores CASCADE;
CREATE TABLE mimiciv_derived.sofa2_scores AS
SELECT stay_id, hadm_id, subject_id, hr, starttime, endtime,
    MAX(brain_score) OVER w AS brain,
    MAX(respiratory_score) OVER w AS respiratory,
    MAX(cardiovascular_score) OVER w AS cardiovascular,
    MAX(liver_score) OVER w AS liver,
    MAX(kidney_score) OVER w AS kidney,
    MAX(hemostasis_score) OVER w AS hemostasis,
    (MAX(brain_score) OVER w + MAX(respiratory_score) OVER w + MAX(cardiovascular_score) OVER w + MAX(liver_score) OVER w + MAX(kidney_score) OVER w + MAX(hemostasis_score) OVER w) AS sofa2_total
FROM mimiciv_derived.sofa2_hourly_raw
WINDOW w AS (PARTITION BY stay_id ORDER BY hr ROWS BETWEEN 23 PRECEDING AND 0 FOLLOWING);

ALTER TABLE mimiciv_derived.sofa2_scores ADD COLUMN sofa2_score_id SERIAL PRIMARY KEY;
CREATE INDEX idx_sofa2_final_stay ON mimiciv_derived.sofa2_scores(stay_id);

-- =================================================================
-- 步骤 5: 过滤非负时间点
-- =================================================================
DROP TABLE IF EXISTS mimiciv_derived.sofa2_scores_hr_filtered CASCADE;
CREATE TABLE mimiciv_derived.sofa2_scores_hr_filtered AS
SELECT * FROM mimiciv_derived.sofa2_scores WHERE hr >= 0;
CREATE INDEX idx_sofa2_scores_hr_filtered_stay_hr ON mimiciv_derived.sofa2_scores_hr_filtered (stay_id, hr);

-- =================================================================
-- 步骤 6: 提取入ICU首日最差分 (对标 first_day_sofa)
-- =================================================================
DROP TABLE IF EXISTS mimiciv_derived.first_day_sofa2 CASCADE;
CREATE TABLE mimiciv_derived.first_day_sofa2 AS
SELECT stay_id, subject_id, hadm_id,
    MAX(brain) AS brain, MAX(respiratory) AS respiratory, MAX(cardiovascular) AS cardiovascular,
    MAX(liver) AS liver, MAX(kidney) AS kidney, MAX(hemostasis) AS hemostasis, MAX(sofa2_total) AS sofa2_total
FROM mimiciv_derived.sofa2_scores_hr_filtered
WHERE hr BETWEEN 0 AND 23 
GROUP BY stay_id, subject_id, hadm_id;

CREATE INDEX idx_first_day_sofa2_stay ON mimiciv_derived.first_day_sofa2(stay_id);
CREATE INDEX idx_first_day_sofa2_total ON mimiciv_derived.first_day_sofa2(sofa2_total);

-- =================================================================
-- 步骤 7: 基于 SOFA2 的 Sepsis-3 提取 (基于 delta SOFA2)
-- =================================================================
DROP TABLE IF EXISTS mimiciv_derived.sepsis3_sofa2_delta CASCADE;
CREATE TABLE mimiciv_derived.sepsis3_sofa2_delta AS
WITH soi AS (
    SELECT subject_id, stay_id, hadm_id, ab_id, antibiotic, antibiotic_time, culture_time, suspected_infection, suspected_infection_time, specimen, positive_culture
    FROM mimiciv_derived.suspicion_of_infection WHERE stay_id IS NOT NULL
),
sofa2 AS (
    SELECT stay_id, starttime, endtime, brain, respiratory, cardiovascular, liver, kidney, hemostasis, sofa2_total AS sofa2_score
    FROM mimiciv_derived.sofa2_scores_hr_filtered
),
baseline AS (
    SELECT soi.subject_id, soi.stay_id, soi.hadm_id, soi.suspected_infection_time, MIN(s2.sofa2_score) AS baseline_sofa2, COUNT(*) > 0 AS baseline_observed
    FROM soi LEFT JOIN sofa2 s2 ON soi.stay_id = s2.stay_id AND s2.endtime >= soi.suspected_infection_time - INTERVAL '48 hours' AND s2.endtime < soi.suspected_infection_time
    GROUP BY soi.subject_id, soi.stay_id, soi.hadm_id, soi.suspected_infection_time
),
window_scores AS (
    SELECT soi.*, s2.endtime AS sofa_time, s2.sofa2_score, s2.brain, s2.respiratory, s2.cardiovascular, s2.liver, s2.kidney, s2.hemostasis,
        COALESCE(baseline.baseline_sofa2, 0) AS baseline_sofa2, baseline.baseline_observed,
        s2.sofa2_score - COALESCE(baseline.baseline_sofa2, 0) AS delta_sofa2,
        (s2.sofa2_score - COALESCE(baseline.baseline_sofa2, 0) >= 2 AND soi.suspected_infection = 1) AS sepsis3_sofa2
    FROM soi INNER JOIN sofa2 s2 ON soi.stay_id = s2.stay_id AND s2.endtime >= soi.suspected_infection_time - INTERVAL '48 hours' AND s2.endtime <= soi.suspected_infection_time + INTERVAL '24 hours'
    LEFT JOIN baseline ON soi.stay_id = baseline.stay_id AND soi.subject_id = baseline.subject_id AND soi.hadm_id = baseline.hadm_id AND soi.suspected_infection_time = baseline.suspected_infection_time
),
first_hit AS (
    SELECT ws.*, ROW_NUMBER() OVER (PARTITION BY ws.stay_id ORDER BY ws.suspected_infection_time, ws.antibiotic_time, ws.culture_time, ws.sofa_time) AS rn
    FROM window_scores ws WHERE ws.sepsis3_sofa2
)
SELECT subject_id, stay_id, hadm_id, ab_id, antibiotic, antibiotic_time, culture_time, suspected_infection_time, sofa_time, sofa2_score, baseline_sofa2, baseline_observed, delta_sofa2, brain, respiratory, cardiovascular, liver, kidney, hemostasis, sepsis3_sofa2
FROM first_hit WHERE rn = 1;
