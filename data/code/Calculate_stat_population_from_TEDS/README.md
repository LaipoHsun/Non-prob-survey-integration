# Calculate_stat_population_from_TEDS

這一層的程式**從 TEDS 原始檔算出母體**，給 `../raking_NTUWS.R`、`../MultiCalibration_NTUWS.R`、`../PAPP_BART_NTUWS.R` 三支加權程式使用。產出三種東西：

1. **聯合分布表**（`joint_full_raw.csv`）—— 一列一種變數組合。**三種加權方法的預設母體**
2. **邊際目標檔**（`targets_*.csv`）—— 一列一個類別，只用來決定「有哪些類別」
3. **描述統計** —— 次數分配的表與圖，給人看的

---

## 檔案

| 程式 | 做什麼 | 輸出 |
|---|---|---|
| `joint_distribution_TEDS.R` | 8 個變數的**聯合分布** | `data/output/portion_of_TEDS/<年份>/joint/` |
| `pool_joint_TEDS.R` | 把多個年份的聯合表**合併成一份** | `data/output/portion_of_TEDS/pooled/joint/` |
| `build_population_targets.R` | 邊際目標檔 | `data/Input/population_targets/` |
| `portion_of_TEDS_party_feeling.R` | 政黨情感溫度計的次數分配（表＋圖） | `data/output/portion_of_TEDS/<年份>/` |
| `portion_of_TEDS_demographics.R` | 人口學變數的次數分配（表＋圖） | 同上 |

```bash
cd "<專案根目錄>"
Rscript data/code/Calculate_stat_population_from_TEDS/joint_distribution_TEDS.R
Rscript data/code/Calculate_stat_population_from_TEDS/pool_joint_TEDS.R          # 要先跑上一行
Rscript data/code/Calculate_stat_population_from_TEDS/build_population_targets.R
Rscript data/code/Calculate_stat_population_from_TEDS/portion_of_TEDS_party_feeling.R
Rscript data/code/Calculate_stat_population_from_TEDS/portion_of_TEDS_demographics.R
```

每支都會自己往上找專案根目錄，在哪個目錄執行都可以。**都需要 `data/TEDS/` 底下的 `.sav` 原始檔**（不上傳），所以只有 TEDS 資料更新時才需要重跑——repo 裡已經有算好的聯合表與目標檔。

---

## 1. joint_distribution_TEDS.R —— 聯合分布表

### 為什麼需要

傳統 raking 只要每個變數各自的邊際。但 multilevel calibration 要平衡**變數之間的組合**，PAPP-BART 要**個人層的參考樣本**，兩者都需要更細的母體資訊。聯合表就是這份資訊。

### 輸出

`data/output/portion_of_TEDS/<年份>/joint/`：

| 檔案 | 內容 |
|---|---|
| **`joint_full_raw.csv`** | **8 個變數的完整聯合表**（溫度計保持 0–10 原始尺度）。加權程式讀的就是這個 |
| `joint_therm3.csv` | 溫度計先分成 3 類的版本 |
| `joint_demo5.csv` | 只有 5 個人口學變數的版本 |
| `pairwise_assoc.csv`、`pairwise_tables.csv` | 兩兩變數的關聯（Cramér's V）與列聯表 |
| `sparsity_report.md` | 稀疏度報告：理論格數、實際佔用格數、TVD 與隨機打亂的對照 |

`joint_full_raw.csv` 的欄位：

```
sex, age, edu, arear, ethnicity, party_kmt, party_dpp, party_tpp,
n,        該組合的人數（未加權）
n_wt,     該組合的 TEDS 權數加總  ← 加權程式預設用這欄
prop, prop_wt, cell
```

**只列出實際出現過的組合**，沒出現的組合不會有列（母體裡不存在的格不列入）。

### 資料設定

程式最上面的 `datasets` 指定每個年份的 `.sav` 路徑與變數對應（例如 2025 的省籍是 `H2a`、2024 獨立樣本是 `Q2`）。要加新年份就在那裡加一組。非實質回答（拒答、不知道、跳題等）一律轉成 NA。

---

## 2. pool_joint_TEDS.R —— 合併多個年份

```r
SOURCES     <- c("2024_ind", "2024_pan", "2025")
OUT_NAME    <- "pooled"
WEIGHT_MODE <- "as_is"     # "as_is" / "equal"
LABEL_MAP   <- list(arear = c("高屏澎湖區" = "高屏區", "花東外島區" = "花東區"))
```

- **標籤統一**：2024 與 2025 的區域用詞不同，合併時統一成 2025 的用詞。
- **權數**：各年份的 W 平均約為 1。`as_is` 直接相加，各年份佔比 ∝ 樣本數（目前 20.0% / 32.7% / 47.3%）；`equal` 則先把每年的 `n_wt` 調成相同總和。
- 輸出 `pooled/joint/joint_full_raw.csv`（多一欄 `n_sources`：這個組合出現在幾個年份）與 `pooled_sources.csv`。

**注意**：各年份是不同時間點的調查，合併等於假設這段期間母體結構沒有明顯變化；三個年份的 W 建構方式也不同。合併後格子更多、更細，但 NTUWS 沒有對應的格子也會變多。

加權程式用 `joint=pooled` 切換到合併版。

---

## 3. build_population_targets.R —— 邊際目標檔

### 去哪裡抓資料

| 抓什麼 | 從哪裡 |
|---|---|
| 官方人口數 | 調查的 `.sps` 語法檔裡 `NPAR TEST/CHI <var>(a,b)/EXP=n1,n2,...` 這幾行 |
| 樣本邊際分配 | 對應的 `.sav`，直接數次數 |
| 類別名稱 | `.sav` 的 value label（確保與樣本端對得起來） |

### 輸出

`data/Input/population_targets/`，欄位 `source, variable, var, code, label, N, prop`：

- `targets_census_*.csv` —— **官方人口數**，只涵蓋性別／年齡／教育／區域
- `targets_teds_*.csv` —— **TEDS 樣本本身的分配**，涵蓋全部變數（省籍、政黨溫度計沒有官方人口數）

加權程式在 `TARGET_SOURCE = "joint"`（預設）時，這些檔**只用來決定有哪些類別**，比例來自聯合表；`TARGET_SOURCE = "files"` 時才用它們的比例。

---

## 4. 描述統計

`portion_of_TEDS_party_feeling.R` 與 `portion_of_TEDS_demographics.R` 產生次數分配的表與圖，放在 `data/output/portion_of_TEDS/<年份>/`。這兩支和加權流程無關，是給人看的。

表裡的 `n` 是實際人數，`pct_all` 的分母含拒答／不知道，`pct_valid` 的分母只有實質作答。
