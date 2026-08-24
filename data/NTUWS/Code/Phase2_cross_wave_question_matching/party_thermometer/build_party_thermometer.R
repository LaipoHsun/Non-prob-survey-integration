#!/usr/bin/env Rscript
# =============================================================================
# build_party_thermometer.R  —— Phase 2 batch：政黨喜愛（0–10 好感度）
#
# 這一批處理三個 category：
#     0~10_政黨喜愛_國民黨（14 波）
#     0~10_政黨喜愛_民進黨（14 波）
#     0~10_政黨喜愛_民眾黨（13 波，LS_2306 只問了國民黨與民進黨）
#
# 一個 category 一個 sheet，一列一個 memberId，一波一欄，值是合併後的 0–10，
# 該波沒答就 NA，後面接 n_answered / mean / sd。
#
# 工作規則見 ../AGENTS.md，配對來源見 ntuws_question_catalog.xlsx。
#
# -----------------------------------------------------------------------------
# 執行 —— 工作目錄在哪都可以：
#     LC_ALL=zh_TW.UTF-8 Rscript \
#       data/NTUWS/Code/Phase2_cross_wave_question_matching/party_thermometer/build_party_thermometer.R
#
# -----------------------------------------------------------------------------
# 輸入（相對於 data/NTUWS/）
#     output/Phase1_within_wave_duplicates/ntuws_lottery_dedup.xlsx        作答資料
#     output/Phase2_cross_wave_question_matching/ntuws_question_catalog.xlsx  波次×欄位的配對
#
# 輸出
#     output/Phase2_cross_wave_question_matching/party_thermometer/
#         ntuws_party_thermometer.xlsx
#
# =============================================================================
# 合併規則（使用者 2026-08-24 指定）
#
#   值域：全部 0–10 整數。
#
#   1. 除了 LS_2310 以外，各波的值原樣採用，不做任何縮放。
#      （LS_2211 題幹雖然寫「1 到 10」，但資料實際是 0–10，以資料為準。）
#
#   2. LS_2303 的值帶端點文字：「0（非常厭惡）」「10（非常喜愛）」。
#      剝除括號後的文字只留數字。這是解析不是換算。
#
#   3. LS_2310 實際值域是 1–10（沒有 0）。**不做線性重縮放**，改成逐人判定
#      那個「1」到底是不是別波的「0」：
#
#        對每一個在 LS_2310 填 1 的人，看他在**同一個 category** 其他波的值：
#          其他波的 0 比 1 多   -> LS_2310 的 1 改成 0     （branch: to_0）
#          其他波的 1 比 0 多   -> 維持 1                  （branch: keep_1_majority）
#          0 與 1 一樣多且都出現過 -> 維持 1               （branch: keep_1_tie）
#          其他波既沒 0 也沒 1  -> 維持 1                  （branch: keep_1_no_evidence）
#          沒有其他波可對照     -> 維持 1                  （branch: keep_1_single_wave）
#
#        使用者的規則只明講前兩種。後三種一律**維持原值**，
#        也就是只有在「其他波多數填 0」這種正面證據下才改。
#        每一個受影響的人都逐筆記在 _2310_ONE_RULE，要翻哪一支改
#        RULE_2310_KEEP_ON_TIE / _NO_EVIDENCE / _SINGLE_WAVE 這三個常數即可。
#
#      LS_2310 的 2–10 全部原樣不動。
#
#   4. LS_2410_1 與 LS_2410_2 雖然同為 2024-10，**兩欄並存不合併**
#      （有 185 人兩波都答，那是現成的 test-retest 資料）。
#
# -----------------------------------------------------------------------------
# Time-invariant 的檢查：這一版**只標記、不拆 ID**
#
#   使用者指定的標記方式：先算每個 ID 在該 category 底下所有作答的平均，
#   任何一筆作答與該平均相差超過 ±1 就標記出來，寫成獨立的表供人工判斷。
#   門檻與拆 ID 的規則等使用者看過整體分布再定，所以這一版
#   **不產生任何 -1 / -2 後綴的 ID**，memberId 全部維持原樣。
#
# =============================================================================
# 輸出活頁簿的 sheet
#
#   _INDEX             三個 category 的概況
#   _COVERAGE          category × wave：該波有沒有問、有幾個人答
#   <category> × 3     合併後的寬表（本體）
#   _STATS_OVERALL     每個 category 的整體平均／標準差，以及
#                      「人與人之間」vs「同一個人跨波」的變異拆解
#   _STATS_BY_WAVE     每個 category × 每一波的平均／標準差
#   _2310_ONE_RULE     LS_2310 填 1 的人逐筆判定紀錄（含其他波的值）
#   _DEVIATION_BY_ID   偏離個人平均 ±1 以外的人，一列一人，附全部波次的值
#   _UNCONVERTED       無法轉成數字的原始值清單
#
#   _RAW_<標的> 原始字串寬表預設不產（KEEP_RAW_SHEETS = FALSE）——
#   使用者 2026-08-24 說不需要留。要回頭核對合併時把常數改 TRUE 重跑即可。
#   逐筆的 _DEVIATION 同樣不產，_DEVIATION_BY_ID 已經夠判斷。
#
# 相依套件：readxl, dplyr, tidyr, purrr, stringr, writexl
# =============================================================================


