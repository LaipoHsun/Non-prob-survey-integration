# raking_NTUWS.R 使用說明

把一份調查樣本，依指定的母體分配做 raking（iterative proportional fitting），算出每個受訪者的權數。

本文件只講**怎麼用這支程式**。母體目標檔怎麼來的，見 [`Calculate_stat_population_from_TEDS/README.md`](Calculate_stat_population_from_TEDS/README.md)。

---

## 快速上手

```bash
cd "<專案根目錄>"
Rscript data/code/raking_NTUWS.R              # 跑 CONFIG 裡設定的樣本
Rscript data/code/raking_NTUWS.R LS_23NY      # 指定某一波
Rscript data/code/raking_NTUWS.R member       # 跑個人層彙整檔 (即已被整理完把年份裡收到的調查資料的組合合併)
Note: 要調整母體來源要到R code裡面處理
```

命令列參數會覆寫 `SAMPLE_TYPE` 與 `WAVE`，其他設定仍讀檔案裡的 CONFIG。輸出固定放在 `data/output/raking/<樣本名稱>/`。

---

## 1. 怎麼指定樣本

程式支援兩種樣本結構。**要換樣本，改的是 `SAMPLE_TYPE` 這一組設定**

### 1.1 `SAMPLE_TYPE = "wave"` —— 一個 Excel、一頁一波

```r
SAMPLE_TYPE <- "wave"
SAMPLE_FILE <- "data/NTUWS/raw_data/lottery_repeated_raw_by_wave.xlsx"
WAVE        <- "LS_23NY"     # 要跑哪一個分頁
BASE_SHEET  <- "Welcome"     # 這一波沒問到的欄位，用這個分頁補；不要補就設 NA
WAVE_YEAR   <- NA            # 算年齡用的年份；NA = 從 WAVE 名稱推導
```

這個模式假設的檔案長相：

- 一個 xlsx，每一個分頁是一次調查
- **第 1 列是題目全文，第 2 列開始才是資料**
- 有一欄叫 `memberId` 當受訪者識別碼
- 另外可以有一個「基本資料」分頁（`BASE_SHEET`），同樣以 `memberId` 為鍵

欄位不必每一波都叫同樣的名字（見 §2）。該波沒問到的性別／出生年／縣市，會從 `BASE_SHEET` 補；**該波自己問到的優先，`BASE_SHEET` 只補缺**。

`WAVE_YEAR` 留 `NA` 時，程式從分頁名稱的 `LS_yy` 推年份（`LS_2405` → 2024）。名稱格式不同就直接填數字。

### 1.2 `SAMPLE_TYPE = "member"` —— 兩個檔接起來，一列一個人

```r
SAMPLE_TYPE <- "member"
MEMBER <- list(
  demo_file   = "data/Input/NTUWS_pooled/ntuws_member_demographics.csv",
  therm_file  = "data/Input/NTUWS_pooled/ntuws_party_thermometer_resolved.xlsx",
  therm_sheet = "總表",
  therm_stat  = "median",    # 或 "mean"
  edu_col     = "education",
  ref_year    = 2024,
  keep_splits = TRUE
)
```

這個模式假設：人口學一個 CSV（鍵為 `memberId`）、政黨溫度計一個 xlsx（鍵為 `out_id`，另有 `split_from` 對回 `memberId`）。

| 設定 | 說明 |
|---|---|
| `demo_file` / `therm_file` / `therm_sheet` | 兩個檔的位置與分頁 |
| `therm_stat` | 用 `_median` 還是 `_mean` 結尾的那組溫度計欄位 |
| `edu_col` | 人口學檔裡要用哪一欄當教育程度 |
| `ref_year` | 算年齡的基準年。彙整檔跨多個時點，沒有單一調查日，要自己指定 |
| `keep_splits` | 溫度計檔若把矛盾作答者拆成多個 `out_id`：`TRUE` 全留、`FALSE` 只留未拆分者 |

這個模式不會用到 `BASE_SHEET`。

### 1.3 要接完全不同的樣本檔

如果新資料是「一個 xlsx、一頁一波、第一列題目、有 memberId」——直接改 `SAMPLE_FILE` 和 `WAVE` 就好。

如果是「一列一個人」的平表——用 `member` 模式，把 `demo_file` 指過去。若沒有第二個溫度計檔，仍需給 `therm_file` 一個含 `out_id`／`split_from` 的檔；沒有的話最省事的作法是把你的平表複製一份、加上 `out_id` 與 `split_from` 兩欄（值都等於 id）。

兩種模式都對不上的話，要改的是程式裡 `build_member_sample()` 那一段，把你的檔讀成一個含下列欄位的 data.frame 即可，後面的流程完全共用：

```
memberId, sex, birth, ageband, edu, ethnicity, city, zip,
party_kmt, party_dpp, party_tpp
```

---

## 2. 欄位是怎麼被找到的

`wave` 模式下程式不靠固定欄名，而是同時比對**欄名**與**第 1 列的題目文字**：

