# Phase 2 — 跨波題目配對與個體回答收斂

最後更新：2026-08-24　｜　**總覽（含 output 的完整說明）見 [`../../PHASE2_README.md`](../../PHASE2_README.md)**

Phase 2 要解決的問題：**同一個概念的題目散在 17 個波次裡，欄位名稱、題幹措辭、
量尺都不一樣**（`LS_2306` 叫 `Q33`、`LS_2310` 叫 `b1_1`、`LS_2410_1` 叫 `Q1__dup1`，
問的卻是同一件事）。要做跨期分析，得先把它們認出來、對起來，再把同一個
`memberId` 的跨波回答收斂成可用的值。

分兩層：

1. **配對**（全域，做一次）——`build_question_catalog.R` 把所有欄位歸類成 category。
2. **收斂**（分批，一批一個子資料夾）——每一批相近的 category 各自處理。
   目前完成的是 `party_thermometer/`（政黨喜愛三黨）。

工作規則（下一批要怎麼開、命名怎麼取、要有哪些檢查）寫在 [`AGENTS.md`](AGENTS.md)。
這份 README 講的是**已經做了什麼、套了什麼規則**。

---

## 資料流

```
output/Phase1_within_wave_duplicates/ntuws_lottery_dedup.xlsx   （波次內已去重）
        │
        │  build_question_catalog.R          267 欄逐欄歸類
        ▼
output/Phase2_cross_wave_question_matching/ntuws_question_catalog.xlsx
        │                                    18 個 category，人工核對過
        │  party_thermometer/build_party_thermometer.R
        ▼                                    依 catalog 取值、合併量尺、組寬表
   party_thermometer/ntuws_party_thermometer.xlsx
        │
        ├─ plot_party_thermometer_ecdf.R     兩張 ECDF 診斷圖
        │      ntuws_party_thermometer_ecdf_{sd,range}.png
        │
        └─ resolve_party_thermometer_ids.R   依穩定度收斂成代表值、不穩的拆 ID
               ntuws_party_thermometer_resolved.xlsx   總表
               ntuws_party_thermometer_review.xlsx     待人工判斷的 case
```

四支程式**工作目錄在哪都可以**，各自從所在位置往上找 NTUWS 根資料夾，
全程絕對路徑、不呼叫 `setwd()`。`LC_ALL=zh_TW.UTF-8` **不能省**，
否則 `writexl` 會把中文寫成空白（程式開頭會擋下來）。

```bash
LC_ALL=zh_TW.UTF-8 Rscript data/NTUWS/Code/Phase2_cross_wave_question_matching/build_question_catalog.R
LC_ALL=zh_TW.UTF-8 Rscript data/NTUWS/Code/Phase2_cross_wave_question_matching/party_thermometer/build_party_thermometer.R
LC_ALL=zh_TW.UTF-8 Rscript data/NTUWS/Code/Phase2_cross_wave_question_matching/party_thermometer/plot_party_thermometer_ecdf.R
LC_ALL=zh_TW.UTF-8 Rscript data/NTUWS/Code/Phase2_cross_wave_question_matching/party_thermometer/resolve_party_thermometer_ids.R
```

---

## 1. `build_question_catalog.R` — 把 267 個欄位歸類成 18 個 category

**做什麼**：掃 `ntuws_lottery_dedup.xlsx` 的每一個欄位，判斷它問的是哪一個概念，
產出一份「一個 category 一個 sheet」的對照活頁簿供人工核對。

**產出**：`output/Phase2_cross_wave_question_matching/ntuws_question_catalog.xlsx`（21 sheet）

### 套用的規則

**掃描範圍**：18 個 sheet 跳過 4 個 —— `Welcome`（名冊）與 `LS_2210` / `LS_24NY` /
`LS_25NY`（這三波只有 demographic，沒有政治題），實掃 14 波。

**歸類依據是第 2 列的題目文字，不是變項名。** 變項名跨波完全對不起來，
題目文字每一波都有實質內容。比對前先正規化：換行、全形空白、重複空白都拿掉
（原始題幹被 PDF 斷行汙染過，例如「有 時候」中間多一個空白）。

