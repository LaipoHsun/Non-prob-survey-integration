#!/usr/bin/env Rscript
# =============================================================================
# build_question_catalog.R  —— Phase 2 第一步：跨波題目歸類對照表
#
# 目的
#   同一個概念的題目，在不同波次裡欄位名稱、題幹措辭、量尺都不一樣
#   （LS_2303 的 D 欄與 LS_2310 的 E 欄可能問的是同一件事）。
#   這支程式把 ntuws_lottery_dedup.xlsx 裡**所有非 demographic、非 weight**
#   的欄位，依「可能是同一個 category」歸類，產出一份對照用的活頁簿：
#
#       一個 category = 一個 sheet
#       sheet 裡一列 = 某一波的某一欄（記錄波次／欄位序號／原變項名／
#                      原題目描述／量尺措辭／該欄出現過的填答選項）
#
#   歸類是**提案**，不是定論。原題目描述整段原樣保留，人工核對過之後
#   再依 category 去做真正的跨波合併（下一步才做 member × 題目 × 波次 的長表）。
#
# -----------------------------------------------------------------------------
# 執行 —— 工作目錄在哪都可以，程式會從自己的所在位置往上找到 NTUWS/：
#     LC_ALL=zh_TW.UTF-8 Rscript \
#       data/NTUWS/Code/Phase2_cross_wave_question_matching/build_question_catalog.R
#
#     ⚠️ locale 一定要是 UTF-8，否則寫檔時中文會被清掉（程式會擋下來）。
#
# 只讀 output/Phase1_within_wave_duplicates/ 的去重後 xlsx，
# 只寫 output/Phase2_cross_wave_question_matching/。不改任何既有資料。
#
# -----------------------------------------------------------------------------
# 輸入（相對於 data/NTUWS/）
#     output/Phase1_within_wave_duplicates/ntuws_lottery_dedup.xlsx
#
# 輸出（data/NTUWS/output/Phase2_cross_wave_question_matching/）
#     ntuws_question_catalog.xlsx
#         _INDEX          所有 category 一覽（涵蓋幾波、哪幾波、選項是否跨波一致）
#         _ALL_COLUMNS    掃過的每一欄逐欄判定結果（含被排除的 demographic /
#                         weight / memberId），用來檢查「每一欄都有被處理到」
#         _UNMATCHED      沒被任何規則接住的欄（正常情況下應該是空的）
#         <category> ...  一個 category 一個 sheet
#
#     只產這一個檔。長表版的 CSV 刻意不做 —— 這一步的用途是人工核對歸類，
#     真正的長表（memberId × category × wave）是下一步的事。
#
# -----------------------------------------------------------------------------
# 設計決定
#
#   排除的 sheet
#     Welcome（名冊）與 LS_2210 / LS_24NY / LS_25NY（這三波只有 demographic，
#     沒有任何政治題）不掃描。
#
#   排除的欄
#     memberId、weight，以及 demographic（性別／年齡／出生年／教育／
#     籍貫省籍／縣市地區／郵遞區號／戶籍地）。這些是 Phase0 的範圍。
#     被排除的欄仍會出現在 _ALL_COLUMNS，標上排除理由，方便核對。
#
#   歸類依據是「第 2 列的題目文字」，不是變項名
#     LS_2306 / LS_2310 / LS_2405 / LS_2410_* 的變項名是 Q33 / b1_1 / B1_1_1 /
#     Q1__dup1 這種代碼，跨波完全對不起來；但第 2 列的題目文字每一波都有實質內容。
#     所以規則全部寫在題目文字上（見 SECTION 3 的 classify_question）。
#
#   量尺措辭不併進 category，另存一欄
#     照 QUESTION_INVENTORY.md 的 D3：情感電池的「不舒服」（2211/2305）與
#     「高興／感受」（2303/2405+）測的不是同一個東西，不該當成同一題合併。
#     但兩者的「對象 × 政黨」結構完全一樣，所以 category 只到「對象 × 政黨」，
#     措辭差異放 scale_wording 欄，由人工決定要不要拆。好感度的 0–10 / 1–10
#     同理（D6 說要線性重縮放，那是下一步的事，這裡只記錄）。
#
#   填答選項只列出現過的值，不做統計
#     照要求不算次數。全數值的欄依數值排序，其餘依字典序。
#     選項超過 OPTION_LIMIT 種（開放填答「其他-」那類）只列前 OPTION_LIMIT 種，
#     並在 n_options 欄標明實際種數。
#
#   「每一欄都有被 match 到」的檢查
#     程式結束前會確認：掃過的欄數 == 已歸類 + 已排除 + 未歸類，
#     且 _UNMATCHED 為空。有未歸類的欄會在 console 印出清單並以非零碼結束。
#
# 相依套件：readxl, dplyr, purrr, stringr, writexl
# =============================================================================


