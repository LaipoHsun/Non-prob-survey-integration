#!/usr/bin/env Rscript
# =============================================================================
# resolve_party_thermometer_ids.R  —— 政黨喜愛：把每個 ID 的跨波回答收斂成代表值
#
# 讀 build_party_thermometer.R 產出的 ntuws_party_thermometer.xlsx，
# 依「這個人的跨波回答穩不穩」決定他在每個 category 的代表值：
# 穩的就取平均與中位數，不穩的就拆成兩個 ID，判不出來的丟出來人工看。
#
# 只讀那份 xlsx，不重算合併，也不動任何既有檔案。產出兩個新檔。
#
# -----------------------------------------------------------------------------
# 執行 —— 工作目錄在哪都可以：
#     LC_ALL=zh_TW.UTF-8 Rscript \
#       data/NTUWS/Code/Phase2_cross_wave_question_matching/party_thermometer/resolve_party_thermometer_ids.R
#
# -----------------------------------------------------------------------------
# 輸入
#     output/Phase2_cross_wave_question_matching/party_thermometer/
#         ntuws_party_thermometer.xlsx
#
# 輸出（同一個資料夾）
#     ntuws_party_thermometer_resolved.xlsx   總表，一列一個 ID（單一 page，三黨併排）
#     ntuws_party_thermometer_review.xlsx     全部 sd > 2.5 的人，三個 page 供肉眼判斷
#
# =============================================================================
# 收斂規則（使用者 2026-08-24 指定）
#
#   逐 category 各自判定。同一個人可能在國民黨被拆、在民進黨完全正常。
#
#   單一 category 底下，對一個 memberId：
#
#     n_answered == 1                     rule = single_wave
#         mean = median = 該值。沒有 sd 可言。
#
#     sd <= SD_CUTOFF                     rule = stable
#         mean 與 median 照該人全部波次算。ID 不拆。
#         ⚠️ 邊界：sd 恰好等於 SD_CUTOFF 歸在這裡（使用者確認）。
#
#     sd > SD_CUTOFF 且不同值只有 2 種    rule = split_2values
#         拆成兩列：**小的值 -> 原 ID**、**大的值 -> 原 ID-1**。
#         注意這條是按**值的大小**拆，不是按時間 —— 所以原 ID 那一段
#         有可能是比較晚的波次。這是使用者指定的方向。
#
#     sd > SD_CUTOFF 且不同值 >= 3 種
#         先做 regime 判定（見下）。
#         成立   rule = split_regime
#             拆成兩列：**切點前段 -> 原 ID**、**後段 -> 原 ID-1**。
#             這條是按**時間先後**拆。
#         不成立 rule = excluded
#             不進總表（該 category 的欄位留 NA），只出現在檔二。
#
#   拆出來的每一段，mean 與 median 都**按該段重新算**（使用者確認）。
#   規則 1 的段內都是同一個值，所以兩欄相同；規則 2 的段內若有多筆就照算。
#
# -----------------------------------------------------------------------------
# regime 判定：單切點 + 段內一致
#
#   把該人的作答按調查月份由早到晚排（同月份的 LS_2410_1 / _2 依名稱）。
#   逐一嘗試每個可能的切點 k（前段 1..k、後段 k+1..n，兩段都至少 1 筆），
#   取「兩段組內平方和 SS_within 最小」的切點。成立條件兩個都要過：
#
#       兩段平均差的絕對值 >= REGIME_MEAN_GAP   （預設 4）
#       每一段內部的全距   <= REGIME_SEG_RANGE  （預設 2）
#
#   前者要求真的有階梯，後者要求階梯兩側各自穩定 —— 少了後者，
#   「前段 9,2,8 後段 1,0」這種中間亂跳的也會被當成 regime shift。
#
# =============================================================================
# 總表的形狀（單一 page，三黨併排）
#
#   一列一個 memberId（被拆的帶 -1 後綴），每個 category 五欄：
#       <黨>_mean / <黨>_median / <黨>_rule / <黨>_n / <黨>_waves
#
#   某人只在國民黨被拆時：
#       原 ID   那一列三黨都有值（民進黨、民眾黨用它們各自沒被拆的結果）
#       原 ID-1 那一列**只有國民黨的欄位有值**，另外兩黨留 NA
#   split_in 欄註明這一列是被哪個 category 拆出來的。
#
#   規則 3 的人不是整列拿掉，是那個 category 的五欄留 NA、rule = excluded，
#   因為他在另外兩黨可能完全正常。
#
# 相依套件：readxl, dplyr, tidyr, purrr, stringr, writexl
# =============================================================================