**判定順序**（由上往下，先攔先贏）：

| 順序 | 判定 | 為什麼要排這個位置 |
|---|---|---|
| 0 | `memberId`、`weight` | 排除 |
| 1 | 情感極化電池（對象 × 政黨） | 先攔，因為它同時含「政黨」字樣 |
| 2 | 0–10 政黨好感度 | 再攔，因為它含「泛藍政黨／泛綠政黨」 |
| 3 | demographic | 排除 |
| 4 | 陣營（泛藍／泛綠）主問與追問 | |
| 5 | 政黨認同主問與追問 | |
| — | 都沒中 | 進 `_UNMATCHED`，程式以非零碼結束 |

**排除的欄**：`memberId`(14)、`weight`(14)、demographic(49)。demographic 認的是
性別／年齡／歲數／出生／民國幾年／學歷／教育程度／籍貫／省籍／族群／縣市／地區／
郵遞區號／戶籍地，另加「本省客家人」「本省閩南」「新住民」——`LS_2405` 與
`LS_2410_*` 的父親籍貫題整句都是選項名稱，沒有「籍貫」二字。

**量尺措辭不併進 category，另存 `scale_wording` 欄。** category 只切到「概念 × 標的」，
措辭差異留給人工決定要不要拆。依據是 `QUESTION_INVENTORY.md` 的 D3：情感電池的
「不舒服」與「感覺／感受」測的不是同一個東西。

**填答選項只列出現過的值，不做統計。** 全數值的欄依數值排序，其餘依字典序，
超過 60 種只列前 60 種並在 `n_options` 標明實際種數。

**檢查**：掃描欄數必須等於「已歸類 + 已排除 + 未歸類」，且 `_UNMATCHED` 為空。

### 結果

267 欄全部有歸宿：**190 欄歸進 18 個 category、77 欄明確排除、0 欄漏接**。

| category | 波數 | 缺哪幾波 |
|---|---|---|
| `陣營認同_泛藍泛綠`、`0~10_政黨喜愛_國民黨`、`0~10_政黨喜愛_民進黨` | 14 | — |
| `0~10_政黨喜愛_民眾黨` | 13 | `LS_2306` 只問兩黨 |
| `政黨認同_主問` | 13 | `LS_2303` 沒問 |
| `情感極化_{朋友,鄰居,家人}×{國民黨,民進黨,民眾黨}` 共 9 個 | 11 | 只有 11 波有情感電池 |
| └ 例外 `情感極化_鄰居_國民黨` | 10 | `LS_2305` 原始檔就少這一欄 |
| `政黨認同_追問`、`陣營認同_追問` | 8 | 只有 2024-05 之後有追問 |
| `0~10_政黨喜愛_泛藍政黨`、`_泛綠政黨` | 4 | 只有 2405 / 2408 / 2410_1 / 2410_2 問了 |

數字與 `QUESTION_INVENTORY.md` 的題組 × 波次對照表完全一致。
細節另見 [`../../PHASE2_QUESTION_CATALOG.md`](../../PHASE2_QUESTION_CATALOG.md)。

---

## 2. `party_thermometer/build_party_thermometer.R` — 政黨喜愛的跨波寬表

**做什麼**：依 catalog 取出三個政黨喜愛 category 在各波的那一欄，把量尺合併成
統一的 0–10，組成「一列一個 memberId、一波一欄」的寬表。

**處理的 category**：`0~10_政黨喜愛_國民黨`(14 波)、`_民進黨`(14 波)、`_民眾黨`(13 波)

**產出**：`party_thermometer/ntuws_party_thermometer.xlsx`（10 sheet）

### 套用的合併規則

值域統一為 **0–10 整數**。