# =============================================================================
# SECTION 1 — 設定與路徑
# =============================================================================

BATCH      <- "party_thermometer"
PHASE      <- "Phase2_cross_wave_question_matching"
IN_PHASE   <- "Phase1_within_wave_duplicates"
IN_XLSX    <- "ntuws_lottery_dedup.xlsx"
CATALOG    <- "ntuws_question_catalog.xlsx"
OUT_XLSX   <- "ntuws_party_thermometer.xlsx"

NTUWS_MARKER <- file.path("output", IN_PHASE, IN_XLSX)

CATEGORIES <- c("0~10_政黨喜愛_國民黨",
                "0~10_政黨喜愛_民進黨",
                "0~10_政黨喜愛_民眾黨")

# 合併後宣告的值域，轉換完會逐波檢查
VALUE_RANGE <- c(0, 10)

# LS_2310 的「1」在證據不足時要不要維持原值（見檔頭合併規則第 3 條）
RULE_2310_KEEP_ON_TIE        <- TRUE   # 其他波 0 與 1 一樣多
RULE_2310_KEEP_ON_NO_EVIDENCE <- TRUE  # 其他波既沒 0 也沒 1
RULE_2310_KEEP_ON_SINGLE_WAVE <- TRUE  # 沒有其他波可對照

# 偏離標記門檻：|該筆作答 − 該人平均| > DEVIATION_TOL 就標記
DEVIATION_TOL <- 1

# 未轉換的原始字串寬表要不要一起輸出（預設不要，見檔頭）
KEEP_RAW_SHEETS <- FALSE

HEADER_ROWS <- 2L

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
    if (parent == d) {
      stop("往上找不到 NTUWS 根資料夾（要有 ", NTUWS_MARKER, "）", call. = FALSE)
    }
    d <- parent
  }
}

NTUWS_ROOT   <- find_ntuws_root(script_dir())
DATA_PATH    <- file.path(NTUWS_ROOT, "output", IN_PHASE, IN_XLSX)
CATALOG_PATH <- file.path(NTUWS_ROOT, "output", PHASE, CATALOG)
OUT_DIR      <- file.path(NTUWS_ROOT, "output", PHASE, BATCH)
dir.create(OUT_DIR, showWarnings = FALSE, recursive = TRUE)

cat("作答資料：", DATA_PATH, "\n")
cat("配對來源：", CATALOG_PATH, "\n")
cat("輸出到：  ", OUT_DIR, "\n\n")


# =============================================================================
# SECTION 2 — 依 catalog 取出各波該題的那一欄
#
# 哪一波的哪一欄屬於哪個 category，一律以 catalog 為準，不在這裡重新判定。
# =============================================================================

# 每個 sheet 只讀一次，之後重複取欄都吃這份快取
sheet_cache <- new.env(parent = emptyenv())
get_sheet <- function(w) {
  if (!exists(w, envir = sheet_cache)) {
    assign(w, suppressMessages(
      read_excel(DATA_PATH, sheet = w, col_names = FALSE,
                 col_types = "text", .name_repair = "minimal")
    ), envir = sheet_cache)
  }
  get(w, envir = sheet_cache)
}

read_catalog_sheet <- function(s) suppressMessages(read_excel(CATALOG_PATH, sheet = s))