# =============================================================================
# SECTION 1 — 設定與路徑
# =============================================================================

BATCH    <- "party_thermometer"
PHASE    <- "Phase2_cross_wave_question_matching"
IN_PHASE <- "Phase1_within_wave_duplicates"
IN_XLSX  <- "ntuws_lottery_dedup.xlsx"
SRC_XLSX <- "ntuws_party_thermometer.xlsx"

OUT_RESOLVED <- "ntuws_party_thermometer_resolved.xlsx"
OUT_REVIEW   <- "ntuws_party_thermometer_review.xlsx"

NTUWS_MARKER <- file.path("output", IN_PHASE, IN_XLSX)

CATEGORIES <- c("0~10_政黨喜愛_國民黨",
                "0~10_政黨喜愛_民進黨",
                "0~10_政黨喜愛_民眾黨")

# 欄位前綴（總表併排時用），與 category 一一對應
SHORT_NAME <- c("0~10_政黨喜愛_國民黨" = "國民黨",
                "0~10_政黨喜愛_民進黨" = "民進黨",
                "0~10_政黨喜愛_民眾黨" = "民眾黨")

# 穩定與否的分界。sd 恰好等於這個值算「穩定」。
SD_CUTOFF <- 2.5

# regime 判定的兩個條件
REGIME_MEAN_GAP  <- 4   # 前後兩段平均差的絕對值至少要有多少
REGIME_SEG_RANGE <- 2   # 每一段內部的全距最多容許多少

# 拆出來的第二段用什麼後綴
SPLIT_SUFFIX <- "-1"

WAVE_MONTH <- c(
  LS_2210 = "2022-10", LS_2211 = "2022-11", LS_23NY = "2023-02",
  LS_2303 = "2023-03", LS_2305 = "2023-05", LS_2306 = "2023-06",
  LS_2310 = "2023-10", LS_24NY = "2024-02", LS_2405 = "2024-05",
  LS_2408 = "2024-08", LS_2410_1 = "2024-10", LS_2410_2 = "2024-10",
  LS_25NY = "2025-01", LS_2509 = "2025-08", LS_2512 = "2025-12",
  LS_26NY = "2026-02", LS_2604 = "2026-04"
)

suppressPackageStartupMessages({
  library(readxl); library(dplyr); library(tidyr)
  library(purrr);  library(stringr); library(writexl)
})

loc <- paste(Sys.getlocale("LC_CTYPE"), Sys.getlocale("LC_ALL"))
if (!grepl("UTF-8|utf8", loc, ignore.case = TRUE)) {
  stop("LC_CTYPE 不是 UTF-8（目前：", Sys.getlocale("LC_CTYPE"), "）。\n",
       "請改用：LC_ALL=zh_TW.UTF-8 Rscript <這支程式>", call. = FALSE)
}

script_dir <- function() {
  args <- commandArgs(trailingOnly = FALSE)
  f <- sub("^--file=", "", args[grepl("^--file=", args)])
  if (length(f)) return(normalizePath(dirname(f[1])))
  if (requireNamespace("rstudioapi", quietly = TRUE) && rstudioapi::isAvailable()) {
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
    if (parent == d) stop("往上找不到 NTUWS 根資料夾", call. = FALSE)
    d <- parent
  }
}

NTUWS_ROOT <- find_ntuws_root(script_dir())
DIR        <- file.path(NTUWS_ROOT, "output", PHASE, BATCH)
SRC_PATH   <- file.path(DIR, SRC_XLSX)