| # | 波次 | 做法 |
|---|---|---|
| 1 | 除 `LS_2310` 外的 13 波 | **原樣採用，不做任何縮放。**`LS_2211` 題幹雖寫「1 到 10」，但資料實際是 0–10，以資料為準 |
| 2 | `LS_2303` | 值帶端點文字（`0（非常厭惡）`、`10（非常喜愛）`），**剝除括號後的文字只留數字**。這是解析不是換算 |
| 3 | `LS_2310` | 實際值域是 1–10（沒有 0）。**不做線性重縮放**，改成逐人判定那個「1」是不是別波的「0」（見下） |
| 4 | `LS_2410_1` / `LS_2410_2` | 雖然同為 2024-10，**兩欄並存不合併**。有 185 人兩波都答，那是現成的 test-retest 資料 |

**`LS_2310` 的「1」逐人判定**：對每一個在 `LS_2310` 填 1 的人，看他在**同一個
category** 其他波的值 ——

| 其他波的情況 | branch | 結果 |
|---|---|---|
| 0 比 1 多 | `to_0` | 改成 **0** |
| 1 比 0 多 | `keep_1_majority` | 維持 1 |
| 0 與 1 一樣多且都出現過 | `keep_1_tie` | 維持 1 |
| 既沒 0 也沒 1 | `keep_1_no_evidence` | 維持 1 |
| 沒有其他波可對照 | `keep_1_single_wave` | 維持 1 |

只有在「其他波多數填 0」這種**正面證據**下才改，其餘一律維持原值。
`LS_2310` 的 2–10 全部不動。實際改掉 **433 筆**（國 160 / 民進 206 / 民眾 67），
維持 1 的 939 筆裡有 685 筆是「只答過這一波無從對照」。
逐筆紀錄在 `_2310_ONE_RULE`，要翻哪一支改程式裡的
`RULE_2310_KEEP_ON_TIE` / `_NO_EVIDENCE` / `_SINGLE_WAVE` 三個常數。

### 其他規則

- **該波沒答就是 NA**，包含「這個人那一波沒參與」與「那一波沒問這題」兩種，
  靠 `_COVERAGE` sheet 分辨。
- **`mean` / `sd` 只用有答的波算**；`n_answered == 1` 的 `sd` 是 `NA`，不填 0。
- **值域檢查**：轉換後有值落在 0–10 外就中止。
- **無法轉換的值不會靜靜變成 NA**，會進 `_UNCONVERTED`（目前是 0 筆）。
- **對帳**：原始作答數 = 進入寬表的格數 + 無法轉換數，對不上就中止。
- **偏離標記**：算每個 ID 的平均，任一筆與平均差超過 ±1 就標記，寫進
  `_DEVIATION_BY_ID` 供人工判斷。**這一支不拆任何 ID。**
- 原始字串寬表 `_RAW_<標的>` 預設不產（`KEEP_RAW_SHEETS = FALSE`），
  要回頭核對合併時改 `TRUE` 重跑。

### 結果

| category | 波數 | ID 數 | 作答數 | 只答 1 波 |
|---|---|---|---|---|
| 國民黨 | 14 | 13,248 | 29,579 | 6,360 |
| 民進黨 | 14 | 13,248 | 29,579 | 6,360 |
| 民眾黨 | 13 | 11,841 | 26,103 | 5,815 |

對帳：85,261 = 85,261 + 0。

**整體分布**（`_STATS_OVERALL`）：國民黨 3.54±2.33、民進黨 3.78±2.56、
民眾黨 4.02±2.42，三黨都低於量尺中點 5。

**個體 sd 的平均與標準差**（每個 ID 自己跨波的 sd，再拿這些 sd 算平均與標準差）：

| category | 有 sd 的 ID | 個體 sd 的平均 | 個體 sd 的標準差 | 中位數 | P90 |
|---|---|---|---|---|---|
| 國民黨 | 6,888 | 1.100 | 0.952 | 0.894 | 2.29 |
| 民進黨 | 6,888 | 1.103 | 0.989 | 0.837 | 2.36 |
| 民眾黨 | 6,026 | 1.174 | 0.992 | 1.000 | 2.50 |

