# Phase 2 工作規則

這個資料夾底下不論處理哪一個題目、哪一批 category，都照這份規則走。
使用者只要說「這次一起處理 X、Y、Z 這幾個 category」＋「合併規則是什麼」，
其餘的結構、命名、檢查都按這裡的約定，不用每次重講。

Phase 2 在做的事：依 `ntuws_question_catalog.xlsx` 的歸類，
把同一個 category 的跨波回答**按 memberId 併成同一列**，
做成 time-variant 的作答矩陣。

---

## 0. 先讀這三份

| 檔案 | 為什麼要讀 |
|---|---|
| `../../PHASE2_README.md` | **Phase 2 全貌**：已經做過哪幾批、套了什麼規則、產出長什麼樣 |
| `../../PHASE2_QUESTION_CATALOG.md` | 這一批 category 各涵蓋哪幾波、有幾種措辭 |
| `../../QUESTION_INVENTORY.md` | 量尺差異與已確認的合併決定（D1–D8），合併規則的依據 |
| `../../output/Phase2_cross_wave_question_matching/ntuws_question_catalog.xlsx` | **唯一的配對來源**。哪一波哪一欄屬於哪個 category，以這份為準 |

⚠️ **不要重新用正則表達式去猜哪一欄是哪一題。** 配對已經人工核對過了，
一律從 catalog 的 `wave` + `col_index` 去原始 xlsx 取那一欄。
catalog 改了就重跑，不要在下游程式裡另開一套判定邏輯。

資料來源一律是 `output/Phase1_within_wave_duplicates/ntuws_lottery_dedup.xlsx`
（波次內已去重）。不讀 `raw_data/`。

---

## 1. 一批 category = 一個子資料夾

使用者一次會給一批**性質相近、要一起處理**的 category。每一批在
`Code/` 與 `output/` 底下各開一個**同名子資料夾**，兩邊一一對應
（沿用專案既有的 phase 資料夾配對慣例）：

```
Code/Phase2_cross_wave_question_matching/
├── AGENTS.md                       ← 你在看的這份
├── build_question_catalog.R        ← 產 catalog 的程式（已完成，不要動）
└── <batch_name>/
    └── build_<batch_name>.R

output/Phase2_cross_wave_question_matching/
├── ntuws_question_catalog.xlsx     ← catalog（已完成，不要動）
└── <batch_name>/
    └── ntuws_<batch_name>.xlsx
```

`<batch_name>` 用英文小寫底線，看得出是哪一批（例：`party_thermometer`、
`affective_polarization`）。子資料夾名兩邊必須一模一樣。

---

## 2. 一個 category = 一個 page

輸出的 xlsx，**一個 category 一個 sheet**，一列一個 memberId，寬表：

| 欄 | 內容 |
|---|---|
| `memberId` | 受訪者 ID（見第 5 節，可能帶 `-1` / `-2` 後綴） |
| 每一波一欄 | 欄名 = 波次名（`LS_2211`、`LS_2303`…），依調查月份由早到晚排 |
| `n_answered` | 這個 ID 在這個 category 底下總共答了幾波 |
| `mean` | 見第 4 節 |
| `sd` | 見第 4 節 |
| 判定欄 | 見第 5 節 |

規則：

- **該波沒答就是 `NA`**。包含兩種情況：這個人那一波沒參與、以及那一波根本沒問這題。
  兩者在寬表裡都是 NA，靠 `_COVERAGE` sheet 分辨（見第 6 節）。
- 只有 catalog 說這個 category 有出現的波次才開欄。沒問過的波次不開空欄。
- 欄位裡放的是**合併後的值**，不是原始字串。合併規則由使用者當批指定
  （因為各波 scale 不一樣），程式裡要把該規則寫成一個明確的函式並在檔頭列出來。
- **原始值不能丟。** 每個 category 都要有一個對應的 `_RAW_<標的>` sheet，
  同樣的寬表結構但放未經轉換的原始字串，方便回頭核對合併是否正確。

---

## 3. 合併規則怎麼寫

合併規則使用者會給，但落地時一律遵守：

1. **寫成單一函式，逐波分開**（`merge_value(wave, raw)`），不要散在各處。
2. 檔頭註解要把「哪一波做了什麼轉換、為什麼」逐條列出來，
   引用 `QUESTION_INVENTORY.md` 的決定編號（D1–D8）。
3. **轉換後要檢查值域**：每一波轉換後的值必須落在宣告的值域內，
   有落在外面的就中止並印出該波、該值、出現次數。
4. 無法轉換的值（開放填答、「其他-」、拒答）**不要靜靜變成 NA**。
   要單獨統計，印在 console，並在輸出裡有一個 `_UNCONVERTED` sheet 記錄
   `wave / 原始值 / 出現次數`。

---

## 4. 平均與標準差

寬表的波次欄之後接 `mean` 與 `sd`，都只用該 ID **有答的波**計算
（`na.rm = TRUE`）。