# =============================================================================
# SECTION 1 — 設定與路徑
# =============================================================================

IN_PHASE   <- "Phase1_within_wave_duplicates"
IN_XLSX    <- "ntuws_lottery_dedup.xlsx"

PHASE      <- "Phase2_cross_wave_question_matching"
OUT_XLSX   <- "ntuws_question_catalog.xlsx"

NTUWS_MARKER <- file.path("output", IN_PHASE, IN_XLSX)

# 不掃描的 sheet：名冊，以及三個只有 demographic 的波次
SKIP_SHEETS <- c("Welcome", "LS_2210", "LS_24NY", "LS_25NY")

# 活頁簿結構：第 1 列 = 原始變項名、第 2 列 = 題目文字、第 3 列起 = 資料
HEADER_ROWS <- 2L

# 每一欄最多列出幾種填答選項
OPTION_LIMIT <- 60L

# 波次 -> 調查月份（出自 QUESTION_INVENTORY.md 的對照表），用來排序
WAVE_MONTH <- c(
  LS_2210 = "2022-10", LS_2211 = "2022-11", LS_23NY = "2023-02",
  LS_2303 = "2023-03", LS_2305 = "2023-05", LS_2306 = "2023-06",
  LS_2310 = "2023-10", LS_24NY = "2024-02", LS_2405 = "2024-05",
  LS_2408 = "2024-08", LS_2410_1 = "2024-10", LS_2410_2 = "2024-10",
  LS_25NY = "2025-01", LS_2509 = "2025-08", LS_2512 = "2025-12",
  LS_26NY = "2026-02", LS_2604 = "2026-04"
)

suppressPackageStartupMessages({
  library(readxl)
  library(dplyr)
  library(purrr)
  library(stringr)
  library(writexl)
})

# locale 檢查：非 UTF-8 之下 writexl 會把中文寫成空白
loc <- paste(Sys.getlocale("LC_CTYPE"), Sys.getlocale("LC_ALL"))
if (!grepl("UTF-8|utf8", loc, ignore.case = TRUE)) {
  stop("LC_CTYPE 不是 UTF-8（目前：", Sys.getlocale("LC_CTYPE"), "）。\n",
       "請改用：LC_ALL=zh_TW.UTF-8 Rscript <這支程式>", call. = FALSE)
}

script_dir <- function() {
  args <- commandArgs(trailingOnly = FALSE)
  f <- sub("^--file=", "", args[grepl("^--file=", args)])
  if (length(f)) return(normalizePath(dirname(f[1])))
  if (requireNamespace("rstudioapi", quietly = TRUE) &&
      rstudioapi::isAvailable()) {
    p <- rstudioapi::getSourceEditorContext()$path
    if (nzchar(p)) return(normalizePath(dirname(p)))
  }
  normalizePath(getwd())
}

find_ntuws_root <- function(start) {
  d <- start
  repeat {
    if (file.exists(file.path(d, NTUWS_MARKER))) return(d)
    parent <- dirname(d)
    if (parent == d) {
      stop("往上找不到 NTUWS 根資料夾（要有 ", NTUWS_MARKER, "）。\n",
           "起點：", start, "\n",
           "請先跑 Phase1 的 extract_within_wave_duplicates.R", call. = FALSE)
    }
    d <- parent
  }
}

NTUWS_ROOT <- find_ntuws_root(script_dir())
IN_PATH    <- file.path(NTUWS_ROOT, "output", IN_PHASE, IN_XLSX)
OUT_DIR    <- file.path(NTUWS_ROOT, "output", PHASE)
dir.create(OUT_DIR, showWarnings = FALSE, recursive = TRUE)

cat("NTUWS 根資料夾：", NTUWS_ROOT, "\n")
cat("讀取：          ", IN_PATH, "\n")
cat("輸出到：        ", OUT_DIR, "\n\n")


