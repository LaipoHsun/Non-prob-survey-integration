#!/usr/bin/env Rscript
# =============================================================================
# plot_party_thermometer_ecdf.R  —— 政黨喜愛：個體變異的累積分布圖
#
# 讀 build_party_thermometer.R 產出的 ntuws_party_thermometer.xlsx，
# 取**答過兩波以上**的人，把他們的
#     跨波標準差 sd
#     跨波全距 range（該人所有作答的 max − min）
# 各畫一張累積分布函數（ECDF），三個 category 疊在同一張圖比較，
# 並標出各 category 的 90% 與 95% 分位落在哪裡。
#
# 只產兩張圖，不動任何資料檔，也不重算合併 —— 值全部取自那份 xlsx。
#
# -----------------------------------------------------------------------------
# 執行 —— 工作目錄在哪都可以：
#     LC_ALL=zh_TW.UTF-8 Rscript \
#       data/NTUWS/Code/Phase2_cross_wave_question_matching/party_thermometer/plot_party_thermometer_ecdf.R
#
# -----------------------------------------------------------------------------
# 輸入
#     output/Phase2_cross_wave_question_matching/party_thermometer/
#         ntuws_party_thermometer.xlsx
#
# 輸出（同一個資料夾）
#     ntuws_party_thermometer_ecdf_sd.png
#     ntuws_party_thermometer_ecdf_range.png
#
# -----------------------------------------------------------------------------
# 設計決定
#
#   只取 n_answered >= 2
#     只答過一波的人沒有 sd 也沒有全距可言，畫進去只會把曲線往 0 拉。
#
#   sd 直接取寬表的 sd 欄；range 由波次欄現算
#     寬表沒有 range 欄，所以就地從各波的值算 max − min。
#     這樣兩張圖用的都是同一份已合併的值，不會與主程式不一致。
#
#   分位數用 type = 1
#     sd 與 range 都是離散的，ECDF 是階梯函數。type = 1 取的是
#     「累積機率首次達到 p 的那個實際觀測值」，與階梯圖上的落點一致；
#     用預設的插值型分位數會標在階梯之間，圖上對不起來。
#
#   中文字型
#     macOS 上用 quartz 裝置 + Heiti TC。字型找不到就退回英文標籤，
#     不讓圖表變成一堆豆腐方框。
#
# 相依套件：readxl, dplyr, tidyr, ggplot2
# =============================================================================


# =============================================================================
# SECTION 1 — 設定與路徑
# =============================================================================

BATCH    <- "party_thermometer"
PHASE    <- "Phase2_cross_wave_question_matching"
IN_PHASE <- "Phase1_within_wave_duplicates"
IN_XLSX  <- "ntuws_lottery_dedup.xlsx"
SRC_XLSX <- "ntuws_party_thermometer.xlsx"

NTUWS_MARKER <- file.path("output", IN_PHASE, IN_XLSX)

CATEGORIES <- c("0~10_政黨喜愛_國民黨",
                "0~10_政黨喜愛_民進黨",
                "0~10_政黨喜愛_民眾黨")

# 三黨的識別色
PARTY_COLORS <- c("0~10_政黨喜愛_國民黨" = "#0B36A8",
                  "0~10_政黨喜愛_民進黨" = "#1B9431",
                  "0~10_政黨喜愛_民眾黨" = "#00A0A8")

PROBS <- c(0.90, 0.95)

PLOT_W <- 9; PLOT_H <- 6; PLOT_DPI <- 200