if (!file.exists(SRC_PATH)) {
  stop("找不到 ", SRC_PATH, "\n請先跑 build_party_thermometer.R", call. = FALSE)
}
cat("讀取：", SRC_PATH, "\n")
cat("設定：SD_CUTOFF =", SD_CUTOFF,
    "／ regime 條件：平均差 >=", REGIME_MEAN_GAP,
    "且段內全距 <=", REGIME_SEG_RANGE, "\n\n")


# =============================================================================
# SECTION 2 — 讀進來攤成長表
# =============================================================================

NON_WAVE_COLS <- c("memberId", "n_answered", "mean", "sd", "n_flagged")
wave_levels   <- names(sort(WAVE_MONTH))

read_category <- function(ct) {
  d <- suppressMessages(read_excel(SRC_PATH, sheet = ct))
  wave_cols <- intersect(wave_levels, names(d))
  stopifnot(length(wave_cols) == length(setdiff(names(d), NON_WAVE_COLS)))
  d %>%
    select(memberId, n_answered, sd, all_of(wave_cols)) %>%
    pivot_longer(all_of(wave_cols), names_to = "wave", values_to = "value") %>%
    filter(!is.na(value)) %>%
    mutate(category = ct,
           wave = factor(wave, levels = wave_levels)) %>%
    arrange(memberId, wave)
}

long <- map_dfr(CATEGORIES, read_category)

cat("讀入：\n")
long %>%
  group_by(category) %>%
  summarise(n_ids = n_distinct(memberId), n_answers = n(), .groups = "drop") %>%
  as.data.frame() %>% print(row.names = FALSE)

# 讀進來的作答數必須與寬表一致（寬表已經對過帳，這裡只是不要在轉置時弄丟）
n_in <- nrow(long)


# =============================================================================
# SECTION 3 — 逐人逐 category 判定
# =============================================================================

# regime 判定：回傳 list(ok, cut, mean1, mean2, range1, range2)
# v 必須已經按時間排序。
detect_regime <- function(v) {
  n <- length(v)
  fail <- list(ok = FALSE, cut = NA_integer_,
               mean1 = NA_real_, mean2 = NA_real_,
               range1 = NA_real_, range2 = NA_real_)
  if (n < 2) return(fail)

  ss <- function(x) if (length(x) <= 1) 0 else sum((x - mean(x))^2)

  cuts   <- seq_len(n - 1)
  ss_tot <- map_dbl(cuts, function(k) ss(v[1:k]) + ss(v[(k + 1):n]))
  k      <- cuts[which.min(ss_tot)]      # 平手取最早的切點

  a <- v[1:k]; b <- v[(k + 1):n]
  res <- list(ok = FALSE, cut = k,
              mean1 = mean(a), mean2 = mean(b),
              range1 = max(a) - min(a), range2 = max(b) - min(b))
  res$ok <- abs(res$mean2 - res$mean1) >= REGIME_MEAN_GAP &&
            res$range1 <= REGIME_SEG_RANGE &&
            res$range2 <= REGIME_SEG_RANGE
  res
}

# 一個人在一個 category 底下的判定結果。
# 回傳的 tibble 一列一個「輸出用的 ID」（穩定的 1 列、被拆的 2 列）。
resolve_one <- function(v, waves, n_answered, sd_value) {
  seg_row <- function(idx, suffix, rule) {
    x <- v[idx]
    tibble(id_suffix = suffix, rule = rule,
           mean = mean(x), median = median(x), n = length(x),
           waves = paste(waves[idx], collapse = ", "))
  }
  all_idx <- seq_along(v)

  if (n_answered == 1) return(seg_row(all_idx, "", "single_wave"))
  if (!is.na(sd_value) && sd_value <= SD_CUTOFF) return(seg_row(all_idx, "", "stable"))

  uv <- sort(unique(v))

  # 規則 1：只有兩種值 -> 小的給原 ID、大的給原 ID-1（按值不按時間）
  if (length(uv) == 2) {
    return(bind_rows(
      seg_row(which(v == uv[1]), "",           "split_2values"),
      seg_row(which(v == uv[2]), SPLIT_SUFFIX, "split_2values")
    ))
  }

  # 規則 2：三種以上，看是不是單切點的階梯（按時間）
  rg <- detect_regime(v)
  if (rg$ok) {
    k <- rg$cut
    return(bind_rows(
      seg_row(1:k,                    "",           "split_regime"),
      seg_row((k + 1):length(v),      SPLIT_SUFFIX, "split_regime")
    ))
  }

  # 規則 3
  seg_row(all_idx, "", "excluded")
}

