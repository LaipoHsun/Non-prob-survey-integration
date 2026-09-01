# =============================================================================
# TEDS 人口學變數 marginal distribution —— 未加權
#
#   性別、年齡、教育程度、省籍（父親）、居住縣市
#
#                 2024_ind   2024_pan   2025
#     性別        SEX        PSEX       SEX
#     年齡        AGE        PAGE       AGE
#     教育程度    EDU        PEDU       EDU
#     省籍        Q2         PQ2        H2a
#     居住縣市    City       PCity      City
#
#   註：定群樣本（Panel）採 P 開頭版本，與 2024 該波受訪者一致；未受訪者
#       (1,575 人) 在該波為 NA，列於表尾且不計入分母。
#   註：AGE 分組兩年不同（2024 為 20-29 起 5 組；2025 為 18-19 起 6 組），
#       依各年原始編碼呈現，不強行合併。
#
#   輸出：data/output/portion_of_TEDS/{2024_ind, 2024_pan, 2025}/
#           fig_sex.png  fig_age.png  fig_edu.png  fig_ethnicity.png  fig_city.png
#           table_demographics.csv
#           table_demographics.md
# =============================================================================

invisible(suppressWarnings(Sys.setlocale("LC_ALL", "zh_TW.UTF-8")))
if (!grepl("UTF-8", Sys.getlocale("LC_CTYPE"), fixed = TRUE))
  invisible(suppressWarnings(Sys.setlocale("LC_ALL", "en_US.UTF-8")))

suppressPackageStartupMessages({
  library(haven)
  library(dplyr)
  library(ggplot2)
  library(scales)
})

find_root <- function() {
  p <- normalizePath(getwd())
  while (!file.exists(file.path(p, "data", "code")) && dirname(p) != p) p <- dirname(p)
  if (!file.exists(file.path(p, "data", "code"))) stop("找不到專案根目錄（需含 data/code）")
  p
}
root     <- find_root()
teds_dir <- file.path(root, "data", "TEDS")
out_root <- file.path(root, "data", "output", "portion_of_TEDS")

# ---- 設定 -------------------------------------------------------------------
demo_vars <- c(sex = "性別", age = "年齡", edu = "教育程度",
               ethnicity = "省籍（父親）", city = "居住縣市")

datasets <- list(
  list(tag = "2024_ind", title = "TEDS2024 面訪 獨立樣本", year = 2024,
       file = file.path(teds_dir, "TEDS2024/Independence/TEDS2024_indQ.sav"), enc = "CP950",
       vars = c(sex = "SEX", age = "AGE", edu = "EDU", ethnicity = "Q2", city = "City")),
  list(tag = "2024_pan", title = "TEDS2024 面訪 定群樣本", year = 2024,
       file = file.path(teds_dir, "TEDS2024/Panel/TEDS2024_panQ.sav"), enc = "CP950",
       vars = c(sex = "PSEX", age = "PAGE", edu = "PEDU", ethnicity = "PQ2", city = "PCity")),
  list(tag = "2025", title = "TEDS2025", year = 2025,
       file = file.path(teds_dir, "TEDS2025/TEDS2025/TEDS2025.sav"), enc = "UTF-8",
       vars = c(sex = "SEX", age = "AGE", edu = "EDU", ethnicity = "H2a", city = "City"))
)

# 依 value label 判定「非實質回答」，不計入 % (有效) 的分母
nonsubstantive <- c("拒答", "不知道", "無意見", "看情形", "跳題", "無反應", "沒聽過", "遺漏值")

bar_col <- "#3F6C8F"

# ---- 單一資料集 × 單一變數 --------------------------------------------------
tabulate_var <- function(dat, cfg, key) {
  v    <- cfg$vars[[key]]
  x    <- dat[[v]]
  labs <- attr(x, "labels")
  num  <- as.numeric(x)

  lab_of <- function(val) {
    if (is.null(labs)) return(as.character(val))
    m <- match(val, as.numeric(labs))
    ifelse(is.na(m), as.character(val), names(labs)[m])
  }

  n_na <- sum(is.na(num))
  ans  <- num[!is.na(num)]

  tab <- as.data.frame(table(value = ans), stringsAsFactors = FALSE) |>
    transmute(value = as.numeric(value), n = Freq) |>
    arrange(value) |>
    mutate(label = lab_of(value),
           valid = !(label %in% nonsubstantive))

  n_base  <- sum(tab$n)
  n_valid <- sum(tab$n[tab$valid])

  tab <- tab |>
    mutate(pct_all       = round(100 * n / n_base, 2),
           pct_valid     = ifelse(valid, round(100 * n / n_valid, 2), NA_real_),
           cum_pct_valid = round(cumsum(ifelse(is.na(pct_valid), 0, pct_valid)), 2),
           cum_pct_valid = ifelse(valid, cum_pct_valid, NA_real_))

  out <- tab |> select(value, label, n, pct_all, pct_valid, cum_pct_valid)

  out <- bind_rows(
    out,
    data.frame(value = NA_real_, label = "總計（有效＋非實質回答）", n = n_base,
               pct_all = 100, pct_valid = NA_real_, cum_pct_valid = NA_real_),
    data.frame(value = NA_real_, label = "未受訪／系統遺漏（不計入分母）", n = n_na,
               pct_all = NA_real_, pct_valid = NA_real_, cum_pct_valid = NA_real_)
  )

  out |> mutate(dataset = cfg$tag, year = cfg$year,
                variable = demo_vars[[key]], var = v, .before = 1)
}

