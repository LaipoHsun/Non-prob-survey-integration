# data/code — how to use

Three weighting methods: raking, multilevel calibration, PAPP-BART. **Sample reading, recoding, category collapsing and the population setup are shared**; only the weighting algorithm differs.

中文版：[`README.md`](README.md)

| Script | Method | Output | Section |
|---|---|---|---|
| `raking_NTUWS.R` | anesrake raking: matches first-order margins only | `data/output/raking/<sample>/` | §7 |
| `MultiCalibration_NTUWS.R` | multilevel calibration (Ben-Michael et al. 2024): margins exact, higher-order interactions as close as possible | `data/output/multical/<sample>/<tag>/` | §8 |
| `PAPP_BART_NTUWS.R` | PAPP quasi-randomization (Rafei et al. 2020): two BART models for inclusion probabilities | `data/output/papp_bart/<sample>/<tag>/` | §9 |
| `Calculate_stat_population_from_TEDS/` | Builds the population (joint tables and marginal targets) from TEDS | `data/output/portion_of_TEDS/` | [its README](Calculate_stat_population_from_TEDS/README.md) |

**§10 "Reading the output" explains every metric** — deff, effective sample size, TVD, weights at the floor, population coverage, the λ trade-off curve, AUC. Read that section to judge whether a set of weights is any good.

---

## 1. Quick start

```bash
Rscript -e 'install.packages(c("readxl","dplyr","tidyr","ggplot2","scales","haven","anesrake","BART","osqp","Matrix","remotes"))'
Rscript -e 'remotes::install_github("ebenmichael/multical")'

Rscript data/code/raking_NTUWS.R           member
Rscript data/code/MultiCalibration_NTUWS.R member order=1
Rscript data/code/MultiCalibration_NTUWS.R member order=2
Rscript data/code/PAPP_BART_NTUWS.R        member
```

Replace `member` with a wave name (e.g. `LS_23NY`) to run a single wave. In `member` mode the output folder is always called `member_pooled`.

All three scripts must use the **same shared settings** (§2–§6) for their results to be comparable.

### Current defaults

| Item | Value |
|---|---|
| Population | TEDS 2025 joint table, weighted by W (§4) |
| Adjustment variables | sex, age, edu, arear, party_kmt, party_dpp, party_tpp |
| Holdout variable | ethnicity (not adjusted, reported only — used to check side effects) |
| Category collapsing | age `A2` (20+), arear six regions, edu `B` (auto fallback), thermometers 3 categories each |
| raking | cap = 5, pctlim = 0.05 |
| multical | lowlim = 0.01, no upper limit, λ chosen automatically |
| PAPP-BART | no trimming and IQR trimming (c = 5), fixed seed |

---

## 2. Choosing the sample

The first command-line argument selects the sample and overrides `SAMPLE_TYPE` / `WAVE` in the CONFIG block.

### 2.1 `wave` mode — one Excel file, one sheet per wave

```r
SAMPLE_TYPE <- "wave"
SAMPLE_FILE <- "data/NTUWS/raw_data/lottery_repeated_raw_by_wave.xlsx"
WAVE        <- "LS_23NY"     # which sheet
BASE_SHEET  <- "Welcome"     # fill gaps from this sheet; NA to disable
WAVE_YEAR   <- NA            # year used for age; NA = derive from the wave name
```

Assumptions: each sheet is one survey, **row 1 holds the full question text and data starts at row 2**, and there is a `memberId` column. Sex / birth year / city missing in a wave are filled from `BASE_SHEET`, but **the wave's own answers win**.

### 2.2 `member` mode — one row per person

```r
MEMBER <- list(
  demo_file   = "data/Input/NTUWS_pooled/ntuws_member_demographics.csv",
  therm_file  = "data/Input/NTUWS_pooled/ntuws_party_thermometer_resolved.xlsx",
  therm_sheet = "總表",
  therm_stat  = "mean",      # use the _mean or _median thermometer columns
  edu_col     = "education",
  ref_year    = 2024,        # reference year for age
  keep_splits = TRUE
)
```

