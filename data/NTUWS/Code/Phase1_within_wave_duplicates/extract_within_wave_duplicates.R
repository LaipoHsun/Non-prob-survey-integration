#!/usr/bin/env Rscript
# =============================================================================
# extract_within_wave_duplicates.R
#
# 同一個波次（sheet）裡，一個 memberId 照理只會有一筆填答。
# 這支程式把違反這個前提的列去掉，產出一份「除了重複列被拿掉以外，
# 其餘與原始 xlsx 一模一樣」的活頁簿，外加一份被刪列的清單。
#
# -----------------------------------------------------------------------------
# 去重規則（每個 sheet 內，逐個 memberId 判定）
#
#     只出現一次                  原樣保留
#     出現多次、內容完全相同      保留第一筆，其餘刪除     （純粹重送）
#     出現多次、內容有差異        整組全部刪除             （無法判斷哪份為真）
#
# 「內容相同」的比對範圍是該波所有作答欄，但**不含 weight**。
# weight 是事後加權欄、不是受訪者的作答，兩筆答案一樣卻 weight 不同，
# 仍屬同一份重送。輸出時 weight 欄照樣保留（留的是第一筆的值）。
#
# memberId 為空的列不參與去重，原樣保留（原始檔目前沒有這種列）。
#
# -----------------------------------------------------------------------------
# 執行 —— 工作目錄在哪都可以，程式會從自己的所在位置往上找到 NTUWS/：
#     LC_ALL=zh_TW.UTF-8 Rscript \
#       data/NTUWS/Code/Phase1_within_wave_duplicates/extract_within_wave_duplicates.R
#
#     ⚠️ locale 一定要是 UTF-8，否則寫檔時中文會被清掉（程式會擋下來）。
#
# 只讀 raw_data/ 底下的原始 xlsx，只寫 NTUWS/output/Phase1_within_wave_duplicates/。
# 不修改任何原始資料，也不改變呼叫端的工作目錄（全程絕對路徑，不呼叫 setwd）。
# output/ 整個資料夾都是可拋棄的 —— 刪掉重跑就會回來。
#
# -----------------------------------------------------------------------------
# 輸入（相對於 data/NTUWS/）
#     raw_data/lottery_repeated_raw_by_wave.xlsx
#
# 輸出（data/NTUWS/output/Phase1_within_wave_duplicates/）—— 只有兩個檔
#     ntuws_lottery_dedup.xlsx      去重後的總表。sheet 名稱、順序、欄位、
#                                   前兩列表頭都與原始檔相同，只少了被刪的資料列
#     ntuws_dedup_removed.csv       被刪掉的列清單，每列一筆：
#                                   sheet / memberId / 原始列號 / 刪除原因
#
# -----------------------------------------------------------------------------
# 設計決定
#
#   原值原樣輸出
#     全欄以文字讀入、原樣寫回，不做任何值標準化（性別不歸男/女、
#     年齡不轉整數）。值的標準化是 Phase0 的事，Phase1 只負責去重。
#     副作用：輸出的 xlsx 每一格都是文字格式，數值欄不會是 Excel 數字。
#
#   保留前兩列表頭
#     第 1 列變項名、第 2 列題目文字，原樣搬過去，下游程式讀法不用改。
#
#   Welcome 也一起處理
#     它是總名冊，理應一人一列。真出現重複同樣照上面的規則處理。
#
# 相依套件：readxl, dplyr, purrr, writexl
# =============================================================================


# =============================================================================
# SECTION 1 — 設定與路徑
# =============================================================================

RAW_XLSX_NAME <- "lottery_repeated_raw_by_wave.xlsx"
PHASE         <- "Phase1_within_wave_duplicates"
NTUWS_MARKER  <- file.path("raw_data", RAW_XLSX_NAME)

OUT_XLSX    <- "ntuws_lottery_dedup.xlsx"
OUT_REMOVED <- "ntuws_dedup_removed.csv"

# 判斷「兩筆是否相同」時忽略的欄位（比對時忽略大小寫與前後空白）。
# 這些欄位仍會出現在輸出的 xlsx 裡，只是不參與比對。
IGNORE_COLS <- c("weight")