| 內部變數 | 比對的關鍵字 |
|---|---|
| `sex` | 性別 |
| `birth` | 出生 |
| `ageband` | 您的年齡、年齡、請問您的年齡 |
| `edu` | 學歷、教育程度 |
| `ethnicity` | 省籍、本省客家、籍貫、族群 |
| `city` | 哪一個縣市、居住的縣市、居住縣市、地區 |
| `zip` | 郵遞區號 |
| `party_kmt` | 國民黨 |
| `party_dpp` | 民主進步黨、民進黨 |
| `party_tpp` | 民眾黨 |

溫度計另外會檢查資料本身：排除泛藍／泛綠，且該欄必須真的是 0–10 量表（至少 8 個相異值、範圍落在 0–10）。這樣才抓得到題目文字只寫「請問您會給民進黨多少？」的欄位，也不會誤抓 1–5 分的感受題。

執行時畫面會印出偵測結果：

```
偵測到的欄位：sex=您的生理性別？  birth=-  ageband=您的年齡  edu=請問您的教育程度 ...
```

**抓錯或抓不到就用 `COLUMN_OVERRIDE` 指定**（欄名要跟檔案裡一模一樣，注意結尾可能有空白）：

```r
COLUMN_OVERRIDE <- c(edu = "S3 ", city = "S5_1")
```

要新增關鍵字則改程式裡的 `PATTERNS`。

---

## 3. 怎麼指定母體

```r
TARGET_DIR   <- "data/Input/population_targets"
TARGET_FILES <- c(
  sex       = "targets_census_2024.csv",
  age       = "targets_census_2024.csv",
  edu       = "targets_census_2024.csv",
  arear     = "targets_census_2024.csv",
  ethnicity = "targets_teds_2024_ind.csv",
  party_kmt = "targets_teds_2024_ind.csv",
  party_dpp = "targets_teds_2024_ind.csv",
  party_tpp = "targets_teds_2024_ind.csv"
)
```

**每個變數各自指定，可以混用不同來源。** 換母體 = 換這裡的檔名，程式其他部分不用動。

母體檔的格式是一列一個類別，必要欄位 `variable`、`label`、`N`（`arear` 另外會用到 `code`）。要用自己的母體，做一個同格式的 CSV 丟進 `TARGET_DIR` 就好。

---

## 4. 怎麼指定要 rake 哪些變數

```r
RAKE_VARS <- c("sex", "age", "edu", "arear")
```

可用：`sex` `age` `edu` `arear` `ethnicity` `party_kmt` `party_dpp` `party_tpp`
（三個政黨溫度計各自獨立，可以只放其中一個。）

兩件事要知道：

- **沒放進 `RAKE_VARS` 但 `TARGET_FILES` 有指定的變數，仍然會出圖出表**，只是不參與 raking。這樣可以看出 raking 對它們造成了什麼影響。
- **放越多，掉的人越多。** 任一個 raking 變數缺值，整個個案就進不了 raking。畫面會逐項顯示各變數的 NA 比例，決定前先看那個。

---

## 5. 怎麼指定類別合併

母體與樣本的類別必須完全對齊才能 raking。合併寫一次，**程式會同時套用在母體與樣本兩邊**。
ex. education兩邊的樣本可以回答的內容必須相同, 如果有不同就要collapse,假設:
    A--> 國小/國中/高中/大學/研究所
    B--> 國小/國中/高中/大學與專科 
    那collapse起來就要設定 國小/國中/高中/大學專科與以上 這樣

### 5.1 用預設代號
以下有先依據作者個人的判斷選擇要做的可以collapse的方案 方式列於下

```r
COLLAPSE <- list(age = "A", arear = "A", edu = "B",
                 ethnicity = "4class", party_kmt = "C")
```

| 變數 | 代號 | 分組 |
|---|---|---|
| `age` | `A` | 原始（18-19 / 20-29 / 30-39 / 40-49 / 50-59 / 60+）|
| | `A2` | 同 A，但 18-19 設為 NA (有些TEDS資料需要20歲以上)|
| | `B` | 20-39 / 40-59 / 60+ |
| | `C` | 20-49 / 50+ |
| `arear` | `A` | 原始NTUWS設定的 6 區 |
| | `B` | 北 / 中 / 南 / 東 |
| | `C` | 北 / 中 / 南 |
| `edu` | `A` | 原始 5 類 |
| | `B` | 高中職及以下 / 專科 / 大學及以上 |
| | `C` | 高中職及以下 / 專科及以上 |
| `ethnicity` | `raw` | 母體的原始類別 |
| | `4class` | 客家 / 閩南 / 大陸各省市 / 其他 |
| `party_*` | `A` | 原始 11 類（0…10）|
| | `C` | 0-4 冷淡 / 5 中間 / 6-10 溫暖 |
| | `E` | 0-2 / 3-4 / 5 / 6-7 / 8-10 |

沒有在 `COLLAPSE` 裡列到的變數就是不合併。

### 5.2 自己寫

直接給一個 list，格式是 `新類別 = c(舊類別...)`：

```r
COLLAPSE$edu <- list(
  "高中以下" = c("小學及以下", "國、初中"),
  "高中職"   = "高中、職",
  "專科以上" = c("專科", "大學及以上")
)
```

