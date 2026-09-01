# data/output
```
output/
  portion_of_TEDS/   TEDS 各變數的描述統計
  raking/            對樣本做 raking 之後的權數與圖片可供參考
```

---

## portion_of_TEDS/

TEDS 調查資料的邊際分配，給人看的表與圖。

**怎麼來的**

```bash
Rscript data/code/Calculate_stat_population_from_TEDS/portion_of_TEDS_party_feeling.R
Rscript data/code/Calculate_stat_population_from_TEDS/portion_of_TEDS_demographics.R
```
可得TEDS問卷資料裡所得到的variable的邊際分布 如情感溫度計, 性別 bla bla bla
資料源頭是 `data/TEDS/` 底下的 `.sav` 檔。

**內容**
每個資料夾的名稱會被設定為所採用的TEDS面訪資料夾的資料名稱 如2025就是TEDS 2025的面訪資料
而每個資料夾裡都有以下的內容：

| 檔案 | 內容 |
|---|---|
| `fig_party_feeling.png` | 三個政黨的情感溫度計（0–10）畫在同一張圖 |
| `table_party_feeling.csv` / `.md` | 上圖的次數分配表 |
| `fig_sex.png` `fig_age.png` `fig_edu.png` `fig_ethnicity.png` `fig_city.png` | 五個人口學變數各一張 |
| `table_demographics.csv` / `.md` | 五個人口學變數的次數分配表 |

表裡的 `n` 是實際人數，`pct_all` 的分母含拒答／不知道，`pct_valid` 的分母只有實質作答。

這個資料夾的數字與 `data/Input/population_targets/targets_teds_*.csv` 是同一組（`prop` 等於 `pct_valid / 100`）。
這邊的圖做法與內容實作細節請參考 `data/code/Calculate_stat_population_from_TEDS/README.md` 
---

## raking/

對調查樣本做 raking 的結果。

**怎麼來的**

```bash
Rscript data/code/raking_NTUWS.R <樣本名稱>
```

輸入是 `data/Input/`（母體目標＋樣本）與 NTUWS 的逐波原始檔。每跑一次會在底下建一個以樣本命名的資料夾。

**內容**

一個樣本一個資料夾，裡面的檔案意義見 [`raking/README.md`](raking/README.md)。

---

## 重跑

全部重來：

```bash
rm -rf data/output/portion_of_TEDS data/output/raking
```

然後依序執行 `data/code/Calculate_stat_population_from_TEDS/` 底下的兩支 `portion_of_TEDS_*.R`，以及 `data/code/raking_NTUWS.R`。
