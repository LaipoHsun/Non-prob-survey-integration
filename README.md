# Integrating method to deal with selection bias problem

台大網路抽獎問卷（NTUWS）的多波追蹤資料整理與加權。這是**非機率樣本**，最終目的是要跟機率樣本（TEDS、ABS）做整合分析，所以要先把 NTUWS 清成可以直接 match 的形狀，再用機率樣本的分配把它調整到接近母體。

English version: [`README.en.md`](README.en.md)

repo 裡有兩條 pipeline：

| | 做什麼 | 位置 |
|---|---|---|
| **A. 資料清理** | 把 17 波原始問卷收斂成每人一列的乾淨檔 | `data/NTUWS/Code/` |
| **B. 加權** | 用 TEDS 當母體，算出每個受訪者的權數。**三種方法** | `data/code/` |

兩條各自獨立：A 的產出是 B 的其中一種輸入，但 B 也可以直接吃逐波原始檔。

Pipeline A 的所有內容只需要參考 NTUWS 內部的資料即可；其他 `/data/code`、`/data/Input`、`/data/output` 都是放入 Pipeline B 裡。要重製 Pipeline B 的加權，所需的資訊都在這三個資料夾裡（少數會用到原始資料的運算除外）。

---

## Pipeline B 的三種加權方法

| 程式 | 方法 | 出處 | 特點 |
|---|---|---|---|
| `raking_NTUWS.R` | **raking**（anesrake） | 傳統做法 | 只對齊一階邊際，權數穩定 |
| `MultiCalibration_NTUWS.R` | **multilevel calibration** | Ben-Michael, Feller & Hartman (2024), *Political Analysis* 32(1) | 邊際完全對齊，二階以上交互盡量對齊 |
| `PAPP_BART_NTUWS.R` | **PAPP-BART** | Rafei, Flannagan & Elliott (2020), *JSSAM* 8(1) | 用兩個 BART 模型估入樣機率，不強制對齊邊際 |

三支程式的**樣本讀取、重新編碼、類別合併、母體設定完全共用**，所以換方法只要換程式，不用改資料。

### 關鍵：母體用「聯合表」，不是邊際

傳統 raking 只需要每個變數各自的邊際分配。但 multilevel calibration 要平衡**變數之間的組合**，PAPP-BART 要**個人層的參考樣本**，兩者都需要更細的母體資訊。

所以這個 repo 提供 **TEDS 的聯合分布表**（`joint_full_raw.csv`）：一列一種變數組合，記錄該組合的人數 `n` 與 TEDS 權數加總 `n_wt`。三種方法都能吃這份表當母體，比較才有意義。

```
sex, age, edu, arear, ethnicity, party_kmt, party_dpp, party_tpp, n, n_wt, ...
女性, 30至39歲, 大學及以上, 中彰投區, 本省閩南人, 05, 05, 05, 10, 11.30, ...
```

---

## 快速開始

### 1. 安裝套件

```bash
Rscript -e 'install.packages(c("readxl","dplyr","tidyr","stringr","purrr","writexl","ggplot2","haven","scales","anesrake","BART","osqp","Matrix","remotes"))'
Rscript -e 'remotes::install_github("ebenmichael/multical")'
```

`multical` 只在 GitHub 上，一定要用 `remotes` 裝。R 圖用 `Heiti TC` 字型（macOS 內建），換作業系統要改各程式裡的 `base_family`。

### 2. 準備母體

repo 裡已經有算好的聯合表，**不需要 TEDS 原始資料就能直接用**：

```
data/output/portion_of_TEDS/
├── 2024_ind/joint/joint_full_raw.csv    TEDS 2024 面訪 獨立樣本（n = 1,113）
├── 2024_pan/joint/joint_full_raw.csv    TEDS 2024 面訪 定群樣本（n = 1,838）
├── 2025/joint/joint_full_raw.csv        TEDS 2025（n = 2,649）← 預設
└── pooled/joint/joint_full_raw.csv      三份合併（n = 5,600）
```

只有 TEDS 資料更新時才需要重新產生（需要 `data/TEDS/` 底下的 `.sav`）：

```bash
Rscript data/code/Calculate_stat_population_from_TEDS/joint_distribution_TEDS.R   # 各年份
Rscript data/code/Calculate_stat_population_from_TEDS/pool_joint_TEDS.R           # 合併版
```

### 3. 跑三種方法

```bash
Rscript data/code/raking_NTUWS.R           member          # raking
Rscript data/code/MultiCalibration_NTUWS.R member order=1  # 只對齊邊際
Rscript data/code/MultiCalibration_NTUWS.R member order=2  # 加上二階交互
Rscript data/code/PAPP_BART_NTUWS.R        member          # 一次輸出 notrim 與 trimiqr5
```

`member` 換成波次名（例如 `LS_23NY`）就是跑單一波次。multilevel calibration 一次只解一個 `order`，要兩種就跑兩次。