三條規則：

1. **沒提到的類別原樣保留**，所以 `list()` 等於完全不合併。
2. **要丟掉某些類別**，用特殊項 `.drop`：
   ```r
   COLLAPSE$age <- list("40歲以下" = c("20至29歲", "30至39歲"), .drop = "18至19歲")
   ```
   樣本端設為 NA，母體端整列移除後重新標準化。
3. **舊類別的名字要跟母體檔的 `label` 一字不差**。溫度計是用數字對齊，可以直接寫：
   ```r
   COLLAPSE$party_kmt <- list("討厭" = 0:4, "普通" = 5, "喜歡" = 6:10)
   ```

打錯字或對不上，程式會在對齊檢查停下來，並印出「樣本有母體沒有的類別」／「母體有但樣本 0 人的類別」。

---

## 6. OPTS：邊界情況

| 選項 | 可填 | 說明 |
|---|---|---|
| `sex_other_to_na` | `TRUE`/`FALSE` | 「其他」性別設為 NA，或保留成獨立類別 |
| `island_to_na` | `TRUE`/`FALSE` | 母體不含外島時，外島個案設為 NA 或保留 |
| `age_1819` | `"auto"`/`"keep"`/`"na"` | `auto` = 母體有 18-19 組就用、沒有就設 NA |
| `edu_auto_fallback` | `TRUE`/`FALSE` | 教育類別對不上時自動退到較粗的版本（A→B→C）|
| `ethnicity_dk` | `"na"`/`"other"` | 省籍的「不知道／不清楚／拒答」排除，或併進「其他」|
| `dedupe` | `"smart"`/`"first"`/`"none"` | 同一 id 重複時：`smart` = 回答一致才去重、不一致視為獨立樣本 |
| `therm_scale` | `"auto"`/`"asis"` | 偵測到 1–10 量表時自動平移成 0–9 |
| `therm_round` | `TRUE`/`FALSE` | 溫度計出現非整數（跨波 median/mean）時四捨五入 |

---

## 7. ANESRAKE 參數

```r
ANESRAKE <- list(cap = 5, choosemethod = "total", type = "pctlim",
                 pctlim = 0.05, nlim = 5, maxit = 1000, force1 = TRUE)
```

| 參數 | 意思 |
|---|---|
| `cap` | 單一權數上限（平均的幾倍）。調小 → 權數穩定但母體對得差；調大 → 對得準但少數個案主導 |
| `pctlim` | 納入門檻：樣本與母體總差距小於此值的變數就不 rake。設 `0` 表示全部都 rake |
| `type` | 挑變數的規則：`"pctlim"` / `"nolim"`（全部）/ `"nlim"` / `"both"` |
| `choosemethod` | 差距的算法：`"total"` / `"max"` / `"average"` |
| `nlim` | 搭配 `"nlim"`/`"both"`，最多納入幾個變數 |
| `maxit` | 迭代上限 |
| `force1` | 權數標準化成平均 1。做描述統計時建議維持 `TRUE` |

最常調的是 `cap` 和 `pctlim`。

anesrake 常出現 partial convergence 警告，那只表示迭代到後面改善幅度很小就停了，**不代表失敗**。真正該看的是診斷檔裡的「raking 後與母體的最大差距」。

---

## 8. 執行時會做什麼

```
[1] 讀樣本      依 SAMPLE_TYPE 讀檔；補值；處理重複 id；指派 caseid
[2] 對映        把原始值映到母體檔的類別標籤（臺/台 自動正規化）
[3] 讀母體      依 TARGET_FILES 各自讀入
[4] 合併        同一份 COLLAPSE 同時套用在母體與樣本
[5] 對齊檢查    兩邊類別必須一致，否則停下來並印出差異；印出各變數 NA 人數
[6] anesrake    只用 RAKE_VARS；任一變數缺值的個案排除
[7] 輸出        權數、分布表、分布圖、collapse 對比圖、診斷檔
```

輸出檔的意義見 [`../output/raking/README.md`](../output/raking/README.md)。

---

## 9. 常見錯誤

| 訊息 | 原因與處理 |
|---|---|
| `母體與樣本的類別對不齊` | 訊息會指出變數與類別。可能是 `COLLAPSE` 名稱打錯、這一波沒有這個變數，或母體沒有這個類別 |
| `教育程度有未對應的選項（設為 NA）` | 出現 `EDU_MAP` 沒收錄的用詞。零星幾人可略過；人數多就把用詞加進程式裡的 `EDU_MAP`（省籍同理，改 `ETH_MAP`）|
| `COLUMN_OVERRIDE 指定的欄位不存在` | 欄名要跟檔案完全一致，注意結尾空白 |
| `完整個案太少，無法 raking` | `RAKE_VARS` 放太多，或某變數缺值太嚴重。看畫面上各變數的 NA 比例 |
| `找不到母體檔` | 檢查 `TARGET_DIR` 與 `TARGET_FILES`，母體檔要先用 `Calculate_stat_population_from_TEDS/build_population_targets.R` 產生 |
