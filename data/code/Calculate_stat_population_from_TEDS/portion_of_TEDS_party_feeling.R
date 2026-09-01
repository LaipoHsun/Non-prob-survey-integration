# =============================================================================
# TEDS 政黨情感溫度計 (0-10) marginal distribution —— 未加權
#
#   題目：「我們想要請您用0到10來表示您對國內幾個政黨的看法，0表示您『非常不
#          喜歡』這個政黨，10表示您『非常喜歡』這個政黨。」
#          a = 國民黨   b = 民進黨   c = 台灣民眾黨
#
#   TEDS2024 獨立樣本 (Independence)：P2a  / P2b  / P2c
#   TEDS2024 定群樣本 (Panel)        ：PP2a / PP2b / PP2c
#   TEDS2025                         ：G2a  / G2b  / G2c   （同一題，變數改名）
#
#   輸出：data/output/portion_of_TEDS/{2024_ind, 2024_pan, 2025}/
#           fig_party_feeling.png
#           table_party_feeling.csv
#           table_party_feeling.md
# =============================================================================

# 確保中文在 Rscript (C locale) 下不會被丟失
invisible(suppressWarnings(Sys.setlocale("LC_ALL", "zh_TW.UTF-8")))
if (!grepl("UTF-8", Sys.getlocale("LC_CTYPE"), fixed = TRUE))
  invisible(suppressWarnings(Sys.setlocale("LC_ALL", "en_US.UTF-8")))

suppressPackageStartupMessages({
  library(haven)
  library(dplyr)
  library(ggplot2)
  library(scales)
})

# ---- 專案路徑 ---------------------------------------------------------------
find_root <- function() {
  p <- normalizePath(getwd())
  while (!file.exists(file.path(p, "data", "code")) && dirname(p) != p) p <- dirname(p)
  if (!file.exists(file.path(p, "data", "code"))) stop("找不到專案根目錄（需含 data/code）")
  p
}
root     <- find_root()
teds_dir <- file.path(root, "data", "TEDS")
out_root <- file.path(root, "data", "output", "portion_of_TEDS")

# ---- 資料集設定 -------------------------------------------------------------
datasets <- list(
  list(tag   = "2024_ind",
       title = "TEDS2024 面訪 獨立樣本",
       year  = 2024,
       file  = file.path(teds_dir, "TEDS2024/Independence/TEDS2024_indQ.sav"),
       enc   = "CP950",
       vars  = c("國民黨" = "P2a", "民進黨" = "P2b", "台灣民眾黨" = "P2c")),
  list(tag   = "2024_pan",
       title = "TEDS2024 面訪 定群樣本",
       year  = 2024,
       file  = file.path(teds_dir, "TEDS2024/Panel/TEDS2024_panQ.sav"),
       enc   = "CP950",
       vars  = c("國民黨" = "PP2a", "民進黨" = "PP2b", "台灣民眾黨" = "PP2c")),
  list(tag   = "2025",
       title = "TEDS2025",
       year  = 2025,
       file  = file.path(teds_dir, "TEDS2025/TEDS2025/TEDS2025.sav"),
       enc   = "UTF-8",
       vars  = c("國民黨" = "G2a", "民進黨" = "G2b", "台灣民眾黨" = "G2c"))
)

party_levels <- c("國民黨", "民進黨", "台灣民眾黨")
party_cols   <- c("國民黨" = "#000095", "民進黨" = "#1B9431", "台灣民眾黨" = "#28C8C8")

# 非實質回答的代碼（不列入 0-10 有效分配）
missing_codes <- c("95" = "拒答", "96" = "沒聽過", "97" = "無意見", "98" = "不知道", "99" = "跳題")

value_label <- function(v) {
  ifelse(v == 0,  "0 非常不喜歡",
  ifelse(v == 10, "10 非常喜歡",
  ifelse(as.character(v) %in% names(missing_codes),
         paste(v, missing_codes[as.character(v)]), as.character(v))))
}

# ---- 單一資料集的次數分配 ---------------------------------------------------
tabulate_one <- function(cfg) {
  dat <- read_sav(cfg$file, encoding = cfg$enc)

  long <- lapply(names(cfg$vars), function(p) {
    data.frame(party = p, var = cfg$vars[[p]],
               value = as.numeric(dat[[cfg$vars[[p]]]]))
  }) |> bind_rows()

  # NA = 未受訪／系統遺漏，不列入任何分母，只在表尾註記
  n_na <- long |> filter(is.na(value)) |> count(party, var, name = "n_na")
  ans  <- long |> filter(!is.na(value))

  counts <- ans |> count(party, var, value, name = "n")

  base <- counts |>
    group_by(party, var) |> summarise(n_base = sum(n), .groups = "drop")
  valid_base <- counts |> filter(value <= 10) |>
    group_by(party, var) |> summarise(n_valid = sum(n), .groups = "drop")

  tab <- counts |>
    left_join(base, by = c("party", "var")) |>
    left_join(valid_base, by = c("party", "var")) |>
    arrange(party, value) |>
    group_by(party, var) |>
    mutate(
      label         = value_label(value),
      pct_all       = round(100 * n / n_base, 2),
      pct_valid     = ifelse(value <= 10, round(100 * n / n_valid, 2), NA_real_),
      cum_pct_valid = ifelse(value <= 10,
                             round(cumsum(ifelse(is.na(pct_valid), 0, pct_valid)), 2),
                             NA_real_)
    ) |>
    ungroup() |>
    select(party, var, value, label, n, pct_all, pct_valid, cum_pct_valid)

  total_row <- base |>
    transmute(party, var, value = NA_real_,
              label = "總計（有效作答＋拒答/不知道）",
              n = n_base, pct_all = 100, pct_valid = NA_real_, cum_pct_valid = NA_real_)

  na_row <- n_na |>
    transmute(party, var, value = NA_real_,
              label = "未受訪／系統遺漏（不計入分母）",
              n = n_na, pct_all = NA_real_, pct_valid = NA_real_, cum_pct_valid = NA_real_)

  tab <- bind_rows(tab, total_row, na_row) |>
    mutate(dataset = cfg$tag, year = cfg$year, .before = 1) |>
    mutate(party = factor(party, levels = party_levels)) |>
    arrange(party)

  # 平均數／標準差僅供 .md 表尾註記（不另存 summary 檔）
  smry <- ans |>
    filter(value <= 10) |>
    group_by(party, var) |>
    summarise(n_valid = n(), mean = mean(value), sd = sd(value),
              median = median(value), .groups = "drop") |>
    left_join(n_na, by = c("party", "var")) |>
    mutate(party = factor(party, levels = party_levels)) |>
    arrange(party)

  list(table = tab, summary = smry, cfg = cfg)
}

