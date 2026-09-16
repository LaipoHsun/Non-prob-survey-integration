# Integrating method to deal with selection bias problem

Cleaning and weighting of the NTU web lottery survey (NTUWS), a multi-wave online panel. NTUWS is a **non-probability sample**. The goal is to combine it with probability samples (TEDS, ABS), so the sample is first cleaned into a one-row-per-person file, then reweighted towards the population using a probability sample.

中文版：[`README.md`](README.md)

The repo holds two pipelines:

| | What it does | Where |
|---|---|---|
| **A. Cleaning** | Collapses 17 waves of raw questionnaires into one row per respondent | `data/NTUWS/Code/` |
| **B. Weighting** | Uses TEDS as the population and produces a weight for each respondent. **Three methods** | `data/code/` |

The two are independent: A's output is one possible input to B, but B can also read the raw per-wave file directly.

---

## Three weighting methods

| Script | Method | Reference | Character |
|---|---|---|---|
| `raking_NTUWS.R` | **Raking** (anesrake) | Standard practice | Matches first-order margins only; stable weights |
| `MultiCalibration_NTUWS.R` | **Multilevel calibration** | Ben-Michael, Feller & Hartman (2024), *Political Analysis* 32(1) | Margins matched exactly, second- and higher-order interactions matched as closely as possible |
| `PAPP_BART_NTUWS.R` | **PAPP-BART** | Rafei, Flannagan & Elliott (2020), *JSSAM* 8(1) | Two BART models estimate inclusion probabilities; margins are not forced to match |

All three share the same sample reading, recoding, category collapsing and population settings, so switching methods means switching scripts — the data stays untouched.

### The key input: a joint table, not margins

Classical raking only needs the marginal distribution of each variable. Multilevel calibration has to balance **combinations of variables**, and PAPP-BART needs an **individual-level reference sample**. Both need finer population information than margins.

This repo therefore ships the **TEDS joint distribution table** (`joint_full_raw.csv`): one row per combination of variables, with the number of respondents `n` and the sum of TEDS survey weights `n_wt`. All three methods can take this table as the population, which is what makes the comparison meaningful.

```
sex, age, edu, arear, ethnicity, party_kmt, party_dpp, party_tpp, n, n_wt, ...
female, 30-39, college+, central, Minnan, 05, 05, 05, 10, 11.30, ...
```

---

## Quick start

### 1. Install packages

```bash
Rscript -e 'install.packages(c("readxl","dplyr","tidyr","stringr","purrr","writexl","ggplot2","haven","scales","anesrake","BART","osqp","Matrix","remotes"))'
Rscript -e 'remotes::install_github("ebenmichael/multical")'
```

`multical` is only on GitHub, so it must be installed with `remotes`. Plots use the `Heiti TC` font (bundled with macOS); on other systems change `base_family` inside the scripts.

### 2. The population is already here

The joint tables are committed, so **you do not need the raw TEDS files to run the methods**:

```
data/output/portion_of_TEDS/
├── 2024_ind/joint/joint_full_raw.csv    TEDS 2024 face-to-face, independent sample (n = 1,113)
├── 2024_pan/joint/joint_full_raw.csv    TEDS 2024 face-to-face, panel sample (n = 1,838)
├── 2025/joint/joint_full_raw.csv        TEDS 2025 (n = 2,649)  ← default
└── pooled/joint/joint_full_raw.csv      the three pooled (n = 5,600)
```

Regenerate them only when the TEDS data changes (needs the `.sav` files under `data/TEDS/`):

```bash
Rscript data/code/Calculate_stat_population_from_TEDS/joint_distribution_TEDS.R   # per year
Rscript data/code/Calculate_stat_population_from_TEDS/pool_joint_TEDS.R           # pooled
```

### 3. Run the three methods

```bash
Rscript data/code/raking_NTUWS.R           member          # raking
Rscript data/code/MultiCalibration_NTUWS.R member order=1  # margins only
Rscript data/code/MultiCalibration_NTUWS.R member order=2  # plus second-order interactions
Rscript data/code/PAPP_BART_NTUWS.R        member          # writes both notrim and trimiqr5
```

