# Calculate_stat_population_from_TEDS

這一層的程式負責**從調查原始檔算出邊際分配**，產出兩種東西：

1. **母體目標檔** —— 給 `../raking_NTUWS.R` 當 raking 的目標用
2. **描述統計的表與圖** —— 給人看的次數分配

這邊的Code執行完後會有TEDS的面訪資料的變數的邊際分布 在ranking的做法裡面被視為母體分佈
---

## 檔案

| 程式 | 做什麼 |
|---|---|
| `build_population_targets.R` | 產生母體目標檔 |
| `portion_of_TEDS_party_feeling.R` | 政黨情感溫度計的次數分配（表＋圖）|
| `portion_of_TEDS_demographics.R` | 人口學變數的次數分配（表＋圖）|

```bash
cd "<專案根目錄>"
Rscript data/code/Calculate_stat_population_from_TEDS/build_population_targets.R
Rscript data/code/Calculate_stat_population_from_TEDS/portion_of_TEDS_party_feeling.R
Rscript data/code/Calculate_stat_population_from_TEDS/portion_of_TEDS_demographics.R
```

三支都會自己往上找專案根目錄（判斷依據是找得到 `data/TEDS`），所以在哪個目錄執行都可以。

---

## 1. build_population_targets.R

### 去哪裡抓資料

| 抓什麼 | 從哪裡 |
|---|---|
| 官方人口數 | 調查的 `.sps` 語法檔裡 `NPAR TEST/CHI <var>(a,b)/EXP=n1,n2,...` 這幾行 |
| 樣本邊際分配 | 對應的 `.sav` 資料檔，直接數次數 |
| 類別名稱 | `.sav` 的 value label（確保與樣本端對得起來）|

### 會產生什麼

輸出到 `data/Input/population_targets/targets_<來源>.csv`，一列一個類別：

| 欄位 | 內容 |
|---|---|
| `source` | 來源代號 |
| `variable` | 內部變數名（`sex` `age` `edu` `arear` `city` `ethnicity` `party_kmt` `party_dpp` `party_tpp`）|
| `var` | 在原始檔裡的變數名 |
| `code` | 原始編碼 |
| `label` | 類別名稱 |
| `N` | 個數（官方人口數是真實人口；樣本分配是受訪人數）|
| `prop` | 佔比，同一 `variable` 內加總為 1 |

兩種來源：

- **`census_*`** —— 解析 `.sps` 得到的官方人口數。只有 `.sps` 裡有寫的那些變數（通常是性別、年齡、教育、區域）。
- **`teds_*`** —— 從 `.sav` 直接數的樣本分配。所有登記的變數都有，供沒有官方人口數的變數使用。

### 會記錄什麼

- 執行時逐一印出每個來源寫出了哪些變數
- 找不到 `NPAR TEST/CHI` 行的來源會發出警告並跳過，不會中斷
- `.sps` 的 `EXP=` 個數與 code 範圍不符時直接報錯（避免默默對錯類別）
- 依 value label 判定並**排除**「拒答／不知道／無意見／看情形／跳題／無反應／沒聽過／遺漏值」，這些不會出現在母體目標裡

### 要換一份資料時

在程式最上面的 `teds` 清單加一筆，或改掉現有的：

```r
teds <- list(
  "我的資料" = list(
    sav  = file.path(teds_dir, "路徑/檔名.sav"),
    enc  = "UTF-8",              # 或 "CP950"，讀不出中文就換另一個
    sps  = file.path(teds_dir, "路徑/檔名.sps"),   # 沒有官方人口數就填 NA
    vars = c(sex = "你的性別欄", age = "你的年齡欄", edu = "你的教育欄",
             arear = "你的區域欄", city = "你的縣市欄",
             ethnicity = "你的省籍欄",
             party_kmt = "國民黨溫度計欄", party_dpp = "民進黨溫度計欄",
             party_tpp = "民眾黨溫度計欄"))
)
```

