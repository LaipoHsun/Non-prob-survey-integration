# Task 1 — Dissolve Population

非機率樣本（網路抽獎問卷 NTUWS）與機率樣本（ABS / TEDS）的整合分析。
目前進度：**Phase 0 盤點兩邊共有的 demographic 欄位**（兩線都已完成）、
**Phase 1 NTUWS 波次內去重**（已完成）、
**Phase 2 NTUWS 跨波題目配對與個體回答收斂**（配對已完成，18 個 category；
收斂已完成第一批「政黨喜愛」三黨，其餘 15 個 category 待處理 ——
見 [`data/NTUWS/PHASE2_README.md`](data/NTUWS/PHASE2_README.md)）。

資料依「調查來源」分資料夾，每個來源自成一套 pipeline，彼此不共用路徑、不互相依賴：

```
Task_1_disolve_population/
├── README.md                你在看的這份，講整個專案的資料夾結構
├── data/
│   ├── NTUWS/               網路抽獎問卷追蹤資料（非機率樣本）★ 有 pipeline
│   ├── ABS/                 亞洲民主動態調查台灣資料（機率樣本）★ 有 pipeline
│   ├── TEDS/                台灣選舉與民主化調查，原始壓縮檔為主，尚未整理
│   └── 台灣選舉調查資料/     SRDA 下載的其他選舉調查，尚未整理
├── Literature Review/       9 篇方法論論文 PDF
├── Paper Comment/           論文評論與相關中文文獻
└── Meeting Note.pages
```

★ 兩個有 pipeline 的資料夾各有自己的 README，細節看那兩份：

- [`data/NTUWS/README.md`](data/NTUWS/README.md)
- [`data/ABS/README.md`](data/ABS/README.md)

---

## 1. 快速開始

三支程式，兩條互相獨立的線。**工作目錄在哪都可以** —— 每支程式都會從自己的所在位置
往上找到該來源的根資料夾，之後全走絕對路徑，過程中不呼叫 `setwd()`。

```bash
# NTUWS 線：xlsx -> 主表
Rscript "data/NTUWS/Code/Phase0_demographic_matching/clean_lottery_panel.R"

# NTUWS 線：xlsx -> 波次內去重後的 xlsx（與 Phase0 各自獨立，無先後順序）
LC_ALL=zh_TW.UTF-8 Rscript "data/NTUWS/Code/Phase1_within_wave_duplicates/extract_within_wave_duplicates.R"

# ABS 線：.sav -> CSV -> 對照表（有先後順序）
LANG=en_US.UTF-8 Rscript "data/ABS/abs_sav_to_csv.R"
LANG=en_US.UTF-8 Rscript "data/ABS/scan_abs_demographics.R"
```

⚠️ ABS 那兩支的 `LANG=en_US.UTF-8` **不能省**。`Rscript` 預設 `LC_CTYPE=C`，
`haven::read_sav()` 會打不開「第一波台灣完整調查(特有題)」這種中文路徑
（報 `does not exist`，但 `file.exists()` 卻是 `TRUE`）。程式已內建檢查，
locale 不對會直接中止並告訴你怎麼改。在 RStudio 裡跑不會遇到。

第一次跑之前先裝套件：

```bash
Rscript -e 'install.packages(c("readxl","dplyr","tidyr","stringr","purrr","haven","readr","writexl"))'
```

---

## 2. 資料流

```
data/NTUWS/
  raw_data/lottery_repeated_raw_by_wave.xlsx
        │  clean_lottery_panel.R
        ▼
  output/Phase0_demographic_matching/ntuws_member_demographics.csv
        │
        │  六個欄位名（sex / age / birth_year /
        │  father_ethnicity / education / city）
        │  就是下面那支程式要在 ABS 裡找的目標
        ▼
data/ABS/
  Raw data/**/*.sav
        │  abs_sav_to_csv.R
        ▼
  ABS_csv/**/{*.csv, *_raw.csv, *_codebook.csv, *_valuelabels.csv}
        │  scan_abs_demographics.R
        ▼
  output/Phase0_demographic_matching/abs_demographic_{matrix,crosswalk,candidates}.csv
```

兩邊的 Phase 0 產出合起來，就是「NTUWS 與 ABS 共有、可用來做合併分析的 demographics」盤點。

---

## 3. `data/` 底下四個來源

### 3.1 `data/NTUWS/` — 網路抽獎問卷（非機率樣本），11 MB