# 一個 category -> 長表 memberId / wave / raw
pull_category <- function(ct) {
  map <- read_catalog_sheet(ct)
  map_dfr(seq_len(nrow(map)), function(k) {
    w  <- map$wave[k]
    ci <- as.integer(map$col_index[k])
    d  <- get_sheet(w)
    ids <- d[[1]][-seq_len(HEADER_ROWS)]
    val <- d[[ci]][-seq_len(HEADER_ROWS)]
    tibble(memberId = ids, wave = w, raw = val)
  }) %>%
    filter(!is.na(memberId), nzchar(str_trim(memberId)))
}

cat("依 catalog 取值……\n")
raw_long <- map_dfr(CATEGORIES, function(ct) {
  x <- pull_category(ct); x$category <- ct
  cat("  - ", ct, "：", length(unique(x$wave)), " 波、",
      sum(!is.na(x$raw)), " 筆作答\n", sep = "")
  x
})

# 波次內一人一列是 Phase1 的保證，這裡再確認一次
dup_check <- raw_long %>% count(category, wave, memberId) %>% filter(n > 1)
if (nrow(dup_check) > 0) {
  stop("同一波同一個 memberId 出現多列，Phase1 的去重前提被破壞了：\n",
       paste(utils::capture.output(print(as.data.frame(head(dup_check, 20)))),
             collapse = "\n"), call. = FALSE)
}

N_RAW_ANSWERS <- sum(!is.na(raw_long$raw) & nzchar(str_trim(raw_long$raw)))
cat("原始作答總數：", N_RAW_ANSWERS, "\n\n")


# =============================================================================
# SECTION 3 — 合併：解析成數字，再套 LS_2310 的逐人判定
# =============================================================================

# 「0（非常厭惡）」-> 0。括號有全形也有半形，一律砍掉第一個括號之後的東西。
parse_value <- function(x) {
  s <- str_trim(ifelse(is.na(x), NA_character_, x))
  s <- ifelse(!is.na(s) & nzchar(s), str_replace(s, "[（(].*$", ""), NA_character_)
  s <- str_trim(s)
  suppressWarnings(as.numeric(s))
}

work <- raw_long %>%
  filter(!is.na(raw), nzchar(str_trim(raw))) %>%
  mutate(value_parsed = parse_value(raw))

# --- 無法轉成數字的值 --------------------------------------------------------
unconverted <- work %>%
  filter(is.na(value_parsed)) %>%
  count(category, wave, raw, name = "n") %>%
  arrange(desc(n))

if (nrow(unconverted) > 0) {
  cat("⚠️ 無法轉成數字的原始值：\n")
  print(as.data.frame(unconverted), row.names = FALSE)
} else {
  cat("解析檢查：所有原始值都轉得出數字。\n")
}
N_UNCONVERTED <- sum(unconverted$n)

work <- work %>% filter(!is.na(value_parsed))

# --- LS_2310 的「1」逐人判定 -------------------------------------------------
# 判定用的「其他波」是同一個 category、同一個人、LS_2310 以外的所有波。
other_wave_evidence <- work %>%
  filter(wave != "LS_2310") %>%
  group_by(category, memberId) %>%
  summarise(n_other = n(),
            n_zero  = sum(value_parsed == 0),
            n_one   = sum(value_parsed == 1),
            other_values = paste0(wave, "=", value_parsed, collapse = " | "),
            .groups = "drop")

ones_2310 <- work %>%
  filter(wave == "LS_2310", value_parsed == 1) %>%
  select(category, memberId) %>%
  left_join(other_wave_evidence, by = c("category", "memberId")) %>%
  mutate(
    n_other = coalesce(n_other, 0L),
    n_zero  = coalesce(n_zero,  0L),
    n_one   = coalesce(n_one,   0L),
    other_values = coalesce(other_values, ""),
    branch = case_when(
      n_other == 0            ~ "keep_1_single_wave",
      n_zero  >  n_one        ~ "to_0",
      n_one   >  n_zero       ~ "keep_1_majority",
      n_zero  == 0            ~ "keep_1_no_evidence",   # 兩者都是 0 筆
      TRUE                    ~ "keep_1_tie"            # 0 與 1 一樣多且都出現過
    )
  ) %>%
  mutate(
    value_after = case_when(
      branch == "to_0"                                                    ~ 0,
      branch == "keep_1_tie"          & !RULE_2310_KEEP_ON_TIE            ~ 0,
      branch == "keep_1_no_evidence"  & !RULE_2310_KEEP_ON_NO_EVIDENCE    ~ 0,
      branch == "keep_1_single_wave"  & !RULE_2310_KEEP_ON_SINGLE_WAVE    ~ 0,
      TRUE                                                                ~ 1
    ),
    value_before = 1
  )