# 活頁簿結構：第 1 列 = 原始變項名、第 2 列 = 題目文字、第 3 列起 = 資料
HEADER_ROWS <- 2L

# 以下定位邏輯與 Phase0 相同：先問腳本自己在哪，再逐層往上找 NTUWS/。
script_dir <- function() {
  a <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
  if (length(a)) {
    # ⚠️ Rscript 會把 --file= 裡的空白換成 "~+~"（本專案路徑含空白，一定會中）
    f <- gsub("~+~", " ", sub("^--file=", "", a[1]), fixed = TRUE)
    if (file.exists(f)) return(dirname(normalizePath(f)))
  }
  for (i in seq_len(sys.nframe())) {
    of <- sys.frame(i)$ofile
    if (!is.null(of) && file.exists(of)) return(dirname(normalizePath(of)))
  }
  NULL
}

find_up <- function(marker, starts, levels = 6L) {
  for (s in starts) {
    d <- normalizePath(s, mustWork = FALSE)
    for (i in seq_len(levels)) {
      if (file.exists(file.path(d, marker))) return(d)
      parent <- dirname(d)
      if (identical(parent, d)) break
      d <- parent
    }
  }
  NULL
}

find_ntuws_dir <- function() {
  starts <- c(script_dir(), getwd())
  hit <- find_up(NTUWS_MARKER, starts)
  if (is.null(hit)) {
    stop("找不到 data/NTUWS/（判定依據：底下要有 ", NTUWS_MARKER, "）。\n",
         "  目前工作目錄：", getwd(), "\n",
         "  已從這些位置逐層往上找：", paste(starts, collapse = ", "), "\n",
         "  請確認原始 xlsx 放在 data/NTUWS/raw_data/ 底下。",
         call. = FALSE)
  }
  hit
}

NTUWS_DIR <- find_ntuws_dir()
PATHS <- list(xlsx   = file.path(NTUWS_DIR, NTUWS_MARKER),
              output = file.path(NTUWS_DIR, "output", PHASE))


# =============================================================================
# SECTION 2 — 套件與工具
# =============================================================================

REQUIRED_PKGS <- c("readxl", "dplyr", "purrr", "writexl")
missing_pkgs  <- setdiff(REQUIRED_PKGS, rownames(installed.packages()))
if (length(missing_pkgs)) {
  stop("缺少套件：", paste(missing_pkgs, collapse = ", "),
       "\n請先執行：install.packages(c(",
       paste0('"', missing_pkgs, '"', collapse = ", "), "))")
}
suppressPackageStartupMessages({
  library(readxl); library(dplyr); library(purrr); library(writexl)
})

say <- function(...) message(paste0(...))
say_stage <- function(n, title) {
  say("\n", strrep("=", 72), "\n  STAGE ", n, " — ", title, "\n", strrep("=", 72))
}
assert <- function(condition, msg) {
  if (!isTRUE(all(condition))) stop("斷言失敗：", msg, call. = FALSE)
  invisible(TRUE)
}

# 在 C / POSIX locale 下 write.csv(fileEncoding = "UTF-8") 會把中文吃掉，
# 而且只丟 warning 不報錯 —— 產出的 CSV 看起來正常但中文全空。先擋下來。
assert_utf8_locale <- function() {
  ctype <- Sys.getlocale("LC_CTYPE")
  ok <- isTRUE(l10n_info()[["UTF-8"]]) ||
        grepl("UTF-8|utf8", ctype, ignore.case = TRUE)
  if (!isTRUE(ok)) {
    stop("目前的 locale 是 ", ctype, "，不是 UTF-8，中文會在寫檔時被清掉。\n",
         "  請改用：LC_ALL=zh_TW.UTF-8 Rscript <此檔>", call. = FALSE)
  }
  invisible(TRUE)
}