```
NTUWS/
├── raw_data/                 原始 xlsx（18 個 sheet：Welcome 名冊 + 17 波）
├── Supplementary_material/   資料使用說明 PDF、政黨題項對照表 xlsx
├── Code/<Phase>/             程式，依 phase 分資料夾
├── output/<Phase>/           產出，資料夾名與 Code/ 的 phase 一一對應
└── README.md
```

`Code/` 與 `output/` 底下的 phase 資料夾是配對的；目前有 `Phase0_demographic_matching/`
（產出主表 14,407 人、矛盾清單 1,354 筆、標準化長表 55,292 列）與
`Phase1_within_wave_duplicates/`（產出去重後的 xlsx 總表與被刪列清單，共兩個檔）。

### 3.2 `data/ABS/` — 亞洲民主動態調查台灣資料（機率樣本），148 MB

```
ABS/
├── Raw data/                 12 個波次資料夾（.sav / .dta / .dat / .sps / 問卷 PDF）
├── Raw data zip file/        12 個原始下載 zip，已全部解壓到 Raw data/
├── ABS_csv/                  由 abs_sav_to_csv.R 轉出的 CSV（可刪掉重跑）
├── output/<Phase>/           分析產出（可刪掉重跑）
├── abs_sav_to_csv.R
├── scan_abs_demographics.R
└── README.md                 逐檔說明，含每一波的變項命名、權重欄、編碼陷阱
```

12 個 `.sav` 轉出 49 個 CSV（約 97 MB）。
W1–W6 各有「英文核心題版」與「中文完整版（含統獨／認同等台灣特有題）」兩套，
同一波是同一批受訪者、列數相同。

### 3.3 `data/TEDS/` — 台灣選舉與民主化調查，286 MB

2001–2026 年的面訪、電訪、手機調查案，**目前絕大多數還是 `.zip` / `.rar` 原始下載檔，
尚未納入任何 pipeline**。只有兩個已解壓：

| 已解壓資料夾 | 內容 |
|---|---|
| `TEDS2016_PA12/` | `TEDS2016-T_PA12/` 底下有 `SAV` / `DAT` / `SPS` / `QUE` / `FRE` / `Codebook` 六個子資料夾 |
| `TEDS2021_PA03_解壓縮/` | 同上結構 |

另有兩份說明文件：`TEDS_2022_2026_電訪面訪調查計畫彙整表.xlsx`、
`TEDS2001-2012年資料庫整合說明.docx`。

要用的話請沿用 ABS 的作法：解壓到 `Raw data/`，轉檔輸出到自己的 `*_csv/`，
不要把解壓結果和 zip 混在同一層。

### 3.4 `data/台灣選舉調查資料/` — SRDA 其他選舉調查，25 MB

5 個尚未解壓的 SRDA 資料集（`C00395_1/2`、`C00401_1/2`、`D00232`），
外加 `SRDA_已核准下載資料清單.xlsx`（已核准下載的清單）。同樣尚未納入 pipeline。

---

## 4. 文獻與筆記

| 資料夾 | 內容 |
|---|---|
| `Literature Review/` | 9 篇 PDF。檔名帶 `1.Review_` / `2.Algorithm_` / `3.Algorithm_` 前綴的是主要參考：非機率樣本推論綜述、BART quasi-randomization、未知重疊下的機率／非機率樣本合併 |
| `Paper Comment/` | 論文評論（`Paper comment.pages`）與相關文獻：非機率樣本校準的統計範式、網絡問卷資料修正方法、機率與非機率樣本的統計整合 |
| `Meeting Note.pages` | 會議筆記 |

---

## 5. 約定

以下幾件事三支程式都一致，改東西時請沿用：

1. **原始資料唯讀。** 程式只讀 `raw_data/` 或 `Raw data/`，只寫 `output/` 與 `ABS_csv/`。
2. **產出可拋棄。** `output/` 和 `ABS_csv/` 刪掉重跑就會回來，不要往裡面放手工編輯的東西。
3. **不 `setwd()`。** 每支程式自己定位根資料夾（找路標檔案／資料夾），之後全走絕對路徑。
4. **產出檔名帶來源前綴**（`ntuws_*` / `abs_*`），即使分了資料夾也一眼看得出來自哪一邊。
5. **產出依 phase 分資料夾**，資料夾名與程式裡的 `PHASE` 常數一致。
6. **CSV 一律 UTF-8**；ABS 那邊多加 BOM，Excel 直接點兩下開不會亂碼。
