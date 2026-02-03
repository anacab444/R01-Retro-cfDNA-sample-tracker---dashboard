--R01 Retrospective Cohort Malignant Effusion - UC500 Dashboard
--Create BigQuery View that converts raw cfDNA tracking into
--Extracted? (yes/no)
--Passes 50ng? (yes/no)
--Sequenced? (yes/no)

--STEP 1 - Raw data cleanup (Base layer)
CREATE OR REPLACE VIEW `procurement-analytics-482818.R01_retro_me_cfdna_tracking.vw_uc500_dashboard` AS

WITH base AS (
  SELECT
   SAFE_CAST(sample_number AS INT64) AS sample_number,
   date_yyyymmdd,
   date_mmddyyyy,
   SAFE_CAST(days_apart AS INT64) AS days_apart,
   label,

   cfdna_extraction,
   SAFE_CAST(dna_conc_ng_ul AS FLOAT64) AS dna_conc_ng_ul,
   SAFE_CAST(extracted_dna_yield_ng AS FLOAT64) AS extracted_dna_yield_ng,
   SAFE_CAST(starting_volume_ml AS FLOAT64) AS starting_volume_ml,

   patient_id_aliquot,
   uc500_sequencing,
   reason_for_not_sequencing,
   action_item,
   uc500_pass_criteria
FROM `procurement-analytics-482818.R01_retro_me_cfdna_tracking.R01_ext_cfdna_samples`
),

--This step cleans and standardizes raw data so it can be used for calculations
--What the code is trying to do? - take the raw cfDNA data from googlesheets, clean up the data types (numbers should be numbers), and give this cleaned result a temporary name called "base" so we can build logic on top of it

