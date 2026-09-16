# data/code 使用說明

三種加權方法：raking、multilevel calibration、PAPP-BART。**樣本讀取、重新編碼、類別合併、母體設定完全共用**，差別只在算權數的方法。

English version: [`README.en.md`](README.en.md)

| 程式 | 方法 | 輸出 | 本文件 |
|---|---|---|---|
| `raking_NTUWS.R` | anesrake raking：只對齊一階邊際 | `data/output/raking/<樣本>/` | §7 |
| `MultiCalibration_NTUWS.R` | multilevel calibration（Ben-Michael 等 2024）：邊際完全對齊，二階以上交互盡量對齊 | `data/output/multical/<樣本>/<方法標籤>/` | §8 |
| `PAPP_BART_NTUWS.R` | PAPP quasi-randomization（Rafei 等 2020）：兩個 BART 模型估入樣機率 | `data/output/papp_bart/<樣本>/<方法標籤>/` | §9 |
| `Calculate_stat_population_from_TEDS/` | 從 TEDS 算母體（聯合表與邊際檔） | `data/output/portion_of_TEDS/` | [該資料夾的 README](Calculate_stat_population_from_TEDS/README.md) |

**§10「判讀輸出」逐一解釋每個指標的意思**——deff、有效樣本數、TVD、權數在下限、母體覆蓋、λ 取捨曲線、AUC。拿到權數後要判斷好不好，看那一節。

---

## 目錄