cat("\n判定中……\n")

per_person <- long %>%
  group_by(category, memberId, n_answered, sd) %>%
  summarise(v = list(value), w = list(as.character(wave)), .groups = "drop")

resolved <- per_person %>%
  mutate(res = pmap(list(v, w, n_answered, sd), resolve_one)) %>%
  select(category, memberId, n_answered, sd, res) %>%
  unnest(res) %>%
  mutate(out_id = paste0(memberId, id_suffix))

cat("\n---- 各 category 的判定結果 ----\n")
rule_tbl <- resolved %>%
  distinct(category, memberId, rule) %>%
  count(category, rule, name = "n_ids") %>%
  pivot_wider(names_from = category, values_from = n_ids, values_fill = 0L)
as.data.frame(rule_tbl) %>% print(row.names = FALSE)

# 對帳：每個 category 的每一筆作答都要恰好被算進某一段一次
n_used <- sum(resolved$n)
cat("\n對帳：讀入作答", n_in, "／ 進入各段合計", n_used, "\n")
if (n_in != n_used) stop("有作答沒被分配到段落，或被重複計算。", call. = FALSE)


# =============================================================================
# SECTION 4 — 檔一：總表（單一 page，三黨併排）
# =============================================================================

# excluded 的人：該 category 的欄位留 NA，但保留 rule 標記
wide_parts <- map(CATEGORIES, function(ct) {
  sn <- SHORT_NAME[[ct]]
  resolved %>%
    filter(category == ct) %>%
    mutate(
      is_excluded = rule == "excluded",
      mean   = if_else(is_excluded, NA_real_, round(mean, 4)),
      median = if_else(is_excluded, NA_real_, median),
      n      = if_else(is_excluded, NA_integer_, as.integer(n)),
      waves  = if_else(is_excluded, NA_character_, waves)
    ) %>%
    select(out_id, memberId, mean, median, rule, n, waves) %>%
    rename_with(~paste0(sn, "_", .x), c(mean, median, rule, n, waves))
})

# 三黨的 out_id 取聯集。某人只在一黨被拆時，-1 那列另外兩黨自然是 NA。
resolved_wide <- reduce(wide_parts, full_join, by = c("out_id", "memberId")) %>%
  rename(split_from = memberId)

# split_in：這一列是被哪個 category 拆出來的（可能不只一個）
SHORT <- unname(SHORT_NAME[CATEGORIES])
rule_mat <- as.matrix(resolved_wide[, paste0(SHORT, "_rule"), drop = FALSE])
split_in <- apply(rule_mat, 1, function(r) {
  hit <- SHORT[!is.na(r) & r %in% c("split_2values", "split_regime")]
  if (length(hit) == 0) NA_character_ else paste(hit, collapse = ", ")
})

resolved_wide <- resolved_wide %>%
  mutate(is_split = out_id != split_from, split_in = split_in) %>%
  select(out_id, split_from, is_split, split_in, everything()) %>%
  arrange(split_from, out_id)

cat("\n---- 總表 ----\n")
cat("列數（= 輸出用的 ID 數）：", nrow(resolved_wide), "\n")
cat("其中被拆出來的 -1 列：    ", sum(resolved_wide$is_split), "\n")
cat("原始 memberId 數：        ", n_distinct(resolved_wide$split_from), "\n")


# =============================================================================
# SECTION 5 — 檔二：全部 sd > 2.5 的人，供肉眼判斷
# =============================================================================