# =============================================================================
# SECTION 2 — 讀取
#
# 全欄以文字讀入。第 1 列變項名、第 2 列題目文字都可能重複，
# 所以用 col_names = FALSE + .name_repair = "minimal" 自己拆。
# =============================================================================

read_sheet_raw <- function(sheet) {
  suppressMessages(
    read_excel(IN_PATH, sheet = sheet, col_names = FALSE,
               col_types = "text", .name_repair = "minimal")
  )
}

all_sheets <- excel_sheets(IN_PATH)
use_sheets <- setdiff(all_sheets, SKIP_SHEETS)

missing_skip <- setdiff(SKIP_SHEETS, all_sheets)
if (length(missing_skip)) {
  warning("要跳過的 sheet 在檔案裡不存在：", paste(missing_skip, collapse = ", "))
}

cat("活頁簿共 ", length(all_sheets), " 個 sheet，跳過 ",
    length(intersect(SKIP_SHEETS, all_sheets)), " 個（",
    paste(intersect(SKIP_SHEETS, all_sheets), collapse = ", "), "），",
    "掃描 ", length(use_sheets), " 個。\n\n", sep = "")


# =============================================================================
# SECTION 3 — 歸類規則
#
# 全部寫在「題目文字」上（見檔頭的設計決定）。判定順序有意義，由上往下：
#
#   0  memberId / weight                     -> 排除
#   1  demographic                           -> 排除
#   2  情感極化電池（對象 × 政黨）           -> 先攔，因為它同時含「政黨」字樣
#   3  0–10 政黨好感度                       -> 再攔，因為它含「泛藍政黨／泛綠政黨」
#   4  陣營（泛藍／泛綠）主問與追問
#   5  政黨認同主問與追問
#   其他                                     -> UNMATCHED
# =============================================================================

# 題目文字正規化：全形空白、換行、重複空白都拿掉再比對。
# （原始檔的題幹被 PDF 斷行汙染過，例如「有 時候」中間多一個空白。）
norm_text <- function(x) {
  x <- ifelse(is.na(x), "", x)
  x <- str_replace_all(x, "[\r\n 　]", " ")
  x <- str_replace_all(x, "\\s+", "")
  x
}

# --- demographic 判定 ---------------------------------------------------------
# 只要題幹裡出現這些字樣就當 demographic。政治題不會出現這些字，
# 唯一要小心的是「族群」——只在「父親的籍貫/族群」出現，不在政治題出現。
DEMO_PATTERNS <- c(
  "性別", "年齡", "歲數", "出生", "民國幾年", "民國哪一年",
  "學歷", "教育程度", "籍貫", "省籍", "族群",
  # LS_2405 / LS_2410_* 的父親籍貫題沒有「籍貫」二字，整句都是選項名稱
  "本省客家人", "本省閩南", "新住民",
  "縣市", "地區", "郵遞區號", "戶籍地", "居住"
)

is_demographic <- function(q) any(str_detect(q, fixed(DEMO_PATTERNS)))

# --- 情感極化電池：對象與政黨 ------------------------------------------------
detect_relation <- function(q) {
  if (str_detect(q, "朋友|同事")) return("朋友")
  if (str_detect(q, "鄰居"))      return("鄰居")
  if (str_detect(q, "親屬|小孩|家人|結婚")) return("家人")
  NA_character_
}

detect_party <- function(q) {
  # 「中國國民黨」也含「國民黨」，先比長的沒差，這裡三黨字樣互不重疊
  if (str_detect(q, "國民黨"))            return("國民黨")
  if (str_detect(q, "民進黨|民主進步黨")) return("民進黨")
  if (str_detect(q, "民眾黨"))            return("民眾黨")
  NA_character_
}

# 情感電池的反應量尺措辭（D3：不可跨措辭合併，故另存一欄）
detect_affect_wording <- function(q) {
  if (str_detect(q, "不舒服")) return("是否會感覺到不舒服（5 點）")
  if (str_detect(q, "什麼感受")) return("有什麼感受（5 點）")
  if (str_detect(q, "什麼感覺")) return("有什麼感覺（4 或 5 點）")
  "未知措辭"
}

is_affect_battery <- function(q) {
  !is.na(detect_relation(q)) &&
    str_detect(q, "不舒服|什麼感覺|什麼感受")
}

