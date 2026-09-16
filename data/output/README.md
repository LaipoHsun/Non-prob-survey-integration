# data/output

```
output/
  portion_of_TEDS/   TEDS 的描述統計與「聯合分布表」（加權程式的母體來源）
  raking/            raking 的權數與報表
  multical/          multilevel calibration 的權數與報表
  papp_bart/         PAPP-BART 的權數與報表
```

每個檔案的欄位意義、以及各指標怎麼判讀，見 [`../code/README.md`](../code/README.md)（§7–§10）。

---

## portion_of_TEDS/

TEDS 調查資料的分配，一個資料夾一份 TEDS 資料（`2024_ind`、`2024_pan`、`2025`），另有 `pooled`（三份合併）。

**怎麼來的**

```bash
Rscript data/code/Calculate_stat_population_from_TEDS/portion_of_TEDS_party_feeling.R   # 邊際（表＋圖）
Rscript data/code/Calculate_stat_population_from_TEDS/portion_of_TEDS_demographics.R    # 邊際（表＋圖）
Rscript data/code/Calculate_stat_population_from_TEDS/joint_distribution_TEDS.R         # 聯合表
Rscript data/code/Calculate_stat_population_from_TEDS/pool_joint_TEDS.R                 # 合併版聯合表
```

資料源頭是 `data/TEDS/` 底下的 `.sav`（不上傳）。

**內容**

| 檔案 | 內容 |
|---|---|
| `fig_*.png`、`table_*.csv` / `.md` | 各變數的次數分配（描述統計，給人看的） |
| **`joint/joint_full_raw.csv`** | **聯合分布表**：一列一種變數組合（8 個變數），`n` = 人數、`n_wt` = TEDS 權數加總。**這是三種加權方法的母體來源** |
| `joint/pooled_sources.csv` | 只有 `pooled/` 有：各年份在合併母體中的佔比 |

`table_*.csv` 的數字與 `data/Input/population_targets/targets_teds_*.csv` 是同一組（`prop` = `pct_valid / 100`）。

---

## raking/、multical/、papp_bart/

三種方法的加權結果。**核心產物是 `weights_*.csv`**，一列一個受訪者，用 `memberId` 併回分析資料即可。

**怎麼來的**

```bash
Rscript data/code/raking_NTUWS.R           <樣本>
Rscript data/code/MultiCalibration_NTUWS.R <樣本> order=1
Rscript data/code/MultiCalibration_NTUWS.R <樣本> order=2
Rscript data/code/PAPP_BART_NTUWS.R        <樣本>
```

**資料夾結構**

raking 一個樣本只有一種結果，所以檔案直接放在樣本資料夾底下；multical 與 PAPP 同一個樣本可以有多種設定（order 1／2、trim／不 trim），**所以多一層子資料夾，名稱就是方法標籤**：

```
raking/<樣本>/                              weights_<樣本>.csv 等 17 檔
multical/<樣本>/mlcal_o1/                   weights_mlcal_o1_<樣本>.csv 等 23 檔
                mlcal_o2/                   多一張 frontier（λ 取捨曲線）
papp_bart/<樣本>/papp_bart_notrim/          weights_papp_bart_notrim_<樣本>.csv 等 20 檔
                 papp_bart_trimiqr5/
```

換設定（例如 `joint=pooled`）時標籤會自動加註（`mlcal_o2_jpooled`），不會蓋掉原本的結果。

**每個資料夾裡有什麼**

| 檔案 | 三種方法都有 | 意義 |
|---|---|---|
| `weights_*.csv` | ✓ | **權數**：`memberId`、`caseid`、`weight`（平均 1）、`excluded_reason` |
| `dist_*.csv` | ✓ | 母體／加權前／加權後的分布對照 |
| `diagnostics_*.txt` | ✓ | 執行紀錄與所有診斷指標 |
| `dist_*_<變數>.png` | ✓ | 上表的長條圖（repo 只保留代表性的一張） |
| `collapse_*_<變數>.png` | ✓ | 類別合併前後對比（repo 不上傳，內容與方法無關） |
| `analysis_*.csv` | multical、PAPP | 每個人合併後的類別（**含個人層資料，不上傳**） |
| `target_*.csv`、`coverage_*.csv`、`lambda_path_*.csv`、`balance_*` | multical | 聯合目標、支撐檢查、λ 路徑、各階交互平衡 |
| `frontier_*.png` | multical（order ≥ 2） | λ 取捨曲線 |
| `overlap_*.png`、`weights_*.png` | PAPP | 兩樣本 propensity 分布、權數直方圖 |

> repo 裡只放**代表性的圖**（教育的分布圖，加上各方法專有的診斷圖）。自己重跑會得到完整的圖檔。

---

## 重跑

```bash
rm -rf data/output/raking data/output/multical data/output/papp_bart
# 然後依 ../code/README.md §1 的四行指令，每個樣本各跑一次
```

`portion_of_TEDS/` 不用刪；只有 TEDS 資料更新時才需要重新產生，而且那需要 `data/TEDS/` 的原始檔。