Replace `member` with a wave name (e.g. `LS_23NY`) to run a single wave. Multilevel calibration solves one `order` per call, so run it twice if you want both.

### 4. Collect the weights

```
data/output/
├── raking/<sample>/                         weights_<sample>.csv
├── multical/<sample>/mlcal_o1/              weights_mlcal_o1_<sample>.csv
│                    mlcal_o2/
└── papp_bart/<sample>/papp_bart_notrim/     weights_papp_bart_notrim_<sample>.csv
                       papp_bart_trimiqr5/
```

Every weight file has the same four columns — `memberId, caseid, weight, excluded_reason` — with weights averaging 1. Join them back to your analysis file by id.

**How to tell whether the weights are any good** (deff, effective sample size, TVD, population coverage, the λ trade-off curve, AUC): see the "Reading the output" section of [`data/code/README.md`](data/code/README.md).

---

## What is and is not in this repo

**Included**: the scripts for all three methods, the TEDS joint tables, and the weighting results (weights, distribution tables, diagnostics, a representative set of figures).

**Not included** (all in `.gitignore`):
These files carry personal identifiers and confidential answers from respondents. If you need them, please contact the author.

| Missing | Consequence | Original location |
|---|---|---|
| Raw NTUWS questionnaires (xlsx) | Pipeline A cannot run; B's `wave` mode cannot run | `data/NTUWS/raw_data/` |
| NTUWS person-level pooled file | B's `member` mode cannot run | `data/Input/NTUWS_pooled/` (personal data) |
| Raw TEDS `.sav` | Joint tables and target files cannot be regenerated | `data/TEDS/` |

So **the examples here cannot be reproduced by others**, but you can run the methods on your own sample: prepare a one-row-per-person file following the column format in [`data/Input/README.md`](data/Input/README.md), and use the joint tables in this repo as the population.

> The script that compares the three methods (`compare_raking_multical.R`) is still being revised and has not been uploaded. For now, compare the metrics in each method's `diagnostics_*.txt` and `dist_*.csv` by hand.

---

## Layout

```
Task_1_disolve_population/
├── data/
│   ├── NTUWS/
│   │   ├── raw_data/     raw xlsx (not uploaded)
│   │   ├── Code/         pipeline A: cleaning scripts
│   │   └── output/       pipeline A output (not uploaded)
│   ├── code/             pipeline B: the three weighting methods
│   │   ├── raking_NTUWS.R
│   │   ├── MultiCalibration_NTUWS.R
│   │   ├── PAPP_BART_NTUWS.R
│   │   └── Calculate_stat_population_from_TEDS/   population from TEDS
│   ├── Input/
│   │   ├── population_targets/   marginal target files
│   │   └── NTUWS_pooled/         person-level sample (not uploaded)
│   ├── output/
│   │   ├── portion_of_TEDS/      TEDS descriptives and joint tables
│   │   ├── raking/               weights and diagnostics per method
│   │   ├── multical/
│   │   └── papp_bart/
│   └── TEDS/  ABS/       raw probability-sample data (not uploaded)
```

---

## Conventions

1. **Raw data is read-only.** Scripts read the raw files and write only to `output/`.
2. **`output/` is disposable** — delete it, rerun, and it comes back.
3. **No `setwd()`.** Each script walks up to find the project root (the directory containing `data/code/`), so it runs from anywhere.
4. **CSV is always UTF-8.** Chinese text is dropped under `Rscript`'s default C locale, so every script sets a UTF-8 locale at the top — do not remove those lines.
5. **Recoding and category collapsing live in the scripts**, never in the data files. The same collapsing is applied to the population and the sample at the same time.

---

## More detail

- [`data/code/README.md`](data/code/README.md) — **how to run the three methods, what each parameter means, how to read every output file**
- [`data/code/Calculate_stat_population_from_TEDS/README.md`](data/code/Calculate_stat_population_from_TEDS/README.md) — how the joint tables and target files are produced
- [`data/Input/README.md`](data/Input/README.md) — input data format
- [`data/output/README.md`](data/output/README.md) — what each output folder holds
- Pipeline A: the per-phase READMEs under `data/NTUWS/Code/`