# 每個人在該 category 的逐波原始填答（寬表形式）
per_wave_wide <- map(CATEGORIES, function(ct) {
  long %>%
    filter(category == ct) %>%
    select(memberId, wave, value) %>%
    pivot_wider(names_from = wave, values_from = value) %>%
    select(memberId, any_of(wave_levels))
})
names(per_wave_wide) <- CATEGORIES

# 拆的結果與 regime 的細節
split_summary <- resolved %>%
  group_by(category, memberId) %>%
  summarise(
    rule = first(rule),
    split_result = paste0(
      if_else(id_suffix == "", "原ID", paste0("原ID", SPLIT_SUFFIX)),
      "=", round(mean, 2), "（", waves, "）", collapse = "　→　"),
    .groups = "drop")

regime_detail <- per_person %>%
  mutate(rg = map(v, detect_regime)) %>%
  transmute(category, memberId,
            cut_point = map_int(rg, ~ as.integer(.x$cut)),
            seg1_mean = round(map_dbl(rg, ~ .x$mean1), 4),
            seg2_mean = round(map_dbl(rg, ~ .x$mean2), 4),
            seg1_range = map_dbl(rg, ~ .x$range1),
            seg2_range = map_dbl(rg, ~ .x$range2),
            regime_ok  = map_lgl(rg, ~ .x$ok))

review_sheets <- map(CATEGORIES, function(ct) {
  base <- per_person %>%
    filter(category == ct, !is.na(sd), sd > SD_CUTOFF) %>%
    transmute(memberId, n_answered, sd = round(sd, 4),
              n_distinct = map_int(v, ~ length(unique(.x))),
              range = map_dbl(v, ~ max(.x) - min(.x)),
              all_values = map2_chr(w, v, ~ paste0(.x, "=", .y, collapse = " | ")))

  base %>%
    left_join(split_summary %>% filter(category == ct) %>%
                select(memberId, rule, split_result), by = "memberId") %>%
    mutate(rule_no = case_when(rule == "split_2values" ~ 1L,
                               rule == "split_regime"  ~ 2L,
                               rule == "excluded"      ~ 3L,
                               TRUE ~ NA_integer_)) %>%
    left_join(regime_detail %>% filter(category == ct) %>% select(-category),
              by = "memberId") %>%
    left_join(per_wave_wide[[ct]], by = "memberId") %>%
    select(memberId, rule_no, rule, n_answered, sd, range, n_distinct,
           all_values, split_result,
           cut_point, seg1_mean, seg2_mean, seg1_range, seg2_range, regime_ok,
           any_of(wave_levels)) %>%
    arrange(rule_no, desc(range), memberId)
})
names(review_sheets) <- SHORT_NAME[CATEGORIES]

cat("\n---- 檔二：sd >", SD_CUTOFF, "的人 ----\n")
imap_dfr(review_sheets, function(d, nm) {
  tibble(category = nm, n = nrow(d),
         rule1 = sum(d$rule_no == 1), rule2 = sum(d$rule_no == 2),
         rule3 = sum(d$rule_no == 3))
}) %>% as.data.frame() %>% print(row.names = FALSE)


# =============================================================================
# SECTION 6 — 寫出
# =============================================================================

safe_names <- function(x) make.unique(substr(str_replace_all(x, "[:\\\\/?*\\[\\]]", "_"), 1, 31), sep = "_")

resolved_out <- list(`總表` = resolved_wide)
names(resolved_out) <- safe_names(names(resolved_out))
write_xlsx(resolved_out, file.path(DIR, OUT_RESOLVED))

names(review_sheets) <- safe_names(names(review_sheets))
write_xlsx(review_sheets, file.path(DIR, OUT_REVIEW))

cat("\n寫出：\n")
cat("  ", file.path(DIR, OUT_RESOLVED), "（1 個 page）\n", sep = "")
cat("  ", file.path(DIR, OUT_REVIEW),   "（", length(review_sheets), " 個 page）\n", sep = "")