cat("\n---- LS_2310 的「1」逐人判定 ----\n")
ones_2310 %>%
  count(category, branch, name = "n") %>%
  pivot_wider(names_from = category, values_from = n, values_fill = 0L) %>%
  as.data.frame() %>% print(row.names = FALSE)
cat("實際被改成 0 的筆數：", sum(ones_2310$value_after == 0), "\n")

merged <- work %>%
  left_join(ones_2310 %>% select(category, memberId, value_after),
            by = c("category", "memberId")) %>%
  mutate(value = if_else(wave == "LS_2310" & value_parsed == 1 & !is.na(value_after),
                         value_after, value_parsed)) %>%
  select(category, memberId, wave, raw, value)

# --- 值域檢查 ---------------------------------------------------------------
bad <- merged %>% filter(value < VALUE_RANGE[1] | value > VALUE_RANGE[2])
if (nrow(bad) > 0) {
  cat("\n⚠️ 轉換後有值落在宣告值域", VALUE_RANGE[1], "-", VALUE_RANGE[2], "外：\n")
  print(as.data.frame(count(bad, category, wave, value, name = "n")), row.names = FALSE)
  stop("值域檢查沒過。", call. = FALSE)
}

cat("\n---- 各波轉換前後的值域 ----\n")
merged %>%
  group_by(wave) %>%
  summarise(n = n(),
            before = paste0(min(parse_value(raw)), "–", max(parse_value(raw))),
            after  = paste0(min(value), "–", max(value)), .groups = "drop") %>%
  mutate(wave = factor(wave, levels = names(sort(WAVE_MONTH)))) %>%
  arrange(wave) %>% as.data.frame() %>% print(row.names = FALSE)


# =============================================================================
# SECTION 4 — 個人層級：平均、標準差、偏離標記
# =============================================================================

per_id <- merged %>%
  group_by(category, memberId) %>%
  summarise(n_answered = n(),
            mean = mean(value),
            sd   = if (n() >= 2) sd(value) else NA_real_,
            .groups = "drop")

deviation <- merged %>%
  left_join(per_id, by = c("category", "memberId")) %>%
  mutate(deviation = value - mean) %>%
  filter(n_answered >= 2, abs(deviation) > DEVIATION_TOL)

# --- 各 category 的整體平均與標準差 -----------------------------------------
# 把總變異拆成兩塊，才看得出「跨波差 5 分」到底算不算多：
#   between = 人與人之間的差（每個人的平均值彼此差多少）
#   within  = 同一個人跨波的差（每個人自己的標準差，取平均）
stats_overall <- merged %>%
  group_by(category) %>%
  summarise(n_answers = n(), n_ids = n_distinct(memberId),
            mean = mean(value), sd = sd(value),
            median = median(value),
            p25 = quantile(value, .25), p75 = quantile(value, .75),
            .groups = "drop") %>%
  left_join(
    # 每個 ID 在該 category 底下自己的 sd（跨波），再算這些個體 sd 的
    # 平均與標準差 —— 也就是「一般人跨波會晃多少、這個晃動本身多不一致」。
    # 只答過一波的人沒有 sd，不納入。
    per_id %>%
      group_by(category) %>%
      summarise(sd_between_person   = sd(mean),
                mean_of_id_sd       = mean(sd, na.rm = TRUE),
                sd_of_id_sd         = sd(sd, na.rm = TRUE),
                median_of_id_sd     = median(sd, na.rm = TRUE),
                p90_of_id_sd        = quantile(sd, .9, na.rm = TRUE),
                max_of_id_sd        = max(sd, na.rm = TRUE),
                .groups = "drop"),
    by = "category") %>%
  left_join(
    merged %>% group_by(category, memberId) %>%
      summarise(rng = max(value) - min(value), n = n(), .groups = "drop") %>%
      filter(n >= 2) %>%
      group_by(category) %>%
      summarise(n_ids_2plus = n(),
                mean_range = mean(rng), median_range = median(rng),
                p90_range = quantile(rng, .9), .groups = "drop"),
    by = "category") %>%
  mutate(across(where(is.numeric), ~round(.x, 4)))