### 4. 拿到權數

```
data/output/
├── raking/<樣本>/                         weights_<樣本>.csv
├── multical/<樣本>/mlcal_o1/              weights_mlcal_o1_<樣本>.csv
│                  mlcal_o2/
└── papp_bart/<樣本>/papp_bart_notrim/     weights_papp_bart_notrim_<樣本>.csv
                     papp_bart_trimiqr5/
```

權數檔一律是 `memberId, caseid, weight, excluded_reason` 四欄，平均為 1，用 id 併回你的分析資料即可。

**怎麼判斷權數好不好**（deff、有效樣本數、TVD、母體覆蓋、λ 取捨曲線、AUC 這些指標的意思），見 [`data/code/README.md`](data/code/README.md) 的「判讀輸出」一節。

---

## 這個 repo 有什麼、沒有什麼

**有的**：三種方法的程式、TEDS 聯合分布表、加權成果（權數、分布對照表、診斷檔、代表性的圖）。

**沒有的**（都在 `.gitignore` 裡）：
<<<<<<< HEAD
因內有不同ID的個人檔案跟原本回答的人的機密內容,若需要請再和作者聯絡提供
=======
因內有不同 ID 的個人檔案跟原本回答的人的機密內容，若需要請再和作者聯絡提供。
>>>>>>> 8585e7a (Add multilevel calibration and PAPP-BART weighting with TEDS joint tables)

| 缺什麼 | 影響 | 原本放哪裡 |
|---|---|---|
| NTUWS 原始問卷 xlsx | pipeline A 跑不動；B 的 `wave` 模式跑不動 | `data/NTUWS/raw_data/` |
| NTUWS 個人層彙整檔 | B 的 `member` 模式跑不動 | `data/Input/NTUWS_pooled/`（含個資） |
| TEDS 原始 `.sav` | 不能重新產生聯合表與目標檔 | `data/TEDS/` |

所以**別人不能直接重現這裡的範例**，但可以用自己的樣本跑：準備一份每人一列的資料，照 [`data/Input/README.md`](data/Input/README.md) 的欄位格式，母體直接用 repo 裡的聯合表。

> 比較三種方法的程式（`compare_raking_multical.R`）還在調整，尚未上傳。目前要比較，請用各方法 `diagnostics_*.txt` 與 `dist_*.csv` 裡的指標自行對照。

---

## 資料夾

```
Task_1_disolve_population/
├── data/
│   ├── NTUWS/
│   │   ├── raw_data/     原始 xlsx（不上傳）
│   │   ├── Code/         pipeline A：清理程式
│   │   └── output/       pipeline A 的產出（不上傳）
│   ├── code/             pipeline B：三種加權方法
│   │   ├── raking_NTUWS.R
│   │   ├── MultiCalibration_NTUWS.R
│   │   ├── PAPP_BART_NTUWS.R
│   │   └── Calculate_stat_population_from_TEDS/   從 TEDS 算母體
│   ├── Input/
│   │   ├── population_targets/   邊際目標檔
│   │   └── NTUWS_pooled/         個人層樣本（不上傳）
│   ├── output/
│   │   ├── portion_of_TEDS/      TEDS 的描述統計與聯合表
│   │   ├── raking/               三種方法的權數與診斷
│   │   ├── multical/
│   │   └── papp_bart/
│   └── TEDS/  ABS/       機率樣本原始資料（不上傳）
```

<<<<<<< HEAD
`Code/<Phase>/` 跟 `output/<Phase>/` 是配對的，新開一個 phase 就兩邊各開一個同名資料夾。
Pipeline A的所有內容只需要參考NTUWS內部的資料即可
其他/code /Input /output 都是放入Pipeline B裡
---

## Pipeline A：資料清理

`data/NTUWS/Code/`。把原始問卷清乾淨，做完就不太會再動。

**Phase 0：demographic 主表**（`Phase0_demographic_matching/`）
把 17 波的作答收斂成每人一列的主表。性別、出生年、父親籍貫這三個欄位理論上不會變，跨波
對不起來的人就列進矛盾清單、不進主表；年齡、學歷、縣市這些會變的欄位取最新一波的值。
產出 14,870 人，六個欄位的名字是刻意挑的，跟 ABS 那邊掃出來的變項對得上。

**Phase 1：波次內去重**（`Phase1_within_wave_duplicates/`）
同一波裡同一個 memberId 出現多次的情況。內容完全一樣就留第一筆（純粹重送），內容有差異
就整組刪掉（沒辦法判斷哪份為真）。刪掉 752 列。跟 Phase 0 各自獨立，沒有先後順序。