# --- 0–10 政黨好感度 ---------------------------------------------------------
# 「請問您會給XXX多少」是 LS_23NY 第 9/10 欄那種**承接上一欄題幹**的續問欄，
# 本身沒有 0–10 的說明文字，但問的就是好感度。
is_thermometer <- function(q) {
  str_detect(q, "非常不喜歡|非常厭惡|喜愛度") ||
    str_detect(q, "請問您會給.*多少")
}

# 好感度的標的：三黨 + 泛藍政黨 + 泛綠政黨。標的字樣通常在題幹尾端的
# 「 - XXX」，但 LS_2211 / LS_2305 是整句話裡「請問您會給「XXX」多少」，
# LS_23NY 的第 9/10 欄甚至只剩「請問您會給民進黨多少？」。統一用全句比對。
detect_thermometer_target <- function(q) {
  if (str_detect(q, "泛藍政黨")) return("泛藍政黨")
  if (str_detect(q, "泛綠政黨")) return("泛綠政黨")
  detect_party(q)
}

# 題幹寫的量尺端點（實際資料以 response_options 為準，這裡只記題幹怎麼寫）
detect_thermometer_scale <- function(q) {
  if (str_detect(q, "0到10|0 到 10|用0表示|0表示"))  return("題幹寫 0–10")
  if (str_detect(q, "1到10|1 到 10"))                return("題幹寫 1–10")
  if (str_detect(q, "請問您會給.*多少"))             return("承接前一欄題幹（本欄未重述量尺）")
  "題幹未明寫端點"
}

# --- 陣營（泛藍／泛綠） ------------------------------------------------------
is_camp_followup <- function(q) str_detect(q, "在這兩個陣營之間")

is_camp <- function(q) {
  str_detect(q, "泛藍|泛綠") || is_camp_followup(q)
}

# 陣營題的問法變體（2/3/5/7 點與「群體版」「政黨屬於哪個陣營」都不一樣）
detect_camp_wording <- function(q) {
  if (is_camp_followup(q))                       return("追問：兩陣營之間比較偏向哪邊")
  if (str_detect(q, "哪一個群體"))               return("比較接近哪一個群體")
  if (str_detect(q, "最接近的政黨.*屬於哪一個陣營")) return("您最接近的政黨屬於哪一個陣營（問政黨不是問自己）")
  if (str_detect(q, "比較接近哪一方"))           return("比較接近哪一方")
  if (str_detect(q, "偏向泛藍還是泛綠"))         return("偏向泛藍還是泛綠")
  "自己是泛綠還是泛藍"
}

# --- 政黨認同 ---------------------------------------------------------------
is_party_followup <- function(q) str_detect(q, "您剛剛提到您不接近任何政黨")

is_party_id <- function(q) str_detect(q, "哪一個政黨")

detect_party_id_wording <- function(q) {
  if (is_party_followup(q))            return("追問：比較接近哪一個政黨")
  if (str_detect(q, "最支持"))         return("最支持哪一個政黨")
  if (str_detect(q, "最接近"))         return("最接近哪一個政黨")
  if (str_detect(q, "偏向於"))         return("偏向於哪一個政黨")
  if (str_detect(q, "比較偏向"))       return("比較偏向哪一個政黨（含混陣營選項）")
  "其他問法"
}

# -----------------------------------------------------------------------------
# 回傳 list(category, scale_wording, exclude_reason)
# category 為 NA 且 exclude_reason 為 NA -> 未歸類（UNMATCHED）
# -----------------------------------------------------------------------------
classify_question <- function(var_name, q_raw) {
  q <- norm_text(q_raw)
  v <- norm_text(var_name)

  out <- function(cat = NA_character_, wording = NA_character_,
                  excl = NA_character_) {
    list(category = cat, scale_wording = wording, exclude_reason = excl)
  }

  if (v == "memberId" || q == "memberId")            return(out(excl = "識別碼"))
  if (v == "weight" || str_detect(q, "weighting"))   return(out(excl = "weight（事後加權，非作答）"))

  if (is_affect_battery(q)) {
    rel <- detect_relation(q); pty <- detect_party(q)
    if (is.na(pty)) return(out())                    # 對象有、政黨認不出來 -> 讓它落到 UNMATCHED
    return(out(sprintf("情感極化_%s_%s", rel, pty), detect_affect_wording(q)))
  }

  if (is_thermometer(q)) {
    tgt <- detect_thermometer_target(q)
    if (is.na(tgt)) return(out())
    return(out(sprintf("0~10_政黨喜愛_%s", tgt), detect_thermometer_scale(q)))
  }

  if (is_demographic(q))                             return(out(excl = "demographic（Phase0 範圍）"))

  if (is_camp(q)) {
    cat_name <- if (is_camp_followup(q)) "陣營認同_追問" else "陣營認同_泛藍泛綠"
    return(out(cat_name, detect_camp_wording(q)))
  }

  if (is_party_id(q)) {
    cat_name <- if (is_party_followup(q)) "政黨認同_追問" else "政黨認同_主問"
    return(out(cat_name, detect_party_id_wording(q)))
  }

  out()
}