### 2.3 Using your own sample

If neither mode fits, edit `build_member_sample()` so it returns a data.frame with these columns; everything downstream is shared:

```
memberId, sex, birth, ageband, edu, ethnicity, city, zip, party_kmt, party_dpp, party_tpp
```

---

## 3. Column detection

In `wave` mode the scripts do not rely on fixed column names; they match both **column names** and **the question text in row 1** (keywords are Chinese: 性別 for sex, 學歷/教育程度 for education, and so on). Thermometer columns are additionally validated against the data itself: they must be a genuine 0–10 scale.

If detection fails, pin the column explicitly:

```r
COLUMN_OVERRIDE <- c(edu = "S3 ")   # must match the column name exactly, trailing spaces included
```

---

## 4. Population

```r
TARGET_SOURCE <- "joint"      # raking and multical; the PAPP equivalent is REF$target = "weighted"
JOINT <- list(file = "data/output/portion_of_TEDS/2025/joint/joint_full_raw.csv",
              count_col = "n_wt")
```

- **`TARGET_SOURCE = "joint"` (default)**: population targets come from the joint table aggregated by `count_col`. `n_wt` = weighted by the TEDS survey weight, `n` = unweighted.
- In joint mode `TARGET_FILES` only defines **which categories exist**, not their proportions. Only `"files"` mode uses its proportions.
- The joint table keeps only cells where every adjustment variable is present and matches a category, so all three methods use **the same set of TEDS respondents**.
- **When you change the joint table's year, change `TARGET_FILES` to the same year.** The 2024 and 2025 region labels differ and only 2025 has an 18–19 age group; a mismatch stops the alignment check.

Available joint tables (`data/output/portion_of_TEDS/<source>/joint/joint_full_raw.csv`): `2024_ind`, `2024_pan`, `2025`, `pooled`. Switch with `joint=pooled`.

---

## 5. Adjustment variables

```r
RAKE_VARS <- c("sex", "age", "edu", "arear", "party_kmt", "party_dpp", "party_tpp")
```

- A variable listed in `TARGET_FILES` but not in `RAKE_VARS` (e.g. ethnicity) is still reported, as a **holdout variable** for checking side effects.
- **A missing value on any adjustment variable drops the whole respondent** (complete-case analysis). In `member` mode this currently drops 39%, mostly due to education and the TPP thermometer.

---

## 6. Category collapsing and OPTS

Sample and population categories must match exactly. `COLLAPSE` is written once and **applied to both sides simultaneously**.

```r
COLLAPSE <- list(age = "A2", arear = "A", edu = "B", ethnicity = "4class",
                 party_kmt = "C", party_dpp = "C", party_tpp = "C")
```

| Variable | Code | Grouping |
|---|---|---|
| `age` | `A` / **`A2` (default)** / `B` / `C` | includes 18-19 / 18-19 set to NA on both sides / 20-39, 40-59, 60+ / 20-49, 50+ |
| `arear` | `A` / `B` / `C` | six regions / north, central, south, east / north, central, south |
| `edu` | `A` / `B` / `C` | 5 categories / ≤ high school, junior college, university+ / ≤ high school, junior college+ |
| `ethnicity` | `raw` / `4class` | original / Hakka, Minnan, mainland provinces, other |
| `party_*` | `A` / `C` / `E` | 0…10 / 0-4, 5, 6-10 / five bands |

**Automatic education fallback**: if the sample has a merged "junior college or university" option, `OPTS$edu_auto_fallback` walks A → B → C until the categories line up.

### Command-line options shared by all three scripts

| Key | Meaning | Example |
|---|---|---|
| `joint` | Switch joint table; a bare name reads `portion_of_TEDS/<name>/joint/joint_full_raw.csv` | `joint=pooled` |
| `count_col` | `n_wt` (weighted) or `n` (unweighted) | `count_col=n` |
| `target` | `joint` or `files` | `target=files` |
| `drop` | Remove variables from `RAKE_VARS` | `drop=arear` |
| `collapse` | Override a collapsing code | `collapse=arear:B` |
| `out_root` | Output root (default `data/output`), for experiments | `out_root=data/output/experiments/test` |