suppressPackageStartupMessages({
  library(readxl); library(dplyr); library(tidyr); library(ggplot2)
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

# 中文字型：找得到就用，找不到就把標籤換成英文
CJK_FAMILY <- "Heiti TC"
has_cjk <- .Platform$OS.type == "unix" &&
  capabilities("aqua") &&
  file.exists("/System/Library/Fonts/STHeiti Medium.ttc")
if (!has_cjk) {
  CJK_FAMILY <- ""
  cat("⚠️ 找不到中文字型，圖上的標籤改用英文。\n")
}


# =============================================================================
# SECTION 2 — 取值：sd 直接讀，range 由波次欄現算
# =============================================================================

# 寬表裡不是波次的欄，扣掉才是各波的值
NON_WAVE_COLS <- c("memberId", "n_answered", "mean", "sd", "n_flagged")

per_id <- bind_rows(lapply(CATEGORIES, function(ct) {
  d <- suppressMessages(read_excel(SRC_PATH, sheet = ct))
  wave_cols <- setdiff(names(d), NON_WAVE_COLS)
  m <- as.matrix(d[, wave_cols, drop = FALSE])
  tibble(
    category   = ct,
    memberId   = d$memberId,
    n_answered = d$n_answered,
    sd         = d$sd,
    range      = apply(m, 1, function(r) {
      v <- r[!is.na(r)]
      if (length(v) < 2) NA_real_ else max(v) - min(v)
    })
  )
})) %>%
  filter(n_answered >= 2, !is.na(sd), !is.na(range))

cat("\n答過兩波以上的人：\n")
per_id %>% count(category, name = "n_ids") %>% as.data.frame() %>% print(row.names = FALSE)

# 一致性檢查：range 一定 >= sd（0–10 的量尺上不可能反過來）
if (any(per_id$range < per_id$sd - 1e-9)) {
  stop("有 range < sd 的列，range 算錯了", call. = FALSE)
}


# =============================================================================
# SECTION 3 — 分位數
#
# type = 1：取累積機率首次達到 p 的實際觀測值，與階梯圖的落點一致。
# =============================================================================

quantile_tbl <- function(col) {
  per_id %>%
    group_by(category) %>%
    reframe(prob = PROBS,
            value = quantile(.data[[col]], PROBS, type = 1, names = FALSE)) %>%
    mutate(category = factor(category, levels = CATEGORIES))
}

q_sd    <- quantile_tbl("sd")
q_range <- quantile_tbl("range")

cat("\n---- 個體跨波 sd 的分位數 ----\n")
q_sd %>% mutate(value = round(value, 4)) %>%
  pivot_wider(names_from = prob, values_from = value,
              names_prefix = "P") %>% as.data.frame() %>% print(row.names = FALSE)

cat("\n---- 個體跨波全距的分位數 ----\n")
q_range %>%
  pivot_wider(names_from = prob, values_from = value,
              names_prefix = "P") %>% as.data.frame() %>% print(row.names = FALSE)


# =============================================================================
# SECTION 4 — 畫圖
# =============================================================================

lab <- function(zh, en) if (nzchar(CJK_FAMILY)) zh else en

legend_labels <- if (nzchar(CJK_FAMILY)) {
  c("國民黨", "民進黨", "民眾黨")
} else {
  c("KMT", "DPP", "TPP")
}
names(legend_labels) <- CATEGORIES

# 三黨的 P90 / P95 幾乎重疊（例如 P95 是 2.83 / 2.83 / 2.89），
# 直接把數字標在點上會疊成一團。改成在空白處放一張帶顏色的小表，
# 顏色本身就認得出是哪一黨，所以圖例可以省掉。
make_ecdf_plot <- function(col, qtbl, x_title, main_title, subtitle,
                           x_breaks, table_x, table_y_top) {
  d <- per_id %>% mutate(category = factor(category, levels = CATEGORIES))

  fmt <- if (col == "sd") function(v) sprintf("%.2f", v) else function(v) sprintf("%.0f", v)
  seg <- qtbl %>% mutate(category = factor(category, levels = CATEGORIES))

  # 小表：一列一黨，欄是黨名 / P90 / P95
  row_h <- 0.052
  tab <- qtbl %>%
    mutate(category = factor(category, levels = CATEGORIES)) %>%
    pivot_wider(names_from = prob, values_from = value) %>%
    arrange(category) %>%
    mutate(row = row_number(),
           y   = table_y_top - row * row_h,
           name = legend_labels[as.character(category)],
           v90  = fmt(.data[["0.9"]]),
           v95  = fmt(.data[["0.95"]]))

  hdr <- tibble(
    x     = table_x,
    label = c("", "P90", "P95"),
    y     = table_y_top
  )

  ggplot(d, aes(x = .data[[col]], colour = category)) +
    geom_hline(yintercept = PROBS, linetype = "dotted",
               colour = "grey45", linewidth = .4) +
    stat_ecdf(geom = "step", linewidth = .9, pad = FALSE) +
    geom_segment(data = seg,
                 aes(x = value, xend = value, y = 0, yend = prob, colour = category),
                 linetype = "dashed", linewidth = .45,
                 inherit.aes = FALSE, show.legend = FALSE) +
    geom_point(data = seg, aes(x = value, y = prob, colour = category),
               size = 2.1, inherit.aes = FALSE, show.legend = FALSE) +
    # 小表：表頭 + 三列
    geom_text(data = hdr, aes(x = x, y = y, label = label),
              inherit.aes = FALSE, size = 3.4, colour = "grey30",
              family = CJK_FAMILY, fontface = "bold", hjust = 0) +
    geom_text(data = tab, aes(x = table_x[1], y = y, label = name, colour = category),
              inherit.aes = FALSE, show.legend = FALSE, size = 3.6,
              family = CJK_FAMILY, hjust = 0) +
    geom_text(data = tab, aes(x = table_x[2], y = y, label = v90, colour = category),
              inherit.aes = FALSE, show.legend = FALSE, size = 3.6,
              family = CJK_FAMILY, hjust = 0) +
    geom_text(data = tab, aes(x = table_x[3], y = y, label = v95, colour = category),
              inherit.aes = FALSE, show.legend = FALSE, size = 3.6,
              family = CJK_FAMILY, hjust = 0) +
    scale_colour_manual(values = PARTY_COLORS, labels = legend_labels, name = NULL) +
    scale_x_continuous(breaks = x_breaks) +
    scale_y_continuous(breaks = c(seq(0, 1, .25), PROBS),
                       labels = scales::percent_format(accuracy = 1),
                       limits = c(0, 1), expand = expansion(mult = c(0, .02))) +
    labs(title = main_title, subtitle = subtitle,
         x = x_title, y = lab("累積比例", "cumulative share")) +
    theme_minimal(base_size = 13, base_family = CJK_FAMILY) +
    theme(
      legend.position  = "none",
      panel.grid.minor = element_blank(),
      plot.title       = element_text(face = "bold"),
      plot.subtitle    = element_text(colour = "grey35", size = 10.5),
      plot.margin      = margin(14, 18, 12, 14)
    )
}

n_txt <- per_id %>% count(category) %>%
  mutate(t = paste0(legend_labels[as.character(category)], " ", n)) %>%
  pull(t) %>% paste(collapse = "　")

p_sd <- make_ecdf_plot(
  "sd", q_sd,
  x_title    = lab("該 ID 跨波作答的標準差", "within-person SD across waves"),
  main_title = lab("政黨喜愛：個體跨波標準差的累積分布",
                   "Party thermometer: ECDF of within-person SD"),
  subtitle   = lab(paste0("只含答過兩波以上的人（", n_txt,
                          "）；虛線為各黨的 90% 與 95% 分位"),
                   paste0("respondents with >=2 waves (", n_txt,
                          "); dashed lines mark the 90th and 95th percentiles")),
  x_breaks    = seq(0, 8, 1),
  table_x     = c(4.15, 5.45, 6.25),
  table_y_top = 0.60
)

p_range <- make_ecdf_plot(
  "range", q_range,
  x_title    = lab("該 ID 跨波作答的全距（最大值 − 最小值）",
                   "within-person range across waves (max - min)"),
  main_title = lab("政黨喜愛：個體跨波全距的累積分布",
                   "Party thermometer: ECDF of within-person range"),
  subtitle   = lab(paste0("只含答過兩波以上的人（", n_txt,
                          "）；虛線為各黨的 90% 與 95% 分位"),
                   paste0("respondents with >=2 waves (", n_txt,
                          "); dashed lines mark the 90th and 95th percentiles")),
  x_breaks    = seq(0, 10, 1),
  table_x     = c(5.7, 7.5, 8.6),
  table_y_top = 0.60
)

save_plot <- function(p, file) {
  path <- file.path(DIR, file)
  ggsave(path, p, width = PLOT_W, height = PLOT_H, dpi = PLOT_DPI,
         type = if (nzchar(CJK_FAMILY)) "quartz" else NULL)
  cat("寫出：", path, "\n")
}

save_plot(p_sd,    "ntuws_party_thermometer_ecdf_sd.png")
save_plot(p_range, "ntuws_party_thermometer_ecdf_range.png")
