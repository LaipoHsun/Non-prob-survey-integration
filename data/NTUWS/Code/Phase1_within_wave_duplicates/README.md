# Phase 1 · Code — 波次內重複填答去重

最後更新：2026-08-24

這個資料夾放 Phase 1 的**程式**。產出長什麼樣、刪了誰，看
[`output/Phase1_within_wave_duplicates/README.md`](../../output/Phase1_within_wave_duplicates/README.md)。

| 檔案 | 說明 |
|---|---|
| `extract_within_wave_duplicates.R` | 唯一一支。14 KB |

**這個 phase 只做一件事：去重。** 不做值標準化、不產分析表 —— 那些是 Phase 0 的事。

---

## 1. 執行

```bash
LC_ALL=zh_TW.UTF-8 Rscript "data/NTUWS/Code/Phase1_within_wave_duplicates/extract_within_wave_duplicates.R"
```

第一次跑之前：

```bash
Rscript -e 'install.packages(c("readxl","dplyr","purrr","writexl"))'
```

- **工作目錄在哪都可以。** 定位邏輯與 Phase 0 相同：先問「自己這支腳本放在哪」，
  再逐層往上找含有 `raw_data/lottery_repeated_raw_by_wave.xlsx` 的資料夾，之後全走絕對路徑，
  不呼叫 `setwd()`。
- **只讀 `raw_data/`，只寫 `output/Phase1_within_wave_duplicates/`。** 原始資料完全沒動。
- 約 2 秒跑完。
- ⚠️ **locale 一定要 UTF-8**，否則寫檔時中文會被靜默清掉。程式有 `assert_utf8_locale()` 擋。

---

## 2. 去重規則

同一波（同一個 sheet）裡，一個 `memberId` 照理只會有一筆填答。逐個 `memberId` 判定：

| 情況 | 處理 |
|---|---|
| 只出現一次 | 原樣保留 |
| 出現多次、**內容完全相同** | 保留第一筆，其餘刪除（純粹重送） |
| 出現多次、**內容有差異** | **整組全部刪除**（無法判斷哪份為真） |

「內容相同」的比對範圍是該波**所有作答欄，但不含 `weight`**（`IGNORE_COLS` 設定）。
weight 是事後加權欄、不是受訪者的作答，兩筆答案一樣卻 weight 不同仍屬同一份重送。
輸出時 weight 欄照樣保留（留的是第一筆的值）。

`memberId` 為空的列不參與去重，原樣保留（原始檔目前沒有這種列）。
`Welcome` 名冊也一起處理 —— 它理應一人一列，真出現重複同樣照上面的規則辦（實測 0 重複）。

---

## 3. 設計決定

**原值原樣輸出。** 全欄以 `col_types = "text"` 讀入、原樣寫回，不做任何值標準化
（性別不歸男/女、年齡不轉整數）。理由同 Phase 0：`memberId` 是 16 位十六進位字串
（自動判型會變科學記號）、郵遞區號「062」的前導零會被吃掉、年齡欄混雜級距與整數。
**副作用**：輸出的 xlsx 每一格都是文字格式，數值欄不會是 Excel 數字。

**保留前兩列表頭。** 第 1 列變項名、第 2 列題目文字原樣搬過去，下游程式讀法不用改。

**兩筆是否相同怎麼判。** 每列的比對欄位壓成一個字串（`sig`），分隔符用 `\x1f`
（單元分隔字元），避免值裡本來就有的符號造成誤判。

---

## 4. 產出

只有兩個檔（刻意的，這個 phase 不需要更多）：

| 檔案 | 內容 |
|---|---|
| `ntuws_lottery_dedup.xlsx` | 去重後的總表。18 個 sheet，名稱／順序／欄位／前兩列表頭都與原始 xlsx 相同，只少了被刪的資料列 |
| `ntuws_dedup_removed.csv` | 被刪掉的列清單，每列一筆 |

---

## 5. 內建檢查

跑完會斷言這些條件，不成立直接中止：

- 輸出的 sheet 名稱與順序和原始檔完全相同
- 每個 sheet 的欄數與原始檔相同
- 刪除列數 = 刪除清單的筆數
- 每個 sheet 的輸出列數 = 保留列數 + 2 列表頭

---

## 6. 與 Phase 0 的關係

**兩者都處理同波重複，但規則不同，是刻意的。兩者互相獨立、沒有先後順序**，
各自從原始 xlsx 讀起。

| | Phase 0 | Phase 1 |
|---|---|---|
| 比對範圍 | 只比**六個 demographic 欄位** | 比**該波所有作答欄**（不含 `weight`） |
| 判定「有差異」時 | 該人**整個排除**出主表（含他其他波次） | 只刪**該波那幾列**，其他波次不受影響 |
| 同樣的 420 組怎麼分 | 相同 330 / 互斥 90 | 相同 123 / 有差異 297 |
| 產出 | demographic 主表（14,870 人） | 去重後的完整 xlsx（54,540 列） |

Phase 1 比對的欄位多得多，所以「有差異」的組數自然高很多。**兩邊數字不同不是 bug。**