---

## 7. raking_NTUWS.R

Iterative proportional fitting (anesrake): each adjustment variable's weighted distribution is pulled to the population in turn until convergence. **Only first-order margins are matched; combinations of variables are untouched.** Weights are capped.

```r
ANESRAKE <- list(cap = 5, choosemethod = "total", type = "pctlim",
                 pctlim = 0.05, nlim = 5, maxit = 1000, force1 = TRUE)
```

| Parameter | Meaning |
|---|---|
| `cap` | Upper bound on a single weight (multiples of the mean). Low → stable weights but a worse fit; high → better fit but a few respondents dominate |
| `pctlim` | Variables whose total discrepancy is below this are skipped; `0` rakes everything |
| `force1` | Normalise weights to mean 1 |

### Output (`data/output/raking/<sample>/`, 17 files)

| File | Contents |
|---|---|
| `weights_<sample>.csv` | **The weights**: `memberId`, `caseid`, `weight` (mean 1, blank = excluded), `excluded_reason` |
| `dist_<sample>.csv` | Per variable and category: `n_sample`, `pct_sample` (before), `pct_target` (population), `pct_raked` (after), `in_raking` |
| `diagnostics_<sample>.txt` | Run log, variables actually used, weight summary, deff, largest gap to the population, number of respondents at the cap |
| `dist_<sample>_<var>.png` | Bar chart: population / before / after |
| `collapse_<sample>_<var>.png` | Categories before and after collapsing |

> A **partial convergence** warning only means the iterations stopped improving; it is not a failure. What matters is the largest gap to the population in the diagnostics file.

---

## 8. MultiCalibration_NTUWS.R

Ben-Michael, Feller & Hartman (2024), equation (9):

```
min  Σ_k≥2 (1/λ) ‖weighted count of k-th order interaction − population count‖²  +  Σ weight variance
s.t. first-order margins matched exactly;  lowlim ≤ weight ≤ uplim
```

Larger λ approaches raking, smaller λ approaches post-stratification. With `order = 1` there are no interaction terms, which makes it "raking under a squared distance". Weights only; no DRP (that needs an outcome Y).

| Parameter | Meaning |
|---|---|
| `order` | How many orders of interaction to balance. The joint table comes from a few thousand TEDS respondents, so higher orders increasingly fit sampling noise; 2 is recommended |
| `balance_threshold` | λ selection: relative to the order-1 solution, take the largest effective sample size among λ reaching 95% of the best improvement |
| `lowlim` | Lower bound on weights (on the mean-1 scale). **0.01 forbids zero weights but leaves people pinned at 0.01** (§10) |
| `uplim` | Upper bound. Margins are a hard constraint, so a low bound can make the problem infeasible |

### Tags and folders

**One run per subfolder**, named after the method tag; only settings that differ from the defaults are appended:

| Setting | Tag (= subfolder name) |
|---|---|
| Defaults (2025 joint, `n_wt`, anchored, lowlim 0.01, no upper limit) | `mlcal_o1`, `mlcal_o2` |
| `joint=pooled` / `count_col=n` / `target=files` | `mlcal_o2_jpooled` / `mlcal_o2_Njoint` / `mlcal_o2_tfiles` |
| `anchor=FALSE` / `lowlim=0` / `uplim=5` / explicit λ | `_noanchor` / `_low0` / `_cap5` / `_lam0.01` |

### Output (`data/output/multical/<sample>/<tag>/`, 23–24 files)

Beyond the five file types in §7:

| File | Contents |
|---|---|
| `analysis_*.csv` | Each respondent's collapsed categories plus `complete` (**person-level data, not uploaded**) |
| `target_*.csv` | **The joint target**: one row per variable combination with `n_teds`, `n_teds_wt`, `N_target` |
| `coverage_*.csv` | **Support check**: `pop_uncovered` (share of the population in cells with no sample, which weights cannot reach) and `sample_no_target` |
| `lambda_path_*.csv` | **λ path**: per λ, `n_eff`, weight range, imbalance by order, `pct_improvement`, `selected` |
| `frontier_*.png` | λ trade-off curve (paper Fig. 2): effective sample size vs interaction imbalance, red dot = chosen λ. Only for order ≥ 2 |
| `balance_*.csv` / `.png` | Per cell, orders 1–3: target, sample, order-1 solution and chosen solution (paper Fig. 3) |