- [1. 快速開始](#1-快速開始) ・ [2. 指定樣本](#2-指定樣本) ・ [3. 欄位偵測](#3-欄位偵測) ・ [4. 母體](#4-母體) ・ [5. 調整變數](#5-調整變數) ・ [6. 類別合併與 OPTS](#6-類別合併與-opts)
- [7. raking_NTUWS.R](#7-raking_ntuwsr) ・ [8. MultiCalibration_NTUWS.R](#8-multicalibration_ntuwsr) ・ [9. PAPP_BART_NTUWS.R](#9-papp_bart_ntuwsr)
- [10. 判讀輸出](#10-判讀輸出) ← **指標的意思都在這**

---

## 1. 快速開始

```bash
Rscript -e 'install.packages(c("readxl","dplyr","tidyr","ggplot2","scales","haven","anesrake","BART","osqp","Matrix","remotes"))'
Rscript -e 'remotes::install_github("ebenmichael/multical")'

Rscript data/code/raking_NTUWS.R           member
Rscript data/code/MultiCalibration_NTUWS.R member order=1
Rscript data/code/MultiCalibration_NTUWS.R member order=2
Rscript data/code/PAPP_BART_NTUWS.R        member
```

`member` 換成波次名（例如 `LS_23NY`）就是跑單一波次；輸出資料夾名，`member` 模式固定叫 `member_pooled`。

三支程式要用**同一份共用設定**（§2–§6），結果才可以互相對照。

### 目前的預設設定

| 項目 | 值 |
|---|---|
| 母體 | TEDS 2025 聯合表，W 加權（§4） |
| 調整變數 | sex、age、edu、arear、party_kmt、party_dpp、party_tpp |
| 保留變數 | ethnicity（不調整，只出報表，用來檢查加權的副作用） |
| 類別合併 | age `A2`（20 歲以上）、arear 六區、edu `B`（會自動退回）、溫度計各 3 類 |
| raking | cap = 5、pctlim = 0.05 |
| multical | lowlim = 0.01、無上限、λ 自動選 |
| PAPP-BART | 不 trim 與 IQR trim（c = 5），seed 固定 |

---

## 2. 指定樣本

命令列第一個參數決定樣本，會覆寫 CONFIG 的 `SAMPLE_TYPE` 與 `WAVE`。

### 2.1 `wave` 模式 —— 一個 Excel、一頁一波

```r
SAMPLE_TYPE <- "wave"
SAMPLE_FILE <- "data/NTUWS/raw_data/lottery_repeated_raw_by_wave.xlsx"
WAVE        <- "LS_23NY"     # 要跑哪一個分頁
BASE_SHEET  <- "Welcome"     # 這一波沒問到的欄位用這個分頁補；不補設 NA
WAVE_YEAR   <- NA            # 算年齡的年份；NA = 從 WAVE 名稱推導（LS_2405 → 2024）
```

假設：每個分頁是一次調查、**第 1 列是題目全文、第 2 列開始是資料**、有 `memberId` 欄。該波沒問到的性別／出生年／縣市會從 `BASE_SHEET` 補，**該波自己問到的優先**。

### 2.2 `member` 模式 —— 一列一個人

```r
MEMBER <- list(
  demo_file   = "data/Input/NTUWS_pooled/ntuws_member_demographics.csv",
  therm_file  = "data/Input/NTUWS_pooled/ntuws_party_thermometer_resolved.xlsx",
  therm_sheet = "總表",
  therm_stat  = "mean",      # 用 _mean 或 _median 那組溫度計欄位
  edu_col     = "education",
  ref_year    = 2024,        # 算年齡的基準年
  keep_splits = TRUE
)
```

人口學 CSV 以 `memberId` 為鍵；溫度計 xlsx 以 `out_id` 為鍵、`split_from` 對回 `memberId`。

### 2.3 換成你自己的樣本

兩種模式都對不上時，改程式裡的 `build_member_sample()`，把檔案讀成含這些欄位的 data.frame，後面流程完全共用：

```
memberId, sex, birth, ageband, edu, ethnicity, city, zip, party_kmt, party_dpp, party_tpp
```

---

## 3. 欄位偵測

`wave` 模式不靠固定欄名，而是同時比對**欄名**與**第 1 列的題目文字**：

| 內部變數 | 關鍵字 |
|---|---|
| `sex` | 性別 |
| `birth` ／ `ageband` | 出生 ／ 您的年齡、年齡 |
| `edu` | 學歷、教育程度 |
| `ethnicity` | 省籍、本省客家、籍貫、族群 |
| `city` ／ `zip` | 哪一個縣市、居住縣市、地區 ／ 郵遞區號 |
| `party_kmt` ／ `party_dpp` ／ `party_tpp` | 國民黨 ／ 民主進步黨、民進黨 ／ 民眾黨 |

溫度計另外檢查資料本身：排除泛藍／泛綠，且該欄必須真的是 0–10 量表。抓錯就用 `COLUMN_OVERRIDE <- c(edu = "S3 ")` 指定（欄名一字不差，注意結尾空白）。

---

## 4. 母體

```r
TARGET_DIR   <- "data/Input/population_targets"
TARGET_FILES <- c(sex = "targets_census_2025.csv", age = "targets_census_2025.csv",
                  edu = "targets_census_2025.csv", arear = "targets_census_2025.csv",
                  ethnicity = "targets_teds_2025.csv", party_kmt = "targets_teds_2025.csv",
                  party_dpp = "targets_teds_2025.csv", party_tpp = "targets_teds_2025.csv")

TARGET_SOURCE <- "joint"      # raking 與 multical；PAPP 的對應設定是 REF$target = "weighted"
JOINT <- list(file = "data/output/portion_of_TEDS/2025/joint/joint_full_raw.csv",
              count_col = "n_wt")
```

- **`TARGET_SOURCE = "joint"`（預設）**：母體目標 = 聯合表依 `count_col` 加總。`n_wt` = TEDS 權數 W 加權，`n` = 未加權。
- **`TARGET_FILES` 在 joint 模式下只用來決定「有哪些類別」**，不決定比例。`"files"` 模式才用它的比例。
- 聯合表只保留調整變數在合併後都有值、類別對得上的格，所以三種方法用的是**同一群 TEDS 受訪者**。
- **換聯合表年份時 `TARGET_FILES` 也要換同年份**：2024 與 2025 的區域標籤不同（高屏澎湖區／高屏區），2025 才有 18–19 歲組。不一致會在對齊檢查停下來。

可用的聯合表（`data/output/portion_of_TEDS/<來源>/joint/joint_full_raw.csv`）：`2024_ind`、`2024_pan`、`2025`、`pooled`。用 `joint=pooled` 之類的參數切換。

---

## 5. 調整變數

```r
RAKE_VARS <- c("sex", "age", "edu", "arear", "party_kmt", "party_dpp", "party_tpp")
```

- 沒放進 `RAKE_VARS`、但 `TARGET_FILES` 有指定的變數（例如 ethnicity），仍會出報表，當作**保留變數**檢查加權的副作用。
- **任一個調整變數缺值，整個人就被排除**（完整個案分析）。`member` 模式目前排除 39%，主要是教育與民眾黨溫度計。

---

## 6. 類別合併與 OPTS

樣本與母體的類別必須完全一致。`COLLAPSE` 寫一次，**同時套用在母體與樣本**。

```r
COLLAPSE <- list(age = "A2", arear = "A", edu = "B", ethnicity = "4class",
                 party_kmt = "C", party_dpp = "C", party_tpp = "C")
```

| 變數 | 代號 | 分組 |
|---|---|---|
| `age` | `A` ／ **`A2`（預設）** ／ `B` ／ `C` | 含 18-19 ／ 18-19 兩邊都設 NA ／ 20-39、40-59、60+ ／ 20-49、50+ |
| `arear` | `A` ／ `B` ／ `C` | 六區 ／ 北中南東 ／ 北中南 |
| `edu` | `A` ／ `B` ／ `C` | 5 類 ／ 高中職以下、專科、大學以上 ／ 高中職以下、專科以上 |
| `ethnicity` | `raw` ／ `4class` | 原始 ／ 客家、閩南、大陸各省市、其他 |
| `party_*` | `A` ／ `C` ／ `E` | 0…10 ／ 0-4、5、6-10 ／ 五段 |

自訂寫法：`COLLAPSE$edu <- list("高中以下" = c("小學及以下", "國、初中"), .drop = "...")`。沒提到的類別原樣保留，`.drop` 設為 NA，溫度計用數字對齊。

**edu 自動退回**：樣本出現「專科或大學」這種無法拆開的選項時，`OPTS$edu_auto_fallback` 會自動 A → B → C。

| OPTS | 可填 | 說明 |
|---|---|---|
| `sex_other_to_na` | `TRUE`/`FALSE` | 「其他」性別設為 NA |
| `island_to_na` | `TRUE`/`FALSE` | 母體不含外島時，外島設為 NA |
| `age_1819` | `"auto"`/`"keep"`/`"na"` | `auto` = 母體有 18-19 組才用 |
| `edu_auto_fallback` | `TRUE`/`FALSE` | 教育類別對不上時自動退到較粗版本 |
| `ethnicity_dk` | `"na"`/`"other"` | 省籍「不知道／拒答」排除或併入「其他」 |
| `dedupe` | `"smart"`/`"first"`/`"none"` | 同一 id 重複時；`smart` = 回答一致才去重 |
| `therm_scale` ／ `therm_round` | — | 1–10 量表平移成 0–9 ／ 非整數四捨五入 |

### 三支程式共用的命令列參數

| key | 意思 | 例 |
|---|---|---|
| `joint` | 換聯合表；只給名稱時讀 `portion_of_TEDS/<名稱>/joint/joint_full_raw.csv` | `joint=pooled` |
| `count_col` | `n_wt`（W 加權）或 `n`（未加權） | `count_col=n` |
| `target` | `joint` 或 `files` | `target=files` |
| `drop` | 從 `RAKE_VARS` 拿掉變數 | `drop=arear` |
| `collapse` | 覆寫合併代號 | `collapse=arear:B` |
| `out_root` | 輸出根目錄（預設 `data/output`），實驗用 | `out_root=data/output/experiments/test` |

---

## 7. raking_NTUWS.R

### 做法

anesrake 的迭代比例調整（IPF）：輪流把每個調整變數的加權分布拉到母體，直到收斂。**只對齊一階邊際，不處理變數之間的組合。** 權數有上限 `cap`。

```r
ANESRAKE <- list(cap = 5, choosemethod = "total", type = "pctlim",
                 pctlim = 0.05, nlim = 5, maxit = 1000, force1 = TRUE)
```

| 參數 | 意思 |
|---|---|
| `cap` | 單一權數上限（平均的幾倍）。小 → 權數穩但對不準；大 → 對得準但少數人主導 |
| `pctlim` | 樣本與母體總差距小於此值的變數就不 rake；`0` = 全部都 rake |
| `type` ／ `choosemethod` | 挑變數的規則 ／ 差距的算法 |
| `force1` | 權數標準化成平均 1 |

### 輸出（`data/output/raking/<樣本>/`，17 檔）

| 檔案 | 內容 |
|---|---|
| `weights_<樣本>.csv` | **權數**：`memberId`、`caseid`、`weight`（平均 1，空白 = 被排除）、`excluded_reason` |
| `dist_<樣本>.csv` | 每個變數每個類別：`n_sample`、`pct_sample`（加權前）、`pct_target`（母體）、`pct_raked`（加權後）、`in_raking` |
| `diagnostics_<樣本>.txt` | 執行紀錄、實際納入的變數、權數摘要、deff、與母體的最大差距、觸到 cap 的人數 |
| `dist_<樣本>_<變數>.png` | 母體／加權前／加權後的長條圖 |
| `collapse_<樣本>_<變數>.png` | 類別合併前後對比 |

> **partial convergence 警告**只表示迭代到後面改善很小就停了，不代表失敗。要看的是診斷檔裡「raking 後與母體的最大差距」。

---

## 8. MultiCalibration_NTUWS.R

### 做法

Ben-Michael, Feller & Hartman (2024) 式 (9)：

```
min  Σ_k≥2 (1/λ) ‖第 k 階交互的加權人數 − 母體人數‖²  +  Σ 權數變異數
s.t. 一階邊際完全對齊；lowlim ≤ 權數 ≤ uplim
```

λ 越大越接近 raking，越小越接近事後分層。`order = 1` 時沒有交互項，等於「平方距離版的 raking」。只算權數，不做 DRP（需要 Y）。

```r
MULTICAL <- list(order = 2, n_lambda = 40, lambda_min_ratio = 1e-10, lambda = NULL,
                 balance_threshold = 0.95, lowlim = 0.01, uplim = Inf, report_order = 3,
                 osqp = list(eps_abs = 1e-7, eps_rel = 1e-7, max_iter = 200000L, polish = TRUE))
```

| 參數 | 意思 |
|---|---|
| `order` | 平衡到幾階交互。聯合表只來自數千位 TEDS 受訪者，階數越高越可能在貼合抽樣雜訊；建議 2 |
| `n_lambda` ／ `lambda` | λ 路徑長度 ／ 指定單一 λ 就只解一個 |
| `balance_threshold` | 選 λ：以 order = 1 的解為基準、最小 λ 為最佳，取「改善量達 95%」中有效樣本數最大者 |
| `lowlim` | 權數下限（平均 = 1 的尺度）。**0.01 = 不允許為 0，但會有人被壓在 0.01**（§10） |
| `uplim` | 權數上限。一階邊際是硬約束，上限太低會無解 |

### 方法標籤與資料夾

**一個 run 一個子資料夾**，資料夾名 = 方法標籤，只有和預設不同的設定才加註：

| 設定 | 標籤（= 子資料夾名） |
|---|---|
| 預設（聯合表 2025、`n_wt`、錨定、lowlim 0.01、無上限） | `mlcal_o1`、`mlcal_o2` |
| `joint=pooled` ／ `count_col=n` ／ `target=files` | `mlcal_o2_jpooled` ／ `mlcal_o2_Njoint` ／ `mlcal_o2_tfiles` |
| `anchor=FALSE` ／ `lowlim=0` ／ `uplim=5` ／ 指定 λ | `_noanchor` ／ `_low0` ／ `_cap5` ／ `_lam0.01` |

### 輸出（`data/output/multical/<樣本>/<標籤>/`，23–24 檔）

除了 §7 的五種檔（`weights_`、`dist_`、`diagnostics_`、兩種 png）之外：

| 檔案 | 內容與意義 |
|---|---|
| `analysis_*.csv` | 每個人合併後的類別與 `complete`（給比較程式用；**含個人層資料，不上傳**） |
| `target_*.csv` | **聯合目標**：每一種變數組合一列，`n_teds`、`n_teds_wt`、`N_target`（實際用來校準的母體人數） |
| `coverage_*.csv` | **支撐檢查**：`pop_uncovered`（母體落在樣本空格的比例，權數救不了）、`sample_no_target`（樣本落在母體空格的比例） |
| `lambda_path_*.csv` | **λ 路徑**：每個 λ 的 `n_eff`、權數範圍、各階不平衡、`pct_improvement`、`selected` |
| `frontier_*.png` | λ 取捨曲線（論文 Fig. 2）：橫軸有效樣本數、縱軸交互不平衡，紅點 = 選中的 λ。只有 order ≥ 2 有 |
| `balance_*.csv` / `.png` | 1–3 階交互每一格的目標／樣本／order-1 解／選中解的比例與相對不平衡（論文 Fig. 3） |

---

## 9. PAPP_BART_NTUWS.R

### 做法

Rafei, Flannagan & Elliott (2020) 式 (2.5)、(2.7)。把 NTUWS 當成「入樣機率未知的隨機樣本」，用 TEDS 當參考樣本把入樣機率估出來：

```
π_B(x) ∝ π_R(x) × e(x) / (1 − e(x))     權數 = (1/π̂_R) × (1 − ê)/ê，正規化到平均 = 1
```

| | 模型 | 資料 |
|---|---|---|
| 模型 A | `BART::wbart`（連續） | TEDS：X → logit(π_R)，π_R ∝ 1/W |
| 模型 B | `BART::pbart`（probit） | NTUWS（Z = 1）與 TEDS（Z = 0）疊起來、**不加權** |

**不強制對齊邊際**；權數恆為正，不會有 0。不做論文 §2.4 的變異數估計（需要 Y）。

```r
REF  <- list(file = ".../2025/joint/joint_full_raw.csv", target = "weighted", pop_total = NA)
BART <- list(ntree_a = 200L, ntree_b = 50L, ndpost = 1000L, nskip = 100L,
             seed = 20200205L, cores = 1L, e_clip = 1e-6)
TRIM <- list(methods = c("iqr", "none"), c_iqr = 5, c_entropy = 6, maxit = 100)
```

| 參數 | 意思 |
|---|---|
| `REF$file` | 參考樣本。聯合表每格展開成 n 列、W = `n_wt / n`（TEDS 的 W 在同一格內是常數，所以這就是每個人真正的 W） |
| `ndpost` ／ `nskip` | MCMC 1,100 次、前 100 次 burn-in（論文 §5）；權數用後驗平均 |
| `seed` | BART 是 MCMC，**固定 seed 才能重現**（同 seed 重跑權數完全相同） |
| `TRIM$methods` | `iqr`：K = 中位數 + c × IQR（式 2.9）；`entropy`：K = √(c × Σw²/n)（式 2.8）；`none`。**一次 BART，每種 trimming 各一個子資料夾** |

### 輸出（`data/output/papp_bart/<樣本>/<標籤>/`，20 檔）

標籤是 `papp_bart_notrim`、`papp_bart_trimiqr5`、`papp_bart_trimentropy6`。除了 §7 的五種檔之外：

| 檔案 | 內容與意義 |
|---|---|
| `analysis_*.csv` | 同 multical（**含個人層資料，不上傳**） |
| `overlap_*.png` | 模型 B 的 logit(ê) 在 NTUWS 與 TEDS 的分布（論文 Fig. 5）。**兩條曲線不重疊的區域 = 缺乏共同支撐**，這些人的權數會很極端 |
| `weights_*.png` | 權數直方圖（對數尺度），紅虛線 = 截斷點 K |

`diagnostics` 另外有：參考樣本 n 與 W 範圍、支撐檢查、**模型 A 的 pseudo-R²**、**模型 B 的 AUC** 與 ê 分位數、trimming 截斷人數。

---

## 10. 判讀輸出

拿到權數之後，怎麼判斷這組權數好不好。以下指標都在 `diagnostics_*.txt`、`dist_*.csv`、`coverage_*.csv`、`lambda_path_*.csv` 裡。

### 10.1 權數本身

| 指標 | 在哪 | 意思與判讀 |
|---|---|---|
| **design effect（deff）** | `diagnostics` | `1 + (sd(w)/mean(w))²`。權數的離散程度，**越大代表加權後的估計越不穩定** |
| **有效樣本數 n_eff** | `diagnostics` | `n / deff`。加權後「相當於」多少人。deff = 3 就表示 8,800 人的樣本效力剩下約 2,900 人 |
| **最大權數** | `diagnostics` | 一個人能主導多少估計。PAPP 不 trim 時可能到 30 以上，代表少數人佔掉很大比重 |
| **觸到 cap 的比例** | raking 的 `diagnostics` | 卡在上限的人。比例高表示 raking 被上限綁住，可能因此對不準母體 |
| **權數在下限的比例** | multical 的 `diagnostics`、`weights` | multical 特有。`lowlim = 0.01` 時被壓到 0.01 的人**等於被排除在估計之外**，比例高（目前約 20–30%）要特別留意 |

### 10.2 加權後和母體差多少

| 指標 | 在哪 | 意思與判讀 |
|---|---|---|
| **`pct_target` vs `pct_raked`** | `dist_*.csv` | 母體比例 vs 加權後比例。**raking 與 multical 對調整變數應該接近 0；PAPP 不強制對齊，差距本身就是診斷** |
| **TVD** | 自己從 `dist_*.csv` 算 | `½ Σ|加權後 − 母體|`，單位百分點。一個變數整體差多少的單一數字 |
| **保留變數的差距** | `dist_*.csv` 裡 `in_raking = FALSE` 的列 | 沒拿去調整的變數（ethnicity）加權後有沒有跟著改善。**這是比較公平的檢查**，因為調整過的變數本來就會對齊 |

### 10.3 母體覆蓋（權數救不回來的部分）

| 指標 | 在哪 | 意思與判讀 |
|---|---|---|
| **`pop_uncovered`** | multical 的 `coverage_*.csv` | 母體落在「樣本 0 人」的格的比例。**權數只能分給樣本裡有人的格，這部分任何方法都救不回來** |
| **`sample_no_target`** | 同上 | 樣本落在「母體 0 人」的格。交互約束會把這些人的權數往下壓 |
| **共同支撐** | PAPP 的 `diagnostics`、`overlap_*.png` | 「NTUWS 落在 TEDS 沒有的格」要靠 BART 外推；「TEDS 落在 NTUWS 沒有的格」則是觸及不到的母體 |

判讀時要注意：完整交叉的格越細，落空比例越高。同樣人數的**簡單隨機樣本**也會有一定比例抽不到細格，所以落空比例要和「樣本數有限本來就會有的稀疏」分開看。

### 10.4 交互平衡（multical）

| 指標 | 在哪 | 意思與判讀 |
|---|---|---|
| **各階交互的 TVD** | `diagnostics`、`balance_*.csv` | 1 階 = 邊際，2 階 = 兩兩組合，3 階 = 三個變數的組合。**只對齊邊際的方法在 2、3 階會明顯差** |
| **λ 取捨曲線** | `lambda_path_*.csv`、`frontier_*.png` | 橫軸有效樣本數、縱軸交互不平衡。**左下角 = 交互對得準但樣本效力低**，右上角相反。程式預設取「改善達 95%」中 n_eff 最大者 |
| **`pct_improvement`** | `lambda_path_*.csv` | 相對 order-1 解的平衡改善百分比 |

### 10.5 模型診斷（PAPP）

| 指標 | 在哪 | 意思與判讀 |
|---|---|---|
| **模型 A 的 pseudo-R²** | `diagnostics` | 用 X 預測 TEDS 入樣機率的解釋力。接近 1 表示 W 幾乎由 X 決定 |
| **模型 B 的 AUC** | `diagnostics` | 用 X 分辨「這個人來自 NTUWS 還是 TEDS」的能力。**越高代表兩個樣本的組成差越多**，也代表權數會越極端 |
| **ê 分位數** | `diagnostics` | 兩個樣本的 propensity 分布。NTUWS 的 ê 若大量超過 TEDS 的第 99 百分位，就是缺乏共同支撐 |
| **trimming 截斷人數** | `diagnostics` | 截斷點 K、被截的人數與比例 |

### 10.6 綜合判斷

沒有單一最佳方法，取捨是：

- **raking**：權數最穩、沒有人被排除，但完全不處理變數之間的組合。
- **multilevel calibration（order = 2）**：交互平衡最好、邊際完全對齊，但有效樣本數低，而且約四分之一的人被壓在權數下限。
- **PAPP-BART（不 trim）**：交互平衡接近 multical、沒有人被排除，但有少數極大權數。
- **PAPP-BART（IQR trim）**：權數最集中、有效樣本數最大，但截斷的是樣本嚴重不足族群的權數，邊際會偏回樣本。

**最終判斷需要 Y**：有了共同的、但沒拿去調整的題目後，才能比較各方法的估計偏誤。

---

## 11. 常見錯誤

| 訊息 | 原因與處理 |
|---|---|
| `母體與樣本的類別對不齊` | 訊息會指出變數與類別。`COLLAPSE` 打錯、該波沒有這個類別（例如 18-19 歲 → 用 age `A2`），或 `TARGET_FILES` 與聯合表年份不同 |
| `聯合表沒有任何一格對得上` | `TARGET_FILES` 與聯合表年份不一致 |
| `教育程度有未對應的選項（設為 NA）` | 用詞不在 `EDU_MAP`；人數多就加進程式（省籍改 `ETH_MAP`） |
| `完整個案太少` | `RAKE_VARS` 太多或某變數缺值太嚴重 |
| `缺少套件 multical` ／ `BART` | 見 §1 |
| `multical 求解失敗` | 多半是 `uplim` 太低讓邊際約束無解；調高或設 `Inf` |
| `trimming 的截斷點太低` | 改用 `entropy` 或調高 `c_iqr` |