**Phase 2：跨波題目配對**（`Phase2_cross_wave_question_matching/`）
同一個概念的題目散在各波，欄位名稱、題幹、量尺都不一樣（`Q33` / `b1_1` / `Q1__dup1` 問的
是同一件事）。先把 267 個欄位歸成 18 個 category，再一批一批把跨波回答收斂成代表值。
目前收斂完成的是政黨喜愛那三黨，其餘 15 個 category 還沒做。

### 執行

```bash
Rscript "data/NTUWS/Code/Phase0_demographic_matching/clean_lottery_panel.R"
```
```bash
LC_ALL=zh_TW.UTF-8 Rscript "data/NTUWS/Code/Phase1_within_wave_duplicates/extract_within_wave_duplicates.R"
```
```bash
Rscript "data/NTUWS/Code/Phase2_cross_wave_question_matching/build_question_catalog.R"
```
```bash
Rscript "data/NTUWS/Code/Phase2_cross_wave_question_matching/party_thermometer/build_party_thermometer.R"
```
```bash
Rscript "data/NTUWS/Code/Phase2_cross_wave_question_matching/party_thermometer/resolve_party_thermometer_ids.R"
```

Phase 2 要先跑完 Phase 1。

---

## Pipeline B：加權（raking）
所有要重製Pipeline B的 raking所需的資訊皆在 /data/code, /data/Input, /data/output裡 除了少數會用到的資料運算
`data/code/`。用 anesrake 把樣本的邊際分配拉向母體，算出每人一個權數。

**`raking_NTUWS.R`** —— 主程式。支援兩種樣本結構，用命令列參數切換：

```bash
Rscript data/code/raking_NTUWS.R LS_23NY
```
```bash
Rscript data/code/raking_NTUWS.R member
```

前者讀逐波原始 xlsx 的某一個分頁，後者讀 `data/Input/NTUWS_pooled/` 的個人層彙整檔。
要改母體來源、要 rake 哪些變數、類別怎麼合併，都在程式最上面的 CONFIG 區塊改。

**`Calculate_stat_population_from_TEDS/`** —— 從 TEDS 的 `.sav` / `.sps` 算出邊際分配，
產生母體目標檔與描述統計。TEDS 資料更新時才需要重跑。

```bash
Rscript data/code/Calculate_stat_population_from_TEDS/build_population_targets.R
```
```bash
Rscript data/code/Calculate_stat_population_from_TEDS/portion_of_TEDS_party_feeling.R
```
```bash
Rscript data/code/Calculate_stat_population_from_TEDS/portion_of_TEDS_demographics.R
```

母體有兩種：`targets_census_*` 是官方人口數（真實人口，只涵蓋性別／年齡／教育／區域），
`targets_teds_*` 是 TEDS 樣本本身的分配（涵蓋全部變數，供省籍、政黨溫度計這類沒有官方
人口數的變數使用）。每個變數可以各自指定不同來源。

=======
>>>>>>> 8585e7a (Add multilevel calibration and PAPP-BART weighting with TEDS joint tables)
---

## 幾個約定

<<<<<<< HEAD
1. **`output/` 整個是可拋棄的**，刪掉重跑就會回來，不要往裡面放手工編輯的東西。
2. **不 `setwd()`。** 每支程式自己往上找專案根目錄（判斷依據是找得到 `data/code/`），
   之後全走絕對路徑，所以在哪個目錄執行都可以。
3. **產出檔名一律加 `ntuws_` 前綴**，跟之後 ABS 的 `abs_*` 區隔。
4. **CSV 一律 UTF-8。** 中文在 `Rscript` 的預設 C locale 下會被丟掉，所以每支程式開頭
   都會設定 UTF-8 locale，不要移除那幾行。
=======
1. **原始資料唯讀。** 程式只讀原始檔，只寫 `output/`。
2. **`output/` 是可拋棄的**，刪掉重跑就會回來。
3. **不 `setwd()`。** 每支程式自己往上找專案根目錄（判斷依據是找得到 `data/code/`），所以在哪個目錄執行都可以。
4. **CSV 一律 UTF-8。** 中文在 `Rscript` 的預設 C locale 下會被丟掉，每支程式開頭都會設定 UTF-8 locale，不要移除那幾行。
5. **重編碼與類別合併都寫在程式裡**，不改資料檔。加權時母體端與樣本端同步套用同一份設定。
>>>>>>> 8585e7a (Add multilevel calibration and PAPP-BART weighting with TEDS joint tables)

---

## 更細的說明

- [`data/code/README.md`](data/code/README.md) — **三種方法怎麼用、每個參數什麼意思、每個輸出檔怎麼判讀**
- [`data/code/Calculate_stat_population_from_TEDS/README.md`](data/code/Calculate_stat_population_from_TEDS/README.md) — 聯合表與目標檔怎麼算出來的
- [`data/Input/README.md`](data/Input/README.md) — 輸入資料的格式
- [`data/output/README.md`](data/output/README.md) — 產出的資料夾各是什麼
- Pipeline A：`data/NTUWS/Code/` 底下各 phase 的 README