---

## 9. PAPP_BART_NTUWS.R

Rafei, Flannagan & Elliott (2020), equations (2.5) and (2.7). NTUWS is treated as a random sample with unknown inclusion probabilities, estimated with TEDS as the reference sample:

```
π_B(x) ∝ π_R(x) × e(x) / (1 − e(x))     weight = (1/π̂_R) × (1 − ê)/ê, normalised to mean 1
```

| | Model | Data |
|---|---|---|
| Model A | `BART::wbart` (continuous) | TEDS: X → logit(π_R), with π_R ∝ 1/W |
| Model B | `BART::pbart` (probit) | NTUWS (Z = 1) stacked with TEDS (Z = 0), **unweighted** |

Margins are **not forced to match**; weights are always positive, so none are zero. Variance estimation (paper §2.4) is not implemented because it needs an outcome Y.

| Parameter | Meaning |
|---|---|
| `REF$file` | Reference sample. Each joint-table cell is expanded into n rows with W = `n_wt / n` (TEDS's W is constant within a cell, so this is each person's actual weight) |
| `ndpost` / `nskip` | 1,100 MCMC draws, 100 burn-in (paper §5); weights use the posterior mean |
| `seed` | BART is MCMC, so **a fixed seed is required for reproducibility** (same seed ⇒ identical weights) |
| `TRIM$methods` | `iqr`: K = median + c × IQR (eq. 2.9); `entropy`: K = √(c × Σw²/n) (eq. 2.8); `none`. **BART runs once; each trimming variant gets its own subfolder** |

### Output (`data/output/papp_bart/<sample>/<tag>/`, 20 files)

Tags are `papp_bart_notrim`, `papp_bart_trimiqr5`, `papp_bart_trimentropy6`. Beyond the five file types in §7:

| File | Contents |
|---|---|
| `analysis_*.csv` | As for multical (**person-level data, not uploaded**) |
| `overlap_*.png` | Distribution of logit(ê) in NTUWS and TEDS (paper Fig. 5). **Where the curves do not overlap there is no common support**, and those respondents get extreme weights |
| `weights_*.png` | Weight histogram (log scale); the red dashed line is the trimming cut-point K |

The diagnostics file also reports the reference sample size and W range, the support check, **model A's pseudo-R²**, **model B's AUC** with ê quantiles, and how many weights were trimmed.

---

## 10. Reading the output

How to judge a set of weights. All of these appear in `diagnostics_*.txt`, `dist_*.csv`, `coverage_*.csv` and `lambda_path_*.csv`.

### 10.1 The weights themselves

| Metric | Where | Meaning |
|---|---|---|
| **Design effect (deff)** | `diagnostics` | `1 + (sd(w)/mean(w))²`. How dispersed the weights are; **larger means less stable estimates** |
| **Effective sample size n_eff** | `diagnostics` | `n / deff`. How many respondents the weighted sample is "worth". deff = 3 means 8,800 respondents behave like about 2,900 |
| **Maximum weight** | `diagnostics` | How much one respondent can dominate. Untrimmed PAPP can exceed 30 |
| **Share at the cap** | raking `diagnostics` | Respondents stuck at the upper bound. A high share means raking is constrained and may not reach the population |
| **Share at the floor** | multical `diagnostics`, `weights` | Specific to multical. With `lowlim = 0.01`, respondents pinned at 0.01 are **effectively excluded**; currently 20–30%, which deserves attention |

### 10.2 Distance from the population