# ---- 繪圖：三黨畫在同一張 ---------------------------------------------------
make_plot <- function(res) {
  cfg <- res$cfg
  d <- res$table |> filter(!is.na(value), value <= 10)

  sub <- res$summary |>
    mutate(lab = sprintf("%s（有效 N=%s, 平均=%.2f）", party,
                         format(n_valid, big.mark = ","), mean)) |>
    pull(lab) |> paste(collapse = "　")

  ggplot(d, aes(x = factor(value, levels = 0:10), y = pct_valid, fill = party)) +
    geom_col(position = position_dodge(width = 0.8), width = 0.75,
             alpha = 0.9, colour = NA) +
    geom_text(aes(label = format(n, big.mark = ","), colour = party),
              position = position_dodge(width = 0.8), vjust = -0.4, size = 2.4,
              show.legend = FALSE) +
    scale_fill_manual(values = party_cols, drop = FALSE) +
    scale_colour_manual(values = party_cols, drop = FALSE) +
    scale_y_continuous(labels = label_percent(scale = 1),
                       expand = expansion(mult = c(0, .10))) +
    labs(
      title    = sprintf("%s：對三大政黨的情感溫度計（0-10）", cfg$title),
      subtitle = paste0("0＝非常不喜歡，10＝非常喜歡；百分比以 0-10 有效作答為分母",
                        "（排除拒答／不知道）；長條上方數字為 n\n", sub),
      x = "情感溫度計分數", y = "百分比", fill = NULL,
      caption = sprintf("變數：%s. 未加權. 資料來源：TEDS", paste(cfg$vars, collapse = " / "))
    ) +
    theme_minimal(base_size = 12, base_family = "Heiti TC") +
    theme(legend.position = "top",
          panel.grid.major.x = element_blank(),
          plot.title = element_text(face = "bold"),
          plot.subtitle = element_text(size = 9),
          plot.caption = element_text(size = 8, colour = "grey40"))
}

# ---- markdown 版表格（方便閱讀） --------------------------------------------
write_md <- function(res, path) {
  cfg <- res$cfg
  con <- file(path, open = "w", encoding = "UTF-8"); on.exit(close(con))
  writeLines(sprintf("# %s：對三大政黨的情感溫度計（0-10）marginal distribution\n", cfg$title), con)
  writeLines(sprintf("變數：%s\n",
                     paste(sprintf("%s = %s", names(cfg$vars), cfg$vars), collapse = "、")), con)
  writeLines("未加權。% (全體) 分母為有作答此題者（含拒答/不知道）；% (有效) 分母為 0-10 作答者。\n", con)
  f <- function(x) ifelse(is.na(x), "—", format(x, big.mark = ","))
  for (p in party_levels) {
    d <- res$table |> filter(party == p)
    s <- res$summary |> filter(party == p)
    writeLines(sprintf("\n## %s（%s）\n", p, cfg$vars[[p]]), con)
    writeLines("| 回答 | n | % (全體) | % (有效) | 累積 % (有效) |", con)
    writeLines("|---|---:|---:|---:|---:|", con)
    for (i in seq_len(nrow(d)))
      writeLines(sprintf("| %s | %s | %s | %s | %s |", d$label[i], f(d$n[i]),
                         f(d$pct_all[i]), f(d$pct_valid[i]), f(d$cum_pct_valid[i])), con)
    writeLines(sprintf("\n有效 N = %s；平均數 = %.3f；標準差 = %.3f；中位數 = %s",
                       format(s$n_valid, big.mark = ","), s$mean, s$sd, s$median), con)
  }
}

# ---- 主流程 -----------------------------------------------------------------
for (cfg in datasets) {
  message("處理：", cfg$tag)
  out_dir <- file.path(out_root, cfg$tag)
  dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)

  res <- tabulate_one(cfg)
  write.csv(res$table, file.path(out_dir, "table_party_feeling.csv"),
            row.names = FALSE, fileEncoding = "UTF-8")
  write_md(res, file.path(out_dir, "table_party_feeling.md"))
  ggsave(file.path(out_dir, "fig_party_feeling.png"), make_plot(res),
         width = 10, height = 6, dpi = 300)
}

message("完成，輸出於：", out_root)
