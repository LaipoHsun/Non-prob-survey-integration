# Task 1 — Dissolve Population

台大網路抽獎問卷（NTUWS）的多波追蹤資料整理。這是非機率樣本，最終目的是要跟機率樣本
（ABS、TEDS）做整合分析，所以前置作業是把 NTUWS 的資料清成可以直接拿來 match 的形狀。

這個 repo 只放程式碼。原始問卷、中間產出、PDF 都留在本機，沒有上傳（見 `.gitignore`）。
所以 clone 下來不能直接跑，要自己準備 `data/NTUWS/raw_data/` 底下的 xlsx。

## 資料夾

```
Task_1_disolve_population/
├── code/                 分析層（規劃中，還沒開始寫）
└── data/
    └── NTUWS/
        ├── raw_data/     原始 xlsx，18 個 sheet：Welcome 名冊 + 17 波
        ├── Code/         清理程式，依 phase 分資料夾
        ├── output/       產出，資料夾名跟 Code/ 一一對應
        └── README.md     這條 pipeline 的詳細說明
```

`data/NTUWS/` 底下是「把原始資料清乾淨」這件事，做完就不太會再動。真正的分析之後會放在
最外層的 `code/`，從 `data/NTUWS/output/` 讀已經整理好的檔案，不碰原始 xlsx。這樣切是為了
不要讓分析的迭代把資料清理的部分弄髒。

`Code/<Phase>/` 跟 `output/<Phase>/` 是配對的，新開一個 phase 就兩邊各開一個同名資料夾。

## 三個 phase 在做什麼

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

## 執行

工作目錄在哪都可以。每支程式會從自己的位置往上找到 `data/NTUWS/`，之後全走絕對路徑，
過程中不呼叫 `setwd()`。

```bash
# Phase 0
Rscript "data/NTUWS/Code/Phase0_demographic_matching/clean_lottery_panel.R"

# Phase 1
LC_ALL=zh_TW.UTF-8 Rscript "data/NTUWS/Code/Phase1_within_wave_duplicates/extract_within_wave_duplicates.R"

# Phase 2，要先跑完 Phase 1
Rscript "data/NTUWS/Code/Phase2_cross_wave_question_matching/build_question_catalog.R"
Rscript "data/NTUWS/Code/Phase2_cross_wave_question_matching/party_thermometer/build_party_thermometer.R"
Rscript "data/NTUWS/Code/Phase2_cross_wave_question_matching/party_thermometer/resolve_party_thermometer_ids.R"
```

第一次跑之前先裝套件：

```bash
Rscript -e 'install.packages(c("readxl","dplyr","tidyr","stringr","purrr","writexl","ggplot2"))'
```

## 幾個約定

1. 原始資料唯讀。程式只讀 `raw_data/`，只寫 `output/`。
2. `output/` 整個是可拋棄的，刪掉重跑就會回來，不要往裡面放手工編輯的東西。
3. 不 `setwd()`。每支程式自己定位根資料夾。
4. 產出檔名一律加 `ntuws_` 前綴，跟之後 ABS 的 `abs_*` 區隔。
5. CSV 一律 UTF-8。

## 更細的說明

每個 phase 資料夾裡都有自己的 README，講規則怎麼定、數字多少、有什麼陷阱：

- [`data/NTUWS/README.md`](data/NTUWS/README.md) — 整條 pipeline 的總覽
- [`data/NTUWS/Code/Phase0_demographic_matching/README.md`](data/NTUWS/Code/Phase0_demographic_matching/README.md)
- [`data/NTUWS/Code/Phase1_within_wave_duplicates/README.md`](data/NTUWS/Code/Phase1_within_wave_duplicates/README.md)
- [`data/NTUWS/Code/Phase2_cross_wave_question_matching/README.md`](data/NTUWS/Code/Phase2_cross_wave_question_matching/README.md)

其中 `data/NTUWS/README.md` 本身沒有上傳（`.gitignore` 只放行 `Code/` 底下的東西），
要看的話在本機開。