stats_by_wave <- merged %>%
  group_by(category, wave) %>%
  summarise(n = n(), mean = round(mean(value), 4), sd = round(sd(value), 4),
            median = median(value), .groups = "drop") %>%
  mutate(wave = factor(wave, levels = names(sort(WAVE_MONTH)))) %>%
  arrange(category, wave) %>%
  mutate(wave = as.character(wave))

cat("\n---- 各 category 的整體平均與標準差 ----\n")
stats_overall %>%
  select(category, n_answers, n_ids, mean, sd, median, p25, p75) %>%
  as.data.frame() %>% print(row.names = FALSE)
cat("\n---- 每個 ID 自己的跨波 sd，其平均與標準差 ----\n")
stats_overall %>%
  select(category, n_ids_2plus, mean_of_id_sd, sd_of_id_sd,
         median_of_id_sd, p90_of_id_sd, max_of_id_sd) %>%
  as.data.frame() %>% print(row.names = FALSE)
cat("\n---- 對照：人與人之間 vs 同一個人跨波 ----\n")
stats_overall %>%
  select(category, sd, sd_between_person, mean_of_id_sd,
         mean_range, median_range, p90_range) %>%
  as.data.frame() %>% print(row.names = FALSE)

cat("\n---- 偏離個人平均 ±", DEVIATION_TOL, " 以外的作答 ----\n", sep = "")
deviation %>%
  count(category, name = "n_flagged_answers") %>%
  left_join(deviation %>% distinct(category, memberId) %>%
              count(category, name = "n_flagged_ids"), by = "category") %>%
  left_join(per_id %>% filter(n_answered >= 2) %>%
              count(category, name = "n_ids_with_2plus"), by = "category") %>%
  as.data.frame() %>% print(row.names = FALSE)


# =============================================================================
# SECTION 5 — 組寬表
# =============================================================================

wave_levels <- names(sort(WAVE_MONTH))

# 每個 ID 的全部作答攤成一行字串，放進診斷表當上下文
all_values_str <- merged %>%
  mutate(wave = factor(wave, levels = wave_levels)) %>%
  arrange(category, memberId, wave) %>%
  group_by(category, memberId) %>%
  summarise(all_values = paste0(wave, "=", value, collapse = " | "), .groups = "drop")

build_wide <- function(ct, value_col) {
  d <- merged %>% filter(category == ct)
  waves_here <- intersect(wave_levels, unique(d$wave))
  wide <- d %>%
    select(memberId, wave, !!sym(value_col)) %>%
    pivot_wider(names_from = wave, values_from = !!sym(value_col)) %>%
    select(memberId, all_of(waves_here))
  wide
}

n_flagged_by_id <- deviation %>% count(category, memberId, name = "n_flagged")

category_sheets <- map(CATEGORIES, function(ct) {
  build_wide(ct, "value") %>%
    left_join(per_id %>% filter(category == ct) %>%
                select(memberId, n_answered, mean, sd), by = "memberId") %>%
    left_join(n_flagged_by_id %>% filter(category == ct) %>%
                select(memberId, n_flagged), by = "memberId") %>%
    mutate(n_flagged = coalesce(n_flagged, 0L),
           mean = round(mean, 4), sd = round(sd, 4)) %>%
    arrange(desc(n_answered), memberId)
})
names(category_sheets) <- CATEGORIES

if (KEEP_RAW_SHEETS) {
  raw_sheets <- map(CATEGORIES, function(ct) build_wide(ct, "raw") %>% arrange(memberId))
  names(raw_sheets) <- paste0("_RAW_", str_remove(CATEGORIES, "^0~10_政黨喜愛_"))
} else {
  raw_sheets <- list()
}

# 對帳：寬表裡的非 NA 格數必須等於原始作答數扣掉無法轉換的
n_cells <- sum(map_int(CATEGORIES, function(ct) {
  w <- category_sheets[[ct]]
  waves_here <- intersect(wave_levels, names(w))
  sum(!is.na(as.matrix(w[, waves_here, drop = FALSE])))
}))