# =============================================================================
# SECTION 3 — 讀取
#
# 全欄以 col_types = "text"、col_names = FALSE 整片讀入，理由同 Phase0：
#   memberId 是 16 位十六進位字串，自動判型會變成科學記號；
#   郵遞區號「062」的前導零會被吃掉；年齡欄混雜級距與整數會產生一半 NA。
# 這支程式本來就要原值原樣寫回，text 正好。
#
# 讀進來的是「含表頭的整片矩陣」：第 1、2 列是表頭，第 3 列起才是資料。
# =============================================================================

read_sheet_raw <- function(sheet) {
  suppressMessages(
    read_excel(PATHS$xlsx, sheet = sheet, col_names = FALSE, col_types = "text")
  )
}


# =============================================================================
# SECTION 4 — 去重
#
# 對每個 sheet：找出重複的 memberId，依開頭寫的規則決定每一列去留，
# 回傳「留下來的整片矩陣（含表頭）」與「被刪列的清單」。
# =============================================================================

dedup_sheet <- function(sheet) {
  full <- read_sheet_raw(sheet)

  varname <- as.character(unlist(full[1, ]))            # 第 1 列：變項名
  head_df <- full[seq_len(HEADER_ROWS), , drop = FALSE]
  body    <- full[-seq_len(HEADER_ROWS), , drop = FALSE]

  # 原始 xlsx 的資料列序（第 3 列 = 1），刪除清單要靠它回原檔對照
  row_in_sheet <- seq_len(nrow(body))
  member       <- as.character(body[[1]])               # 第 1 欄固定是 memberId

  # 比對用的欄位：扣掉 weight 之類的非作答欄
  ignore <- varname %in% IGNORE_COLS |
            tolower(trimws(varname)) %in% tolower(IGNORE_COLS)
  cmp <- body[, !ignore, drop = FALSE]
  # 每列壓成一個字串，用來判斷兩列是否一模一樣。
  # 分隔符用 \x1f（單元分隔字元），避免值裡本來就有的符號造成誤判。
  sig <- do.call(paste, c(lapply(cmp, function(x) ifelse(is.na(x), "\x1eNA\x1e", x)),
                          sep = "\x1f"))

  blank  <- is.na(member) | trimws(member) == ""
  keep   <- rep(TRUE, nrow(body))
  reason <- rep(NA_character_, nrow(body))

  n_per_id <- table(member[!blank])
  dup_ids  <- names(n_per_id)[n_per_id > 1]

  n_identical_groups <- 0L
  n_differing_groups <- 0L

  for (id in dup_ids) {
    idx <- which(!blank & member == id)
    if (length(unique(sig[idx])) == 1L) {
      # 純粹重送：留第一筆，其餘刪掉
      keep[idx[-1]]   <- FALSE
      reason[idx[-1]] <- "duplicate_identical_kept_first"
      n_identical_groups <- n_identical_groups + 1L
    } else {
      # 內容有差異：無法判斷哪份為真，整組刪掉
      keep[idx]   <- FALSE
      reason[idx] <- "duplicate_conflicting_removed_all"
      n_differing_groups <- n_differing_groups + 1L
    }
  }

  # ⚠️ tibble() 的欄位是依序求值的，後面的欄看得到前面剛建好的同名欄。
  # 先把 row_in_sheet 的子集算在外面，否則 excel_row 會拿已經篩過的欄再篩一次。
  del_row <- row_in_sheet[!keep]
  removed <- tibble(
    sheet        = sheet,
    memberId     = member[!keep],
    row_in_sheet = del_row,                             # 資料列序（第 3 列 = 1）
    excel_row    = del_row + HEADER_ROWS,               # Excel 上看到的實際列號
    n_in_sheet   = as.integer(n_per_id[member[!keep]]), # 這人在該波總共填了幾次
    reason       = reason[!keep]
  ) %>% arrange(memberId, row_in_sheet)

  say(sprintf("  %-11s %6d 列 / %6d 人   重複 %3d 人（相同 %3d / 有差異 %3d）  刪 %4d 列 -> 留 %6d 列",
              sheet, nrow(body), length(n_per_id),
              length(dup_ids), n_identical_groups, n_differing_groups,
              sum(!keep), sum(keep)))

  list(
    sheet    = sheet,
    out      = bind_rows(head_df, body[keep, , drop = FALSE]),
    removed  = removed,
    n_rows   = nrow(body),
    n_kept   = sum(keep),
    n_cols   = ncol(full),
    n_dup_id = length(dup_ids),
    n_ident  = n_identical_groups,
    n_diff   = n_differing_groups
  )
}