# =============================================================================
# SECTION 4 — 逐 sheet 逐欄掃描
# =============================================================================

# 該欄出現過的填答選項（不統計次數）。全數值就依數值排序，否則字典序。
collect_options <- function(values) {
  v <- values[!is.na(values)]
  v <- str_trim(v)
  v <- v[nzchar(v)]
  u <- unique(v)
  if (length(u) == 0) {
    return(list(n = 0L, txt = "", truncated = FALSE))
  }
  num <- suppressWarnings(as.numeric(u))
  u <- if (all(!is.na(num))) u[order(num)] else u[order(u)]
  truncated <- length(u) > OPTION_LIMIT
  shown <- if (truncated) u[seq_len(OPTION_LIMIT)] else u
  txt <- paste(shown, collapse = " | ")
  if (truncated) txt <- paste0(txt, " | …（僅列前 ", OPTION_LIMIT, " 種）")
  list(n = length(u), txt = txt, truncated = truncated)
}

scan_sheet <- function(sheet) {
  raw <- read_sheet_raw(sheet)
  if (nrow(raw) < HEADER_ROWS) {
    stop("sheet ", sheet, " 不足 ", HEADER_ROWS, " 列表頭", call. = FALSE)
  }
  var_names <- as.character(unlist(raw[1, ], use.names = FALSE))
  questions <- as.character(unlist(raw[2, ], use.names = FALSE))
  body      <- raw[-seq_len(HEADER_ROWS), , drop = FALSE]

  map_dfr(seq_along(var_names), function(i) {
    cls <- classify_question(var_names[i], questions[i])
    opt <- collect_options(body[[i]])
    tibble(
      wave            = sheet,
      wave_month      = unname(WAVE_MONTH[sheet]) %||% NA_character_,
      col_index       = i,
      col_letter      = excel_col_letter(i),
      var_name        = str_trim(var_names[i]),
      question_text   = str_trim(str_replace_all(questions[i] %||% "", "[\r\n]+", " ")),
      category        = cls$category,
      scale_wording   = cls$scale_wording,
      exclude_reason  = cls$exclude_reason,
      n_rows_answered = sum(!is.na(body[[i]]) & nzchar(str_trim(body[[i]])), na.rm = TRUE),
      n_options       = opt$n,
      response_options = opt$txt
    )
  })
}

`%||%` <- function(a, b) if (is.null(a) || (length(a) == 1 && is.na(a))) b else a

# 欄序號 -> Excel 欄名（A, B, …, AA），方便對著原始 xlsx 看
excel_col_letter <- function(i) {
  out <- ""
  while (i > 0) {
    r <- (i - 1) %% 26
    out <- paste0(LETTERS[r + 1], out)
    i <- (i - 1) %/% 26
  }
  out
}

cat("掃描中……\n")
catalog <- map_dfr(use_sheets, function(s) {
  cat("  - ", s, "\n", sep = "")
  scan_sheet(s)
})

# 波次照月份排序（同月份的 LS_2410_1 / _2 依名稱）
wave_order <- names(sort(WAVE_MONTH))
catalog <- catalog %>%
  mutate(wave = factor(wave, levels = intersect(wave_order, unique(wave)))) %>%
  arrange(wave, col_index) %>%
  mutate(wave = as.character(wave))


# =============================================================================
# SECTION 5 — 檢查：每一欄都要有歸宿
# =============================================================================

matched   <- catalog %>% filter(!is.na(category))
excluded  <- catalog %>% filter(is.na(category), !is.na(exclude_reason))
unmatched <- catalog %>% filter(is.na(category), is.na(exclude_reason))