同一個人跨波的波動（sd≈1.1）大約是人際差異（sd≈2.2）的一半。
分布右偏：多數人相當穩，平均被少數極不穩的人拉高。

---

## 3. `party_thermometer/plot_party_thermometer_ecdf.R` — 兩張診斷圖

**做什麼**：讀上一步的寬表，取**答過兩波以上**的人，把個體的跨波 `sd` 與
跨波全距各畫一張累積分布函數，三黨疊在同一張比較，標出 90% 與 95% 分位。
純診斷，不動任何資料。

**產出**：`ntuws_party_thermometer_ecdf_sd.png`、`ntuws_party_thermometer_ecdf_range.png`

### 套用的規則

- **只取 `n_answered >= 2`**。只答一波的人沒有 sd 也沒有全距，畫進去只會把曲線往 0 拉。
- **`sd` 直接取寬表的欄，`range` 由波次欄現算**（寬表沒有 range 欄），
  兩張圖用的是同一份已合併的值。
- **分位數用 `type = 1`**：取「累積機率首次達到 p 的實際觀測值」，
  與階梯圖的落點一致；預設的插值型分位數會標在階梯之間，圖上對不起來。
- 三黨的分位值幾乎重疊，所以數值收進帶顏色的小表，顏色本身當圖例。
- 中文字型用 macOS 的 Heiti TC，找不到就整張圖退回英文標籤，不變成豆腐方框。

### 結果

| | 國民黨 P90 / P95 | 民進黨 P90 / P95 | 民眾黨 P90 / P95 |
|---|---|---|---|
| 個體跨波 sd | 2.29 / 2.83 | 2.36 / 2.83 | 2.50 / 2.89 |
| 個體跨波全距 | 5 / 5 | 5 / 5 | 5 / 6 |

sd 圖左端起跳點約 20%——五分之一的人每一波都填同一個數字。
全距 ≤2 的人累積已接近 67%，全距 ≥5 的只剩約 10%。

---

## 4. `party_thermometer/resolve_party_thermometer_ids.R` — 收斂成代表值、拆不穩的 ID

**做什麼**：依「這個人的跨波回答穩不穩」決定他在每個 category 的代表值。
穩的取平均與中位數，不穩的拆成兩個 ID，判不出來的丟出來人工看。

**產出**：
- `ntuws_party_thermometer_resolved.xlsx` — 總表，單一 page，一列一個 ID
- `ntuws_party_thermometer_review.xlsx` — 三個 page，全部 `sd > 2.5` 的人供肉眼判斷

### 套用的收斂規則

**逐 category 各自判定。** 同一個人可能在國民黨被拆、在民進黨完全正常。

| 條件 | rule | 做法 |
|---|---|---|
| `n_answered == 1` | `single_wave` | mean = median = 該值 |
| `sd <= 2.5` | `stable` | mean、median 照全部波算，**ID 不拆**。⚠️ sd 恰好 = 2.5 歸在這裡（52 人） |
| `sd > 2.5` 且不同值**只有 2 種** | `split_2values` | 拆兩列：**小值 → 原 ID**、**大值 → 原 ID-1** |
| `sd > 2.5` 且不同值 **≥ 3 種**，通過 regime 判定 | `split_regime` | 拆兩列：**切點前段 → 原 ID**、**後段 → 原 ID-1** |
| 以上皆非 | `excluded` | **不進總表**（該 category 五欄留 NA），只出現在檔二 |

拆出來的每一段，**mean 與 median 都按該段重新算**。規則 1 的段內都是同一個值，
所以兩欄相同；規則 2 的段內若有多筆就照算。

⚠️ **兩條拆分規則的方向不同，這是刻意的**：

- 規則 1 按**值的大小**拆 —— 所以原 ID 那一段有可能是比較晚的波次。
  例：`LS_2211=10 | LS_23NY=0` → `原ID=0（LS_23NY）`、`原ID-1=10（LS_2211）`。
- 規則 2 按**時間先後**拆 —— 前段永遠是原 ID。

之後接 demographic 或做時序分析時要記得這件事。

### regime 判定：單切點 + 段內一致