# =============================================================================
# SECTION 5 — 執行
# =============================================================================

t_start <- Sys.time()
dir.create(PATHS$output, showWarnings = FALSE, recursive = TRUE)

say("\n波次內重複填答去重")
say("  R ", getRversion(), " on ", R.version$platform)
say("  NTUWS  ", NTUWS_DIR, "（自動偵測）")
say("  輸出   ", PATHS$output)
say("  來源   ", RAW_XLSX_NAME,
    " (", round(file.size(PATHS$xlsx) / 1024^2, 1), " MB)")

say_stage(1, "檢查環境")
assert_utf8_locale()
SHEETS <- excel_sheets(PATHS$xlsx)
say("  ", length(SHEETS), " 個 sheet：", paste(SHEETS, collapse = ", "))

say_stage(2, "逐 sheet 去重")
results <- map(SHEETS, dedup_sheet)
names(results) <- SHEETS

say_stage(3, "輸出")

removed_tbl <- map_dfr(results, "removed") %>%
  arrange(match(sheet, SHEETS), memberId, row_in_sheet)

removed_path <- file.path(PATHS$output, OUT_REMOVED)
write.csv(removed_tbl, removed_path, row.names = FALSE,
          fileEncoding = "UTF-8", na = "")
say("  -> ", OUT_REMOVED, "  (", format(nrow(removed_tbl), big.mark = ","),
    " 列 × ", ncol(removed_tbl), " 欄)")

# 表頭已經在資料的前兩列裡，所以寫檔時不要再讓 writexl 生一排欄名
xlsx_path <- file.path(PATHS$output, OUT_XLSX)
write_xlsx(map(results, "out"), xlsx_path,
           col_names = FALSE, format_headers = FALSE)
say("  -> ", OUT_XLSX, "  (", length(results), " 個 sheet，",
    format(sum(map_int(results, "n_kept")), big.mark = ","), " 列資料，",
    round(file.size(xlsx_path) / 1024^2, 1), " MB)")

# --- 不變條件檢查 ---
assert(identical(names(results), SHEETS), "輸出的 sheet 名稱／順序與原始檔不符")
assert(sum(map_int(results, "n_rows")) - sum(map_int(results, "n_kept")) ==
       nrow(removed_tbl), "刪除列數與清單筆數對不起來")
assert(map_lgl(results, ~ ncol(.x$out) == .x$n_cols), "輸出的欄數與原始檔不符")
assert(map_lgl(results, ~ nrow(.x$out) == .x$n_kept + HEADER_ROWS),
       "輸出列數 = 保留列 + 表頭列，不成立")

say("\n", strrep("-", 72))
say("執行摘要")
say(strrep("-", 72))
say("  原始資料列       : ", format(sum(map_int(results, "n_rows")), big.mark = ","))
say("  刪除             : ", format(nrow(removed_tbl), big.mark = ","),
    " 列（涉及 ", format(n_distinct(removed_tbl$memberId), big.mark = ","),
    " 個 memberId）")
say("    重送、留第一筆 : ",
    format(sum(removed_tbl$reason == "duplicate_identical_kept_first"),
           big.mark = ","),
    " 列（", sum(map_int(results, "n_ident")), " 組）")
say("    有差異、整組刪 : ",
    format(sum(removed_tbl$reason == "duplicate_conflicting_removed_all"),
           big.mark = ","),
    " 列（", sum(map_int(results, "n_diff")), " 組）")
say("  保留             : ", format(sum(map_int(results, "n_kept")), big.mark = ","),
    " 列")
say(strrep("-", 72))
say("\n完成，耗時 ", round(difftime(Sys.time(), t_start, units = "secs")), " 秒。\n")