- `n_answered == 0` 的人不應該出現在表裡（沒答過就不列）。
- `n_answered == 1` 時 `sd` 是 `NA`（樣本數不足），不要填 0。
- 類別型的 category（政黨認同、陣營認同這種）沒有平均與標準差可言 ——
  這時 `mean` / `sd` 兩欄放 `NA`，另外用「最常見的答案 + 是否曾經變動」
  兩欄取代，並在檔頭說明為什麼。

---

## 5. Time-invariant 檢查與 ID 拆分

前提：跨波的回答**應該**是 time-variant 的，但同一個 memberId 底下如果出現
「差太多、不像同一個人」的回答，要把它視為不同的人。

- **不能只看前後值是否相同。** 0–10 的量尺上 5→6 是雜訊，3→8 是換了個人。
  判定必須看**變動幅度**，而且門檻要有依據，不能憑感覺挑。
- 每一批都要在檔頭寫清楚：用什麼統計量、門檻多少、門檻怎麼定出來的。
- **門檻沒定之前不要自己拆 ID。** 先產出診斷表（哪些作答偏離、偏多少、
  該人所有波次的值長什麼樣）讓使用者看過再決定，這一階段 memberId 維持原樣。
- 門檻定出來之後，輸出裡要有一個 `_SPLIT_LOG` sheet 記錄每一個被拆的 ID：
  原 ID / 被拆成幾段 / 各段涵蓋哪幾波 / 觸發拆分的那一對波次與其差距。
- 拆分後的 ID 命名：原 ID 加 `-1`、`-2`……
  **哪一段拿原 ID、哪一段拿後綴，由當批的規則指定**，不要預設按時間。
  （政黨喜愛那批就是兩種規則並存：只有兩種值時按**值的大小**拆，小值拿原 ID；
  三種以上判定為 regime shift 時按**時間先後**拆，前段拿原 ID。）
  **沒有被拆的人維持原 ID，不加後綴**，這樣才 join 得回 Phase0 的 demographic 主表。
- 寬表要有一欄 `split_from` 記錄原 ID（沒被拆的人就等於自己），
  以及一欄 `flag_unstable` 標記這個 ID 是否來自被拆的人。

---

## 6. 每一批都要有的檢查 sheet

活頁簿裡除了 category sheet，固定附上這幾個底線開頭的 sheet：

| sheet | 內容 |
|---|---|
| `_INDEX` | 這一批有哪些 category、各涵蓋幾波、幾個 ID、拆了幾個 ID |
| `_COVERAGE` | category × wave 的矩陣：該波有沒有問這題、有幾個人答 |
| `_RAW_<標的>` | 未轉換的原始值寬表，一個 category 一個（第 2 節） |
| `_UNCONVERTED` | 無法轉換的值清單（第 3 節） |
| `_SPLIT_LOG` | 被拆的 ID 清單（第 5 節）。門檻還沒定的階段改放 `_DEVIATION` / `_DEVIATION_BY_ID` 這種供人工判斷的診斷表 |

程式跑完要在 console 印出對帳：**原始作答數 = 進入寬表的格數 + 無法轉換數**，
對不起來就中止。這條跟 `build_question_catalog.R` 的「每一欄都要有歸宿」是同一個精神 ——
每一筆作答都要有去處，不能無聲消失。

---

## 7. 沿用專案既有約定

1. **原始資料唯讀。** 只讀 `output/Phase1_.../` 與 `output/Phase2_.../ntuws_question_catalog.xlsx`，只寫自己那個 batch 子資料夾。
2. **產出可拋棄。** 刪掉重跑就會回來，不要往 `output/` 放手工編輯的東西。
3. **不 `setwd()`。** 從腳本自己的位置往上找 NTUWS 根資料夾，之後全走絕對路徑。
   （直接抄 `build_question_catalog.R` 的 `script_dir()` / `find_ntuws_root()`。）
4. **產出檔名帶 `ntuws_` 前綴。**
5. **locale 必須 UTF-8**，程式開頭要擋：`LC_ALL=zh_TW.UTF-8 Rscript ...`，
   否則 `writexl` 會把中文寫成空白。
6. **Excel sheet 名稱**：不得含 `: \ / ? * [ ]`，長度 ≤ 31，且要唯一。
7. 檔頭註解照 `build_question_catalog.R` 的格式：目的／執行方式／輸入／輸出／設計決定。
8. 相依套件：`readxl, dplyr, tidyr, purrr, stringr, writexl`。

---

## 8. 每一批做完要回報什麼

- 每個 category 進了幾個 ID、各波各有幾個人答
- 合併規則實際套用的結果（各波轉換前後的值域）
- 無法轉換的值有多少、都是些什麼
- 拆了幾個 ID、門檻是多少、怎麼定的
- 對帳有沒有對上

不要只說「做完了」。數字對不上就直說哪裡對不上。