# ---- 繪圖：單一變數 ---------------------------------------------------------
make_plot <- function(d, cfg, key) {
  v  <- cfg$vars[[key]]
  dd <- d |> filter(!is.na(value), !is.na(pct_valid))
  horizontal <- key == "city"           # 縣市類別多，改橫向並依比例排序

  dd$label <- if (horizontal) factor(dd$label, levels = dd$label[order(dd$pct_valid)])
              else            factor(dd$label, levels = dd$label[order(dd$value)])

  n_valid <- sum(dd$n)
  p <- ggplot(dd, aes(x = label, y = pct_valid)) +
    geom_col(fill = bar_col, width = 0.7, alpha = 0.9) +
    geom_text(aes(label = sprintf("%s (%.1f%%)", format(n, big.mark = ","), pct_valid)),
              hjust = if (horizontal) -0.08 else 0.5,
              vjust = if (horizontal) 0.5 else -0.4, size = 2.8) +
    scale_y_continuous(labels = label_percent(scale = 1),
                       expand = expansion(mult = c(0, .15))) +
    labs(title    = sprintf("%s：%s", cfg$title, demo_vars[[key]]),
         subtitle = sprintf("百分比以有效樣本為分母（排除拒答／不知道／無反應）；有效 N = %s",
                            format(n_valid, big.mark = ",")),
         x = NULL, y = "百分比",
         caption = sprintf("變數：%s. 未加權. 資料來源：TEDS", v)) +
    theme_minimal(base_size = 12, base_family = "Heiti TC") +
    theme(plot.title = element_text(face = "bold"),
          plot.subtitle = element_text(size = 9),
          plot.caption = element_text(size = 8, colour = "grey40"))

  if (horizontal) p + coord_flip() + theme(panel.grid.major.y = element_blank())
  else            p + theme(panel.grid.major.x = element_blank())
}

# ---- markdown ---------------------------------------------------------------
write_md <- function(tab, cfg, path) {
  con <- file(path, open = "w", encoding = "UTF-8"); on.exit(close(con))
  writeLines(sprintf("# %s：人口學變數 marginal distribution\n", cfg$title), con)
  writeLines("未加權。% (全體) 分母為有作答者（含拒答/不知道/無反應）；% (有效) 分母為排除這些後的有效樣本。\n", con)
  f <- function(x) ifelse(is.na(x), "—", format(x, big.mark = ","))
  for (key in names(demo_vars)) {
    d <- tab |> filter(variable == demo_vars[[key]])
    writeLines(sprintf("\n## %s（%s）\n", demo_vars[[key]], cfg$vars[[key]]), con)
    writeLines("| 類別 | code | n | % (全體) | % (有效) | 累積 % (有效) |", con)
    writeLines("|---|---:|---:|---:|---:|---:|", con)
    for (i in seq_len(nrow(d)))
      writeLines(sprintf("| %s | %s | %s | %s | %s | %s |",
                         d$label[i], f(d$value[i]), f(d$n[i]),
                         f(d$pct_all[i]), f(d$pct_valid[i]), f(d$cum_pct_valid[i])), con)
  }
  if (cfg$tag == "2025")
    writeLines("\n> 註：2025 年齡分組自 18-19 歲起共 6 組，與 2024（20-29 歲起 5 組）不同，比較時請留意。", con)
  if (cfg$tag == "2024_pan")
    writeLines("\n> 註：定群樣本採 2024 該波（P 開頭）變數；1,575 位追蹤失敗者在該波為系統遺漏，不計入分母。", con)
}

# ---- 主流程 -----------------------------------------------------------------
for (cfg in datasets) {
  message("處理：", cfg$tag)
  out_dir <- file.path(out_root, cfg$tag)
  dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)

  dat <- read_sav(cfg$file, encoding = cfg$enc)
  tabs <- lapply(names(demo_vars), function(k) tabulate_var(dat, cfg, k)) |> bind_rows()

  write.csv(tabs, file.path(out_dir, "table_demographics.csv"),
            row.names = FALSE, fileEncoding = "UTF-8")
  write_md(tabs, cfg, file.path(out_dir, "table_demographics.md"))

  for (k in names(demo_vars)) {
    d <- tabs |> filter(variable == demo_vars[[k]])
    ggsave(file.path(out_dir, sprintf("fig_%s.png", k)), make_plot(d, cfg, k),
           width = if (k == "city") 9 else 8,
           height = if (k == "city") 7 else 5.5, dpi = 300)
  }
}

message("完成，輸出於：", out_root)
