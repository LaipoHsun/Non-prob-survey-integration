# =============================================================================
#  pool_joint_TEDS.R —— 合併多個年份的 TEDS 聯合表，做成一份較大的母體聯合表
#
#  用法：Rscript data/code/Calculate_stat_population_from_TEDS/pool_joint_TEDS.R
#  前提：先跑過 joint_distribution_TEDS.R（產生各年份的 joint_full_raw.csv）
#
#  做法：
#    1. 讀 SOURCES 各年份的 portion_of_TEDS/<年份>/joint/joint_full_raw.csv
#       （一列一格：8 個變數、n = 人數、n_wt = W 加權人數）
#    2. 類別標籤統一成 LABEL_MAP 指定的用詞
#       （2024 的「高屏澎湖區／花東外島區」→ 2025 的「高屏區／花東區」）
#    3. 權數：各年份 W 的平均約為 1。
#         WEIGHT_MODE = "as_is"  直接相加，各年份在合併母體中的佔比 ∝ 樣本數
#         WEIGHT_MODE = "equal"  先把每個年份的 n_wt 調成相同總和，各年份佔比相同
#    4. 依 8 個變數加總 n 與 n_wt，輸出同格式的 joint_full_raw.csv 到
#       portion_of_TEDS/<OUT_NAME>/joint/，加權程式用 joint=<OUT_NAME> 讀取
#
#  注意：2024 的第 5、6 區含澎湖與金馬，2025 不含；外島受訪者很少，合併後以 2025 的用詞為準。
#        2024 沒有 18–19 歲組（加權程式用 age A2 時兩邊都排除）。
#        各年份是不同時間點的調查，合併等於假設這段期間母體結構沒有明顯變化。
# =============================================================================

SOURCES     <- c("2024_ind", "2024_pan", "2025")
OUT_NAME    <- "pooled"
WEIGHT_MODE <- "as_is"     # "as_is" / "equal"
LABEL_MAP   <- list(arear = c("高屏澎湖區" = "高屏區", "花東外島區" = "花東區"))
VARS        <- c("sex", "age", "edu", "arear", "ethnicity", "party_kmt", "party_dpp", "party_tpp")

# ############################################################################

invisible(suppressWarnings(Sys.setlocale("LC_ALL", "zh_TW.UTF-8")))
if (!grepl("UTF-8", Sys.getlocale("LC_CTYPE"), fixed = TRUE))
  invisible(suppressWarnings(Sys.setlocale("LC_ALL", "en_US.UTF-8")))
suppressPackageStartupMessages(library(dplyr))

find_root <- function() {
  p <- normalizePath(getwd())
  while (!file.exists(file.path(p, "data", "code")) && dirname(p) != p) p <- dirname(p)
  if (!file.exists(file.path(p, "data", "code"))) stop("找不到專案根目錄（需含 data/code）")
  p
}
root     <- find_root()
base_dir <- file.path(root, "data", "output", "portion_of_TEDS")
out_dir  <- file.path(base_dir, OUT_NAME, "joint")
dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)
if (!WEIGHT_MODE %in% c("as_is", "equal")) stop("WEIGHT_MODE 必須是 \"as_is\" 或 \"equal\"")

parts <- lapply(SOURCES, function(s) {
  p <- file.path(base_dir, s, "joint", "joint_full_raw.csv")
  if (!file.exists(p)) stop("找不到 ", p, "；請先跑 joint_distribution_TEDS.R")
  d <- read.csv(p, fileEncoding = "UTF-8", colClasses = "character", check.names = FALSE)
  miss <- setdiff(c(VARS, "n", "n_wt"), names(d))
  if (length(miss)) stop(s, " 的聯合表缺少欄位：", paste(miss, collapse = ", "))
  d <- d[c(VARS, "n", "n_wt")]
  for (v in names(LABEL_MAP)) {
    hit <- d[[v]] %in% names(LABEL_MAP[[v]])
    d[[v]][hit] <- unname(LABEL_MAP[[v]][d[[v]][hit]])
  }
  d$n    <- as.numeric(d$n)
  d$n_wt <- as.numeric(d$n_wt)
  d$source <- s
  d
})

src <- bind_rows(lapply(parts, function(d)
  data.frame(source = d$source[1], cells = nrow(d), n = sum(d$n), n_wt = sum(d$n_wt))))
if (identical(WEIGHT_MODE, "equal")) {
  target_total <- mean(src$n_wt)
  parts <- lapply(parts, function(d) { d$n_wt <- d$n_wt / sum(d$n_wt) * target_total; d })
}
src$n_wt_used  <- vapply(parts, function(d) sum(d$n_wt), numeric(1))
src$share_used <- 100 * src$n_wt_used / sum(src$n_wt_used)

pooled <- bind_rows(parts) |>
  group_by(across(all_of(VARS))) |>
  summarise(n = sum(n), n_wt = sum(n_wt), n_sources = n_distinct(source), .groups = "drop") |>
  arrange(desc(n))
pooled$prop    <- pooled$n / sum(pooled$n)
pooled$prop_wt <- pooled$n_wt / sum(pooled$n_wt)
pooled$cell    <- do.call(paste, c(pooled[VARS], sep = " | "))

write.csv(pooled, file.path(out_dir, "joint_full_raw.csv"), row.names = FALSE, fileEncoding = "UTF-8")
write.csv(src, file.path(out_dir, "pooled_sources.csv"), row.names = FALSE, fileEncoding = "UTF-8")

message("合併來源（WEIGHT_MODE = ", WEIGHT_MODE, "）：")
for (i in seq_len(nrow(src)))
  message(sprintf("  %-9s %5d 格  n = %5.0f  n_wt = %7.1f → %7.1f（佔 %.1f%%）", src$source[i], src$cells[i],
                  src$n[i], src$n_wt[i], src$n_wt_used[i], src$share_used[i]))
message(sprintf("合併後：%d 格，n = %.0f，n_wt = %.1f；只出現在一個來源的格 %d 個（%.1f%%）",
                nrow(pooled), sum(pooled$n), sum(pooled$n_wt), sum(pooled$n_sources == 1),
                100 * mean(pooled$n_sources == 1)))
for (v in VARS[1:5])
  message(sprintf("  %-9s %s", v, paste(sort(unique(pooled[[v]])), collapse = " / ")))
message("輸出：", file.path(out_dir, "joint_full_raw.csv"))
