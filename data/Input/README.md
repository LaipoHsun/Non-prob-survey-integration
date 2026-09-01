# data/Input

執行 `data/code/raking_NTUWS.R` 所需要的資料都放在這裡。

```
Input/
  population_targets/   raking 的「母體目標」
  NTUWS_pooled/         個人層彙整的樣本資料 要用到member版本的時候再用
```

---

## population_targets/

raking 要把樣本拉向的那組分配，也就是**母體**。

由 `data/code/Calculate_stat_population_from_TEDS/build_population_targets.R` 產生，資料源頭是 `data/TEDS/` 底下的調查檔（`.sav` 資料檔與 `.sps` 語法檔）。TEDS 資料更新時才需要重跑。

每個檔案都是同一種格式，一列一個類別：

| 欄位 | 內容 |
|---|---|
| `source` | 來源代號 |
| `variable` | 變數（`sex` `age` `edu` `arear` `city` `ethnicity` `party_kmt` `party_dpp` `party_tpp`）|
| `var` | 在原始檔裡的變數名 |
| `code` | 原始編碼 |
| `label` | 類別名稱 |
| `N` | 個數 |
| `prop` | 佔比，同一 `variable` 內加總為 1 |

檔案分兩類：

- **`targets_census_*.csv`** —— 官方人口數（真實人口，百萬級），來自 `.sps` 語法檔裡登記的加權母體。只涵蓋性別、年齡、教育、區域。
- **`targets_teds_*.csv`** —— TEDS 樣本本身的邊際分配（`N` 是受訪人數）。涵蓋全部變數，供省籍、政黨溫度計這類沒有官方人口數的變數使用。

已排除拒答／不知道／無反應等非實質回答。

### 要換自己的母體

做一個同格式的 CSV 丟進這個資料夾（`variable`、`label`、`N` 三欄是必要的；`arear` 另外會用到 `code`），然後在 `raking_NTUWS.R` 的 `TARGET_FILES` 指到它。每個變數可以各自指定不同的檔，不必都用同一份。

---

## NTUWS_pooled/

已經跨波整併過的個人層樣本資料，供 `raking_NTUWS.R` 的 `SAMPLE_TYPE = "member"` 模式使用。
這邊的資料都是一開始假設 time variant把年份內的NTUWS內容組合出來的各個ID的人綜合出來的demographic and party
| 檔案 | 內容 |
|---|---|
| `ntuws_member_demographics.csv` | 一列一位成員，含性別、出生年、教育程度、父親省籍、居住縣市。鍵為 `memberId` |
| `ntuws_party_thermometer_resolved.xlsx` | 「總表」分頁，一列一個 `out_id`，含三個政黨溫度計的跨波 `_mean` / `_median`。`split_from` 對回 `memberId` |

這兩個檔是從 `data/NTUWS/output/` 底下的 Phase0／Phase2 產物複製過來的。上游重跑後記得同步更新這裡的副本。

---

## ⚠️ 不在這裡、但要記得放的東西

**NTUWS 最原始的逐波問卷檔 `lottery_repeated_raw_by_wave.xlsx` 不在 Input 裡。**

`raking_NTUWS.R` 的 `SAMPLE_TYPE = "wave"` 模式需要它，預設路徑是：

```
data/NTUWS/raw_data/lottery_repeated_raw_by_wave.xlsx
```

拿到這個專案之後，請改 `raking_NTUWS.R` 的 `SAMPLE_FILE` 指過去即可。**沒有這個檔，只有 `member` 模式跑得動。**

---

## 這個資料夾的東西不要手動改

`population_targets/` 是程式產生的，手改會在下次重跑時被覆蓋。要調整分類方式，請改 `raking_NTUWS.R` 的 `COLLAPSE` 設定——母體與樣本會同步套用，比手改檔案安全。