把該人的作答按調查月份由早到晚排（同月的 `LS_2410_1` / `_2` 依名稱），
逐一嘗試每個切點把序列切成前後兩段（兩段都至少 1 筆），
取「兩段組內平方和最小」的切點（平手取最早的）。成立條件**兩個都要過**：

```
|前段平均 − 後段平均|  >=  4     （REGIME_MEAN_GAP）
每一段內部的全距        <=  2     （REGIME_SEG_RANGE）
```

前者要求真的有階梯，後者要求階梯兩側各自穩定。少了後者，
「前段 9,2,8 後段 1,0」這種中間亂跳的也會被當成 regime shift。

判定的中間值（`cut_point` / `seg1_mean` / `seg2_mean` / `seg1_range` /
`seg2_range` / `regime_ok`）全部寫進檔二，所以沒過的人**為什麼沒過**一眼看得出來。

### 總表的形狀

單一 page，一列一個 `out_id`，欄位是
`out_id / split_from / is_split / split_in` + 三黨各五欄
（`<黨>_mean` `<黨>_median` `<黨>_rule` `<黨>_n` `<黨>_waves`）。

某人只在國民黨被拆時：

| out_id | split_in | 國民黨_mean | 國民黨_rule | 民進黨_mean | 民進黨_rule | 民眾黨_mean |
|---|---|---|---|---|---|---|
| `01a926e9…` | 國民黨 | 1 | split_2values | 5 | stable | 9 |
| `01a926e9…-1` | 國民黨 | 7 | split_2values | NA | NA | NA |

- 原 ID 那一列三黨都有值（沒被拆的 category 用它們各自的結果）
- `原ID-1` 那一列**只有拆它的那個 category 有值**，其他留 NA
- `excluded` 的人**不是整列拿掉**，是那個 category 的五欄留 NA、`_rule = excluded`，
  因為他在另外兩黨可能完全正常

**對帳**：每一筆作答都要恰好被分配到某一段一次，對不上就中止。

### 結果

| rule | 國民黨 | 民進黨 | 民眾黨 |
|---|---|---|---|
| `single_wave` | 6,360 | 6,360 | 5,815 |
| `stable` | 6,346 | 6,262 | 5,441 |
| `split_2values`（規則 1） | 363 | 401 | 325 |
| `split_regime`（規則 2） | 77 | 117 | 113 |
| `excluded`（規則 3） | 102 | 108 | 147 |

總表 **14,245 列** = 原始 13,248 個 memberId + 997 個拆出來的 `-1`。
對帳：85,261 筆作答全部被分配到某一段且只算一次。

3 種值以上的 664 人裡，307 人通過 regime 判定，**357 人落到規則 3 等人工判斷**。

---

## 目前的狀態與待辦

**已完成**：配對（18 個 category，人工核對過）、政黨喜愛三黨的合併與收斂。

**待辦**：

1. 檔二裡 `rule_no == 3` 的 357 人要人工判斷。判完之後可能要調
   `REGIME_MEAN_GAP` / `REGIME_SEG_RANGE`，或是給規則 3 一條新規則。
2. 其餘 15 個 category 還沒處理。下一批要怎麼開見 [`AGENTS.md`](AGENTS.md)。
3. `QUESTION_INVENTORY.md` 開頭那兩個問題還沒跟資料提供方確認 ——
   2024-05 之後 8 波的「政黨認同」與「泛藍泛綠」主問題整欄退化成單一值。
   政黨喜愛這批不受影響，但處理 `政黨認同_主問` / `陣營認同_泛藍泛綠` 那批之前必須先確認。

**一個沒用上但可能有用的東西**：`LS_2410_1` 與 `LS_2410_2` 同月、185 人重複填答，
是現成的 test-retest 樣本。同月兩次填答有六成完全一樣、95% 差距在 3 以內
（平均絕對差 0.58–0.66）。這幾乎就是純測量雜訊的上界，
之後要替任何門檻找依據時可以拿來用。目前沒有寫進任何程式。
