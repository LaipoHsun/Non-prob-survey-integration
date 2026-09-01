# Task 1 — Dissolve Population

台大網路抽獎問卷（NTUWS）的多波追蹤資料整理與加權。這是非機率樣本，最終目的是要跟機率樣本
（ABS、TEDS）做整合分析，所以要先把 NTUWS 清成可以直接拿來 match 的形狀，再用機率樣本的
邊際分配把它調整到接近母體。

repo 裡有兩條 pipeline：

| | 做什麼 | 位置 |
|---|---|---|
| **A. 資料清理** | 把 17 波原始問卷收斂成每人一列的乾淨檔 | `data/NTUWS/Code/` |
| **B. 加權（raking）** | 用 TEDS／官方人口數當母體，算出每個受訪者的權數 | `data/code/` |

兩條各自獨立：A 的產出是 B 的其中一種輸入，但 B 也可以直接吃逐波原始檔，不必先跑 A。

## 這個 repo 有什麼、沒有什麼

**有的**：所有程式碼、母體目標檔、加權與描述統計的成果（表、圖、診斷檔）。

**沒有的**（都在 `.gitignore` 裡）：

| 缺什麼 | 影響 | 要放哪裡 |
|---|---|---|
| NTUWS 原始問卷 xlsx | pipeline A 完全跑不動；B 的 `wave` 模式跑不動 | `data/NTUWS/raw_data/lottery_repeated_raw_by_wave.xlsx` |
| NTUWS 個人層彙整檔 | B 的 `member` 模式跑不動 | `data/Input/NTUWS_pooled/`（含個資，不上傳）|
| TEDS 原始 `.sav` / `.sps` | 不能重新產生母體目標檔 | `data/TEDS/` |
| ABS 原始資料 | 目前尚未用到 | `data/ABS/` |

**母體目標檔（`data/Input/population_targets/`）已經在 repo 裡**，所以要做自己的加權，
只需要準備一份樣本檔，不需要 TEDS 原始資料。

## 資料夾

```
Task_1_disolve_population/
├── data/
│   ├── NTUWS/
│   │   ├── raw_data/     原始 xlsx，18 個 sheet：Welcome 名冊 + 17 波（不上傳）
│   │   ├── Code/         pipeline A：清理程式，依 phase 分資料夾
│   │   └── output/       pipeline A 的產出，資料夾名跟 Code/ 一一對應（不上傳）
│   │
│   ├── code/             pipeline B：加權程式
│   │   ├── raking_NTUWS.R
│   │   └── Calculate_stat_population_from_TEDS/   從 TEDS 算母體分配
│   │
│   ├── Input/            pipeline B 的輸入
│   │   ├── population_targets/   母體目標檔
│   │   └── NTUWS_pooled/         個人層樣本（不上傳）
│   │
│   ├── output/           pipeline B 的產出
│   │   ├── portion_of_TEDS/      TEDS 各變數的次數分配
│   │   └── raking/               權數、分布對照、診斷檔
│   │
│   └── TEDS/  ABS/       機率樣本原始資料（不上傳）
```

`Code/<Phase>/` 跟 `output/<Phase>/` 是配對的，新開一個 phase 就兩邊各開一個同名資料夾。

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

---

## 套件

```bash
Rscript -e 'install.packages(c("readxl","dplyr","tidyr","stringr","purrr","writexl","ggplot2","haven","scales","anesrake"))'
```

pipeline A 用前七個，pipeline B 用 `readxl` `dplyr` `tidyr` `ggplot2` `scales` `haven` `anesrake`。

R 圖用 `Heiti TC` 字型（macOS 內建），換作業系統要改各程式裡的 `base_family`。

---

## 幾個約定

1. **原始資料唯讀。** 程式只讀原始檔，只寫 `output/`。
2. **`output/` 整個是可拋棄的**，刪掉重跑就會回來，不要往裡面放手工編輯的東西。
3. **不 `setwd()`。** 每支程式自己往上找專案根目錄（判斷依據是找得到 `data/code/`），
   之後全走絕對路徑，所以在哪個目錄執行都可以。
4. **產出檔名一律加 `ntuws_` 前綴**，跟之後 ABS 的 `abs_*` 區隔。
5. **CSV 一律 UTF-8。** 中文在 `Rscript` 的預設 C locale 下會被丟掉，所以每支程式開頭
   都會設定 UTF-8 locale，不要移除那幾行。
6. **重編碼與類別合併都寫在程式裡**，不去改資料檔。加權時母體端與樣本端會同步套用
   同一份合併設定，兩邊永遠對得齊。

---

## 更細的說明

每個資料夾裡都有自己的 README：

**Pipeline A**
- [`data/NTUWS/Code/Phase0_demographic_matching/README.md`](data/NTUWS/Code/Phase0_demographic_matching/README.md)
- [`data/NTUWS/Code/Phase1_within_wave_duplicates/README.md`](data/NTUWS/Code/Phase1_within_wave_duplicates/README.md)
- [`data/NTUWS/Code/Phase2_cross_wave_question_matching/README.md`](data/NTUWS/Code/Phase2_cross_wave_question_matching/README.md)

**Pipeline B**
- [`data/code/README.md`](data/code/README.md) — 怎麼用 `raking_NTUWS.R`：指定樣本、指定母體、
  指定要 rake 哪些變數、類別怎麼合併、anesrake 參數的意義
- [`data/code/Calculate_stat_population_from_TEDS/README.md`](data/code/Calculate_stat_population_from_TEDS/README.md)
  — 母體目標檔怎麼算出來的，以及要換一份資料時要改哪裡
- [`data/Input/README.md`](data/Input/README.md) — 輸入資料的格式，以及怎麼換成自己的母體
- [`data/output/README.md`](data/output/README.md) — 產出的兩個資料夾各是什麼
- [`data/output/raking/README.md`](data/output/raking/README.md) — 跑完 raking 會生出哪些檔、
  每個欄位什麼意思、三個關鍵指標怎麼判讀