cat("\n---- 逐欄判定結果 ----\n")
cat("掃描欄數合計：", nrow(catalog), "\n")
cat("  已歸類：    ", nrow(matched), "\n")
cat("  已排除：    ", nrow(excluded), "\n")
excluded %>% count(exclude_reason, name = "n") %>%
  arrange(desc(n)) %>% as.data.frame() %>% print(row.names = FALSE)
cat("  未歸類：    ", nrow(unmatched), "\n")

stopifnot(nrow(catalog) == nrow(matched) + nrow(excluded) + nrow(unmatched))

if (nrow(unmatched) > 0) {
  cat("\n⚠️ 以下欄位沒有被任何規則接住，請補規則：\n")
  unmatched %>%
    select(wave, col_letter, var_name, question_text) %>%
    as.data.frame() %>% print(row.names = FALSE)
}

# 同一波同一個 category 出現超過一次 = 規則太寬或該波真的重複問，要人工看
dup_in_wave <- matched %>%
  count(category, wave, name = "n_cols") %>%
  filter(n_cols > 1)

if (nrow(dup_in_wave) > 0) {
  cat("\n⚠️ 同一波裡同一個 category 對到多欄（請人工確認是不是真的重複問）：\n")
  dup_in_wave %>% as.data.frame() %>% print(row.names = FALSE)
}


# =============================================================================
# SECTION 6 — 組裝輸出
# =============================================================================

# _INDEX：一個 category 一列
index_tbl <- matched %>%
  group_by(category) %>%
  summarise(
    n_waves            = n_distinct(wave),
    n_columns          = n(),
    waves              = paste(unique(wave), collapse = ", "),
    n_wordings         = n_distinct(scale_wording),
    wordings           = paste(sort(unique(scale_wording)), collapse = " ／ "),
    options_identical  = n_distinct(response_options) == 1,
    .groups = "drop"
  ) %>%
  arrange(desc(n_waves), category)

cat("\n---- category 一覽 ----\n")
index_tbl %>%
  select(category, n_waves, n_columns, n_wordings) %>%
  as.data.frame() %>% print(row.names = FALSE)

# Excel sheet 名稱：不得含 : \ / ? * [ ]，長度 <= 31，且必須唯一
safe_sheet_name <- function(x) {
  x <- str_replace_all(x, "[:\\\\/?*\\[\\]]", "_")
  x <- substr(x, 1, 31)
  make.unique(x, sep = "_")
}

cat_names   <- index_tbl$category
sheet_names <- safe_sheet_name(cat_names)

DETAIL_COLS <- c("wave", "wave_month", "col_index", "col_letter",
                 "var_name", "question_text", "scale_wording",
                 "n_rows_answered", "n_options", "response_options")

sheets <- list(
  `_INDEX`       = index_tbl,
  `_ALL_COLUMNS` = catalog %>%
    mutate(status = case_when(
      !is.na(category)       ~ "已歸類",
      !is.na(exclude_reason) ~ "已排除",
      TRUE                   ~ "未歸類"
    )) %>%
    select(wave, wave_month, col_index, col_letter, var_name, question_text,
           status, category, scale_wording, exclude_reason,
           n_rows_answered, n_options, response_options),
  `_UNMATCHED`   = unmatched %>%
    select(wave, wave_month, col_index, col_letter, var_name, question_text,
           n_rows_answered, n_options, response_options)
)

for (k in seq_along(cat_names)) {
  sheets[[ sheet_names[k] ]] <- matched %>%
    filter(category == cat_names[k]) %>%
    select(all_of(DETAIL_COLS))
}

# _UNMATCHED 若為空，writexl 仍寫得出只有表頭的 sheet，留著當「檢查通過」的證據
out_xlsx_path <- file.path(OUT_DIR, OUT_XLSX)
write_xlsx(sheets, out_xlsx_path)

cat("\n寫出：\n")
cat("  ", out_xlsx_path, "（", length(sheets), " 個 sheet）\n", sep = "")

if (nrow(unmatched) > 0) {
  cat("\n有 ", nrow(unmatched), " 欄未歸類，以非零碼結束。\n", sep = "")
  quit(status = 1)
}
cat("\n檢查通過：所有欄位都已歸類或明確排除。\n")