要完全換掉來源（不是 SPSS 檔）時，只要自己做一個上表格式的 CSV 放進 `data/Input/population_targets/`，raking 那一層就吃得到，不必動這支程式。

---

## 2. portion_of_TEDS_party_feeling.R

### 會產生什麼

輸出到 `data/output/portion_of_TEDS/<tag>/`：

| 檔案 | 內容 |
|---|---|
| `fig_party_feeling.png` | 三個政黨畫在同一張圖，x 軸 0–10，長條上標 n |
| `table_party_feeling.csv` | 長格式次數分配 |
| `table_party_feeling.md` | 同上，加上平均數／標準差／中位數的可讀版本 |

表的欄位：`dataset, year, party, var, value, label, n, pct_all, pct_valid, cum_pct_valid`

### 會記錄什麼

- `pct_all` 的分母是「有作答此題的人」（含拒答／不知道）
- `pct_valid` 的分母只有 0–10 的實質作答
- 拒答／沒聽過／不知道各自單獨一列，n 看得到
- 表尾另有「總計」與「未受訪／系統遺漏」兩列，後者不計入任何分母
- 全部未加權

### 要換一份資料時

改 `datasets` 清單：

```r
datasets <- list(
  list(tag = "輸出資料夾名", title = "圖表標題", year = 2024,
       file = file.path(teds_dir, "路徑/檔名.sav"), enc = "CP950",
       vars = c("國民黨" = "欄名A", "民進黨" = "欄名B", "台灣民眾黨" = "欄名C"))
)
```

`vars` 左邊是圖例上要顯示的名稱，右邊是檔案裡的欄名。政黨數量可以不是三個，`party_levels` 和 `party_cols` 跟著改就好。

---

## 3. portion_of_TEDS_demographics.R

### 去哪裡抓資料

同樣是最上面的 `datasets` 清單，`vars` 改成五個人口學變數的欄名對照。

### 會產生什麼

輸出到 `data/output/portion_of_TEDS/<tag>/`：

| 檔案 | 內容 |
|---|---|
| `fig_sex.png` `fig_age.png` `fig_edu.png` `fig_ethnicity.png` `fig_city.png` | 每個變數一張長條圖，標上 n 與百分比；縣市因類別多改為橫向並依比例排序 |
| `table_demographics.csv` | 五個變數的長格式次數分配疊在一起 |
| `table_demographics.md` | 同上的可讀版本，含資料集特性註記 |

表的欄位：`dataset, year, variable, var, value, label, n, pct_all, pct_valid, cum_pct_valid`

### 會記錄什麼

- 「非實質回答」是**依 value label 判定**（拒答／不知道／無意見／看情形／跳題／無反應／沒聽過），不是寫死代碼，所以各年編碼不同也不會漏
- `pct_valid` 的分母排除這些；`pct_all` 的分母包含
- 表尾同樣有「總計」與「未受訪／系統遺漏」兩列
- 全部未加權

### 要換一份資料時

```r
demo_vars <- c(sex = "性別", age = "年齡", edu = "教育程度",
               ethnicity = "省籍（父親）", city = "居住縣市")   # 顯示名稱

datasets <- list(
  list(tag = "輸出資料夾名", title = "圖表標題", year = 2024,
       file = file.path(teds_dir, "路徑/檔名.sav"), enc = "CP950",
       vars = c(sex = "欄名", age = "欄名", edu = "欄名",
                ethnicity = "欄名", city = "欄名"))
)
```

變數要增減就同時改 `demo_vars` 與各筆的 `vars`，兩邊的鍵要一致。圖檔名會用鍵（`fig_<鍵>.png`）。

---

## 注意

- 這三支都**只讀不寫**原始資料檔。
- 中文在 `Rscript` 的預設 C locale 下會被丟掉，所以每支開頭都會設定 UTF-8 locale。不要移除那幾行。
- 圖用 `Heiti TC` 字型（macOS 內建）。換作業系統要改 `base_family`。