cat("\n---- 對帳 ----\n")
cat("原始作答數：        ", N_RAW_ANSWERS, "\n")
cat("無法轉換：          ", N_UNCONVERTED, "\n")
cat("進入寬表的格數：    ", n_cells, "\n")
if (n_cells + N_UNCONVERTED != N_RAW_ANSWERS) {
  stop("對帳沒對上：", n_cells, " + ", N_UNCONVERTED, " != ", N_RAW_ANSWERS, call. = FALSE)
}
cat("對上了。\n")


# =============================================================================
# SECTION 6 — 檢查用的 sheet 與輸出
# =============================================================================

index_tbl <- map_dfr(CATEGORIES, function(ct) {
  w <- category_sheets[[ct]]
  d <- per_id %>% filter(category == ct)
  tibble(
    category        = ct,
    n_waves         = length(intersect(wave_levels, names(w))),
    waves           = paste(intersect(wave_levels, names(w)), collapse = ", "),
    n_ids           = nrow(w),
    n_answers       = sum(d$n_answered),
    n_ids_1wave     = sum(d$n_answered == 1),
    n_ids_2plus     = sum(d$n_answered >= 2),
    n_ids_flagged   = sum(w$n_flagged > 0),
    n_answers_flagged = sum(w$n_flagged),
    id_split_done   = FALSE   # 這一版只標記不拆，等門檻確定後再做
  )
})

coverage <- merged %>%
  count(category, wave, name = "n_answered") %>%
  mutate(wave = factor(wave, levels = wave_levels)) %>%
  arrange(wave) %>%
  pivot_wider(names_from = wave, values_from = n_answered) %>%
  as.data.frame()

# 全距要算該人**所有**作答的 max−min，不能只算被標記的那幾筆
# （只算被標記的會出現 range = 0 卻被標記這種看不懂的列）。
span_all <- merged %>%
  group_by(category, memberId) %>%
  summarise(min_value = min(value), max_value = max(value),
            range = max(value) - min(value), .groups = "drop")

deviation_by_id <- deviation %>%
  group_by(category, memberId) %>%
  summarise(n_answered = first(n_answered),
            mean = round(first(mean), 4),
            sd   = round(first(sd), 4),
            n_flagged = n(),
            max_abs_deviation = round(max(abs(deviation)), 4),
            .groups = "drop") %>%
  left_join(span_all, by = c("category", "memberId")) %>%
  left_join(all_values_str, by = c("category", "memberId")) %>%
  select(category, memberId, n_answered, mean, sd, min_value, max_value, range,
         n_flagged, max_abs_deviation, all_values) %>%
  arrange(desc(range), desc(max_abs_deviation), category, memberId)

rule_2310_sheet <- ones_2310 %>%
  select(category, memberId, branch, value_before, value_after,
         n_other, n_zero, n_one, other_values) %>%
  arrange(category, branch, memberId)

sheets <- c(
  list(`_INDEX` = index_tbl, `_COVERAGE` = coverage),
  category_sheets,
  raw_sheets,
  list(`_STATS_OVERALL`   = stats_overall,
       `_STATS_BY_WAVE`   = stats_by_wave,
       `_2310_ONE_RULE`   = rule_2310_sheet,
       `_DEVIATION_BY_ID` = deviation_by_id,
       `_UNCONVERTED`     = unconverted)
)

# Excel sheet 名稱：不得含 : \ / ? * [ ]，長度 <= 31，且唯一
names(sheets) <- make.unique(substr(str_replace_all(names(sheets),
                                    "[:\\\\/?*\\[\\]]", "_"), 1, 31), sep = "_")

out_path <- file.path(OUT_DIR, OUT_XLSX)
write_xlsx(sheets, out_path)

cat("\n---- 三個 category 概況 ----\n")
index_tbl %>%
  select(category, n_waves, n_ids, n_answers, n_ids_1wave,
         n_ids_flagged, n_answers_flagged) %>%
  as.data.frame() %>% print(row.names = FALSE)

cat("\n寫出：", out_path, "（", length(sheets), " 個 sheet）\n", sep = "")
cat("\n注意：這一版只標記偏離、不拆 ID。memberId 全部維持原樣，\n")
cat("      等門檻確定後再做 -1 / -2 的拆分。\n")