| Metric | Where | Meaning |
|---|---|---|
| **`pct_target` vs `pct_raked`** | `dist_*.csv` | Population vs weighted share. **Raking and multical should be near 0 on adjustment variables; PAPP does not force this, and the gap is itself a diagnostic** |
| **TVD** | compute from `dist_*.csv` | `½ Σ|weighted − population|`, in percentage points. One number for how far a whole variable is off |
| **Holdout variables** | rows with `in_raking = FALSE` | Whether a variable that was *not* adjusted improved anyway. **This is the fairer check**, since adjusted variables match by construction |

### 10.3 Population coverage (what weights cannot fix)

| Metric | Where | Meaning |
|---|---|---|
| **`pop_uncovered`** | multical `coverage_*.csv` | Share of the population falling in cells with **no sample at all**. Weights can only be spread over cells that contain respondents, so this part is beyond any method |
| **`sample_no_target`** | same | Sample falling in cells the population does not have; interaction constraints push these weights down |
| **Common support** | PAPP `diagnostics`, `overlap_*.png` | NTUWS cells absent from TEDS rely on BART extrapolation; TEDS cells absent from NTUWS are population the weights cannot reach |

Note that the finer the cross-classification, the higher the uncovered share. A **simple random sample** of the same size would also miss some fine cells, so separate genuine non-coverage from ordinary sparsity.

### 10.4 Interaction balance (multical)

| Metric | Where | Meaning |
|---|---|---|
| **TVD by interaction order** | `diagnostics`, `balance_*.csv` | Order 1 = margins, 2 = pairs, 3 = triples. **Methods that only match margins are clearly worse at orders 2 and 3** |
| **λ trade-off curve** | `lambda_path_*.csv`, `frontier_*.png` | Effective sample size against interaction imbalance. **Bottom left = interactions match well but little statistical power**; top right the reverse |
| **`pct_improvement`** | `lambda_path_*.csv` | Balance improvement relative to the order-1 solution |

### 10.5 Model diagnostics (PAPP)

| Metric | Where | Meaning |
|---|---|---|
| **Model A pseudo-R²** | `diagnostics` | How well X predicts the TEDS inclusion probability. Near 1 means W is essentially a function of X |
| **Model B AUC** | `diagnostics` | How well X separates NTUWS from TEDS respondents. **Higher means the two samples differ more**, which also means more extreme weights |
| **ê quantiles** | `diagnostics` | Propensity distributions of both samples. If many NTUWS values sit above TEDS's 99th percentile, common support is lacking |
| **Trimming** | `diagnostics` | Cut-point K, and how many weights were trimmed |

### 10.6 Putting it together

There is no single best method; the trade-offs are:

- **raking** — most stable weights, nobody excluded, but combinations of variables are untouched.
- **multilevel calibration (order = 2)** — best interaction balance and exact margins, but a lower effective sample size and roughly a quarter of respondents pinned at the weight floor.
- **PAPP-BART (no trimming)** — interaction balance close to multical and nobody excluded, but a few very large weights.
- **PAPP-BART (IQR trimming)** — most concentrated weights and the largest effective sample size, but it trims exactly those groups the sample lacks, so margins drift back towards the sample.

**A final verdict needs an outcome Y**: only with a shared question that was *not* used for adjustment can the methods' bias be compared.

---

## 11. Common errors

| Message | Cause and fix |
|---|---|
| `母體與樣本的類別對不齊` (categories do not line up) | The message names the variable and category: a typo in `COLLAPSE`, a category the wave never asked (e.g. 18–19 → use age `A2`), or `TARGET_FILES` and the joint table being from different years |
| `聯合表沒有任何一格對得上` | `TARGET_FILES` and the joint table are from different years |
| `教育程度有未對應的選項（設為 NA）` | Wording missing from `EDU_MAP`; add it if many respondents are affected (`ETH_MAP` for ethnicity) |
| `完整個案太少` | Too many adjustment variables, or one with heavy missingness |
| `缺少套件 multical` / `BART` | See §1 |
| `multical 求解失敗` | Usually `uplim` too low, making the margin constraints infeasible; raise it or set `Inf` |
| `trimming 的截斷點太低` | Use `entropy` or raise `c_iqr` |