--LINE 9: WITH base AS ( - defines a CTE (Common Table Expression)
--Base - is not saved in BigQuery
--It exists only for this query
--It's a named step, not a real table

--Why we use it?
--Instead of writing one giant unreadable query, we break it into steps:
--1. Base --> clean raw data
--2. Flags --> compute yes/no fields
--3. Decisions/status --> business logic

--Base = foundation layer
--Base is your "clean lab notebook copy" of the raw sheet

--LINE 10 - means choose these columns
--days_apart column has "X" values - Need SAFE_CAST to turn `X` Value into NULL so that query doesn't crash reading X value
--SAFE_CAST() - Valid numbers convert correctly, Invalid values quietly become NULL, the query keeps running
--Google sheets data mess and SAFE_CAST() - defensive programming

--WHY INT64 and FLOAT64?
--INT64 --> whole numbers. Ex: sample numbers, counts, days
--FLOAT64 --> decimal numbers. EX: DNA concentration, yield, volumes
--With SAFE_CAST - you're telling BigQuery - this column represents a numeric measurement, not text
--Cleaning up messy data enables the following: comparisons (>=50ng), sorting, Aggregration (AVG, SUM)

--LINE 19 - SAFE_CAST(extracted_dna_yield_ng AS FLOAT64) AS extracted_dna_yield_ng 
--In sheets, 57, 57.0 and 57 might all be text; SQL comparisons require numeric types

--Conclustion - the base CTE standardizes raw cfDNA tracking data by safely casting numeric fields and preparing a clean foundation for downstream sequencing logic

--STEP 2: Simple TRUE/FALSE flags (Flags layer)
--Derive boolean flags to represent extraction status, QC pass/fail and sequencing completion


flags AS (
  SELECT
   *,

--Was cfDNA extracted?
  CASE
  WHEN LOWER(TRIM(COALESCE(CAST(cfdna_extraction AS STRING), ''))) = 'yes' THEN TRUE
  WHEN extracted_dna_yield_ng IS NOT NULL THEN TRUE
  ELSE FALSE
END AS is_extracted,


--LINE 67 - , flags AS ( --> ,(Comma) - means "I'm defining another CTE after the previous one" 
--LINE 67 - Flags is the name of this CTE
--LINE 67 - AS ( begins the query that defines the CTE
--LINE 67 - create a temporary result named flags using the following SELECT
--LINE 67 - Named flags because you're creating flag columns (TRUE/FALSE)
--LINE 68 - SELECT - "pick these columns"
--LINE 69 - *,
--LINE 69 - * = means include all columns from the previous step (base) - so flags contains everything in base, plus new derived columns
--LINE 69 - , the comma after * - continuing the list of selected columns

--CASE 1 - was cfDNA extracted?
--Pattern for conditional statements 
--CASE
-- WHEN condition THEN VALUE
-- WHEN condition THEN VALUE
--ELSE value
--END AS new_column_name

--Meaning - "Create a new column. If condition #1 is true, return value #1. Else if condition #2 is true, return value #2. Otherwise return the ELSE value."

--LINE 73 - WHEN LOWER(cfdna_extraction) = 'yes' THEN TRUE
--LINE 73 - LOWER(...) converts value in cfDNA Extraction to YES to lower case 'yes'
--LINE 73 - Meaning - if the sheet says extracted = yes, then mark is_extracted = TRUE

--LINE 74 - WHEN extracted_dna_yield_ng IS NOT NULL THEN TRUE
--LINE 74 - IS NOT NULL checks that a value exists (not blank)
--LINE 74 - If there is a yield value, then extraction happened
--LINE 74 - Meaning "Even if the 'Yes" field is blank, if DNA yield exists, we assume it is extracted

--LINE 75 - ELSE FALSE - if neither condition is true - "Then it is not extracted"

--CASE 3: Does it pass the UC500 minimum input (50ng)
CASE
  WHEN extracted_dna_yield_ng >= 50 THEN TRUE
  ELSE FALSE
END AS passes_minimum_50ng,

--LINE 111 - 114 - IF DNA yield is equal or greater than 50ng, passes_minimum_50ng = TRUE, otherwise FALSE
--LINE 111 - 114 - IF extracted_dna_yield_ng is NULL, the condition is not TRUE, so it falls to ELSE FALSE



--CASE 4: Has the cfDNA sample already been seqeunced?
  CASE
      WHEN LOWER(COALESCE(uc500_sequencing, '')) = 'sequenced' THEN TRUE
      ELSE FALSE
    END AS is_sequenced,
 -- normalized reason text (so LIKE works even if NULL)
    LOWER(COALESCE(reason_for_not_sequencing, '')) AS reason_lc

FROM base
),
--LINE 129 - 132 - If UC500 sequencint status says 'sequenced' (any capitalization), then is_sequenced = TRUE

--LINE 134 - FROM base - means use the CTE as the input table
--LINE 135 - this closes the flags AS ( CTE definition

--STEP 3 - Decision Logic (Needs Sequencing?)

decisions AS (
  SELECT
   *,
  
   CASE
    WHEN is_sequenced THEN FALSE
    WHEN NOT is_extracted THEN FALSE
    WHEN NOT passes_minimum_50ng THEN FALSE
    WHEN reason_lc LIKE '%high molecular weight%' THEN FALSE
    WHEN reason_lc LIKE '%low dna yield%' THEN FALSE
    ELSE TRUE
  END AS needs_uc500
FROM flags

--LINE 136 - ,decisions AS (
--LINE 136 - This creates another CTE named decision
--LINE 136 - Comma means it comes after earlier CTEs (base, flags)
--LINE 136 - next step create a temporary table called decisions

--LINE 137 - SELECT - selecting columns for this step

--LINE 140 - CASE---END as needs_uc500 - this creates one new column = needs_uc500 = TRUE/FALSE

--LINE 141 - WHEN is_sequenced THEN FALSE - when it is sequenced then it does not need sequencing

--LINE 142 - WHEN NOT is_extracted THEN FALSE - when it is not extracted then don't submit it

--LINE 143 - WHEN NOT passes_50ng THEN FALSE - if the dna yield is not equal to or greater than 50 than it doesn't meet the requirement

--LINE 144 - WHEN reason_for_not_sequencing includes high molecular weight or low dna yield (any capitlization) - do not send for sequencing

--LINE 146 - ELSE TRUE - If none of the "blocked" conditions matched, then it does need UC500
--Line 146 - It passed all checks --> ready and pending

--LINE 147 - END AS needs_uc500 - finish the case and name the new column needs_uc500

--LINE 148 - FROM flags - use the previous step(flags) as input

--WHY MANY FALSE LINES? - because this is an eligibility filter. If any disqualifier is true --> FALSE. Otherwise --> TRUE

),
-- STEP 4 - Readable Dashboard Status
status AS (
  SELECT
    *,
    CASE
      WHEN is_sequenced THEN '✅Sequenced'
      WHEN needs_uc500 THEN '🔴Needs UC500 sequencing'
      WHEN is_extracted AND NOT passes_minimum_50ng THEN '🟠Extracted but <50ng'
      WHEN NOT is_extracted THEN '⚪Not Extracted'
      ELSE '🟣Review'
    END AS dashboard_status
  FROM decisions
)
--LINE 183 - WHEN is_sequenced THEN 'Sequenced' - if is_sequenced is TRUE --> label 'Sequenced'
--LINE 183 - Critical: this needs to be the first condition because even if it has low yield or notes, you still want it to show as sequenceds

--LINE 184 - WHEN needs_uc500 THEN 'Needs UC500 Sequencing' - If it needs_uc500 is TRUE --> label it 'Needs UC500 Sequencing'
--LINE 185 - WHEN is_extracted AND NOT passes_50ng THEN 'Extracted but '<50ng' - two conditions 1) When is_extracted is TRUE AND 2) NOT passes_50ng --> Then Label "Extracted but < 50ng"
--LINE 185 - Meaning - extraction happened but sample failed QC threshold

--LINE 186 - WHEN NOT is_extracted THEN 'Not Extracted' - when it is not extracted status is TRUE --> label it 'Not Extracted'

--LINE 187 - ELSE 'Review' - If none of the conditions were met, label it "Review"
--LINE 187 - Review - This row is weird or incomplete and needs human attention. Review catches missing values, unexpected spelling, situations that don't fit rules

--LINE 188 - END AD dashboard_status - status depends on Is_Sequenced, Needs_uc500, Is_extracted, and Passes_50ng

--Conclusion: The most important in conditional cases is ORDER controls the label.
--Conclusion: - SQL stops at the first match. For example if a sample is sequenced, it will always be labeled "Sequenced" even if it has <50ng, Note says DNA Contamination or Action Item says "isolate"

SELECT 
--Keep raw fields
sample_number,
date_yyyymmdd,
date_mmddyyyy,
days_apart,
label, 
patient_id_aliquot,
cfdna_extraction,
dna_conc_ng_ul,
extracted_dna_yield_ng,
starting_volume_ml,
uc500_sequencing,
reason_for_not_sequencing,
action_item,
uc500_pass_criteria,

--Derived Dashboard Fields 
is_extracted,
passes_minimum_50ng,
is_sequenced,
needs_uc500,
dashboard_status
FROM status;






