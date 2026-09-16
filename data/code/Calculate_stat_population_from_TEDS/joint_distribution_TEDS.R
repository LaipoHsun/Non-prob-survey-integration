# =============================================================================
# joint_distribution_TEDS.R —— TEDS 八個 X 的「聯合分布」原始分配
#
#   八個變數（與 raking_NTUWS.R 的 RAKE_VARS 對齊，額外補回 ethnicity）：
#
#                 2024_ind   2024_pan   2025
#     sex         SEX        PSEX       SEX
#     age         AGE        PAGE       AGE
#     edu         EDU        PEDU       EDU
#     arear       AREAR      PAREAR     AREAR
#     ethnicity   Q2         PQ2        H2a
#     party_kmt   P2a        PP2a       G2a      (0-10 情感溫度計)
#     party_dpp   P2b        PP2b       G2b
#     party_tpp   P2c        PP2c       G2c
#
#   為什麼要看聯合分布：raking 只逼「邊際」對得上，八個變數之間的關聯完全放任。
#   這支程式量化「聯合分布 vs 邊際乘積」差多少，也就是 raking 到底漏掉了什麼。
#
#   延續 build_population_targets.R 的原則：一律輸出原始類別，不做實質合併。
#   唯一例外是溫度計的 3 分箱版本，且與原始版本並列輸出，不取代。
#
#   輸出：data/output/portion_of_TEDS/<tag>/joint/
#           joint_full_raw.csv     8 變數完整聯合（溫度計 0-10 原始尺度）
#           joint_therm3.csv       8 變數聯合（溫度計併為 低/中/高）
#           joint_demo5.csv        只有 5 個人口學變數的聯合
#           pairwise_assoc.csv     28 組兩兩關聯（Cramér's V）
#           pairwise_tables.csv    28 組兩兩交叉表（含獨立性期望值）
#           sparsity_report.md     稀疏度與「raking 漏掉多少」的診斷
#
#   用法：Rscript data/code/Calculate_stat_population_from_TEDS/joint_distribution_TEDS.R
#         Rscript ... joint_distribution_TEDS.R 2024_ind 2025      # 只跑指定資料集
# =============================================================================

invisible(suppressWarnings(Sys.setlocale("LC_ALL", "zh_TW.UTF-8")))
if (!grepl("UTF-8", Sys.getlocale("LC_CTYPE"), fixed = TRUE))
  invisible(suppressWarnings(Sys.setlocale("LC_ALL", "en_US.UTF-8")))

suppressPackageStartupMessages({
  library(haven)
  library(dplyr)
})


# ############################################################################
# ## CONFIG ##################################################################
# ############################################################################

# 溫度計 3 分箱的切點：0-3 低、4-6 中、7-10 高
THERM_BIN <- list(
  breaks = c(-0.5, 3.5, 6.5, 10.5),
  labels = c("低(0-3)", "中(4-6)", "高(7-10)")
)

# 自動偵測設計權數欄位；找到就同時輸出加權版聯合分布
WEIGHT_CANDIDATES <- c("W", "w", "WEIGHT", "weight", "WT", "wt",
                       "W1", "w1", "WR", "wr", "RW", "rw")

# 完整聯合表輸出上限（依 n 由大到小；NA = 全部輸出）
JOINT_MAX_ROWS <- NA

# md 報告裡預覽前幾大的 cell
PREVIEW_N <- 25

# TVD 的 permutation 虛無基準次數。TVD 會被稀疏度嚴重灌水（格子遠多於人時，
# 就算變數真的互相獨立，TVD 也會逼近 1），所以必須跟「把每個變數各自打亂」
# 得到的虛無分布相比，看超出量（excess）才有意義。設 0 可關閉（會快很多）。
NULL_PERM <- 200


# ############################################################################
# ## 資料集設定 ##############################################################
# ############################################################################

find_root <- function() {
  p <- normalizePath(getwd())
  while (!file.exists(file.path(p, "data", "code")) && dirname(p) != p) p <- dirname(p)
  if (!file.exists(file.path(p, "data", "code"))) stop("找不到專案根目錄（需含 data/code）")
  p
}
root     <- find_root()
teds_dir <- file.path(root, "data", "TEDS")
out_root <- file.path(root, "data", "output", "portion_of_TEDS")

DEMO_VARS  <- c("sex", "age", "edu", "arear", "ethnicity")
THERM_VARS <- c("party_kmt", "party_dpp", "party_tpp")
ALL_VARS   <- c(DEMO_VARS, THERM_VARS)

VAR_ZH <- c(sex = "性別", age = "年齡", edu = "教育程度",
            arear = "居住地區", ethnicity = "省籍（父親）",
            party_kmt = "國民黨溫度", party_dpp = "民進黨溫度",
            party_tpp = "民眾黨溫度")

datasets <- list(
  "2024_ind" = list(
    title = "TEDS2024 面訪 獨立樣本", year = 2024,
    sav = file.path(teds_dir, "TEDS2024/Independence/TEDS2024_indQ.sav"), enc = "CP950",
    vars = c(sex = "SEX", age = "AGE", edu = "EDU", arear = "AREAR", ethnicity = "Q2",
             party_kmt = "P2a", party_dpp = "P2b", party_tpp = "P2c")),
  "2024_pan" = list(
    title = "TEDS2024 面訪 定群樣本", year = 2024,
    sav = file.path(teds_dir, "TEDS2024/Panel/TEDS2024_panQ.sav"), enc = "CP950",
    vars = c(sex = "PSEX", age = "PAGE", edu = "PEDU", arear = "PAREAR", ethnicity = "PQ2",
             party_kmt = "PP2a", party_dpp = "PP2b", party_tpp = "PP2c")),
  "2025" = list(
    title = "TEDS2025", year = 2025,
    sav = file.path(teds_dir, "TEDS2025/TEDS2025/TEDS2025.sav"), enc = "UTF-8",
    vars = c(sex = "SEX", age = "AGE", edu = "EDU", arear = "AREAR", ethnicity = "H2a",
             party_kmt = "G2a", party_dpp = "G2b", party_tpp = "G2c"))
)

# 依 value label 判定「非實質回答」，一律轉 NA（與 build_population_targets.R 同一份清單）
nonsubstantive <- c("拒答", "不知道", "無意見", "看情形", "跳題", "無反應", "沒聽過", "遺漏值")


# ############################################################################
# ## 工具函式 ################################################################
# ############################################################################

# 把 haven labelled 欄位轉成「已清乾淨的 label 字串」，非實質回答 → NA
to_label <- function(x, is_therm = FALSE) {
  labs <- attr(x, "labels")
  num  <- as.numeric(x)

  if (is_therm) {
    # 溫度計：只有 0-10 是有效值，95/96/97/98/99 等一律 NA
    num[!is.na(num) & (num < 0 | num > 10)] <- NA
    return(ifelse(is.na(num), NA_character_, sprintf("%02d", num)))
  }

  out <- if (is.null(labs)) as.character(num) else {
    m <- match(num, as.numeric(labs))
    ifelse(is.na(m), as.character(num), names(labs)[m])
  }
  out[is.na(num)] <- NA_character_
  out[!is.na(out) & out %in% nonsubstantive] <- NA_character_
  out
}

bin_therm <- function(lab) {
  v <- suppressWarnings(as.numeric(lab))
  as.character(cut(v, breaks = THERM_BIN$breaks, labels = THERM_BIN$labels))
}

find_weight <- function(dat) {
  hit <- WEIGHT_CANDIDATES[WEIGHT_CANDIDATES %in% names(dat)]
  if (!length(hit)) return(NULL)
  for (h in hit) {
    w <- as.numeric(dat[[h]])
    if (all(is.na(w))) next
    if (min(w, na.rm = TRUE) > 0 && max(w, na.rm = TRUE) < 100) return(h)
  }
  NULL
}

# 聯合分布：只列出「實際出現過」的 cell
joint_table <- function(df, vars, wt = NULL) {
  d <- df[vars]
  ok <- stats::complete.cases(d)
  d  <- d[ok, , drop = FALSE]
  d$.n <- 1
  d$.w <- if (is.null(wt)) 1 else wt[ok]

  out <- d |>
    group_by(across(all_of(vars))) |>
    summarise(n = sum(.n), n_wt = sum(.w), .groups = "drop") |>
    arrange(desc(n))

  out$prop    <- out$n    / sum(out$n)
  out$prop_wt <- out$n_wt / sum(out$n_wt)
  out$cell    <- do.call(paste, c(out[vars], sep = " | "))
  out
}

# 觀察到的聯合分布 vs「八個變數互相獨立」的聯合分布：total variation distance。
# 只在「出現過的 cell」上逐項相減，未出現的 cell 其獨立性機率整批補回來
#   TVD = 0.5 * [ sum_obs |p_obs - p_ind| + (1 - sum_obs p_ind) ]
# 這樣不需要展開幾百萬列的 grid，permutation 才跑得動。
tvd_stats <- function(df, vars, B = NULL_PERM) {
  d <- df[vars]
  d <- d[stats::complete.cases(d), , drop = FALSE]
  n <- nrow(d)

  one_tvd <- function(dd) {
    obs   <- dd |> group_by(across(all_of(vars))) |> summarise(.k = n(), .groups = "drop")
    p_obs <- obs$.k / sum(obs$.k)
    p_ind <- rep(1, nrow(obs))
    for (v in vars) {
      mv    <- prop.table(table(dd[[v]]))
      p_ind <- p_ind * as.numeric(mv[as.character(obs[[v]])])
    }
    0.5 * (sum(abs(p_obs - p_ind)) + max(0, 1 - sum(p_ind)))
  }

  obs_tvd <- one_tvd(d)

  null <- NA_real_
  if (B > 0) {
    null <- replicate(B, {
      dd <- d
      for (v in vars) dd[[v]] <- sample(dd[[v]])
      one_tvd(dd)
    })
  }

  list(n                = n,
       n_cells_possible = prod(vapply(vars, function(v) length(unique(d[[v]])), 1L)),
       n_cells_observed = nrow(unique(d)),
       tvd              = obs_tvd,
       null_mean        = if (all(is.na(null))) NA_real_ else mean(null),
       null_sd          = if (all(is.na(null))) NA_real_ else stats::sd(null),
       excess           = if (all(is.na(null))) NA_real_ else obs_tvd - mean(null))
}

cramers_v <- function(a, b) {
  ok <- !is.na(a) & !is.na(b)
  tb <- table(a[ok], b[ok])
  if (nrow(tb) < 2 || ncol(tb) < 2) return(NA_real_)
  cs <- suppressWarnings(stats::chisq.test(tb))
  as.numeric(sqrt((cs$statistic / sum(tb)) / (min(nrow(tb), ncol(tb)) - 1)))
}


# ############################################################################
# ## 主流程 ##################################################################
# ############################################################################

args <- commandArgs(trailingOnly = TRUE)
tags <- if (length(args)) args else names(datasets)
bad  <- setdiff(tags, names(datasets))
if (length(bad)) stop("未知的資料集：", paste(bad, collapse = ", "))

for (tag in tags) {
  cfg <- datasets[[tag]]
  message("處理：", tag, " —— ", cfg$title)

  if (!file.exists(cfg$sav)) {
    message("  跳過：找不到 ", cfg$sav)
    next
  }

  out_dir <- file.path(out_root, tag, "joint")
  dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)

  raw <- read_sav(cfg$sav, encoding = cfg$enc)

  miss <- setdiff(cfg$vars, names(raw))
  if (length(miss)) stop("在 ", tag, " 找不到欄位：", paste(miss, collapse = ", "))

  # ---- 建立乾淨的分析檔 ----------------------------------------------------
  df <- data.frame(row.names = seq_len(nrow(raw)))
  for (v in ALL_VARS)
    df[[v]] <- to_label(raw[[cfg$vars[[v]]]], is_therm = v %in% THERM_VARS)

  df3 <- df
  for (v in THERM_VARS) df3[[v]] <- bin_therm(df[[v]])

  wcol <- find_weight(raw)
  wt   <- if (is.null(wcol)) NULL else as.numeric(raw[[wcol]])
  if (is.null(wcol)) message("  未偵測到設計權數欄位，只輸出未加權（raw）結果")
  else               message("  偵測到設計權數欄位：", wcol)

  # ---- 三張聯合表 ----------------------------------------------------------
  jt_full  <- joint_table(df,  ALL_VARS,  wt)
  jt_th3   <- joint_table(df3, ALL_VARS,  wt)
  jt_demo  <- joint_table(df,  DEMO_VARS, wt)

  write_joint <- function(tb, file) {
    if (!is.na(JOINT_MAX_ROWS)) tb <- head(tb, JOINT_MAX_ROWS)
    write.csv(tb, file.path(out_dir, file), row.names = FALSE, fileEncoding = "UTF-8")
  }
  write_joint(jt_full, "joint_full_raw.csv")
  write_joint(jt_th3,  "joint_therm3.csv")
  write_joint(jt_demo, "joint_demo5.csv")

  # ---- 兩兩關聯 ------------------------------------------------------------
  pairs <- utils::combn(ALL_VARS, 2, simplify = FALSE)

  assoc <- lapply(pairs, function(p) {
    a <- df3[[p[1]]]; b <- df3[[p[2]]]
    data.frame(dataset = tag, var1 = p[1], var2 = p[2],
               var1_zh = VAR_ZH[[p[1]]], var2_zh = VAR_ZH[[p[2]]],
               n = sum(!is.na(a) & !is.na(b)),
               cramers_v = round(cramers_v(a, b), 4))
  }) |> bind_rows() |> arrange(desc(cramers_v))
  write.csv(assoc, file.path(out_dir, "pairwise_assoc.csv"),
            row.names = FALSE, fileEncoding = "UTF-8")

  ptabs <- lapply(pairs, function(p) {
    d <- df3[p]; d <- d[stats::complete.cases(d), , drop = FALSE]
    if (!nrow(d)) return(NULL)
    tb <- table(d[[1]], d[[2]])
    ex <- outer(rowSums(tb), colSums(tb)) / sum(tb)
    data.frame(dataset = tag, var1 = p[1], var2 = p[2],
               level1 = rep(rownames(tb), ncol(tb)),
               level2 = rep(colnames(tb), each = nrow(tb)),
               n_obs = as.vector(tb),
               n_indep = round(as.vector(ex), 2),
               ratio = round(as.vector(tb) / as.vector(ex), 3))
  }) |> bind_rows()
  write.csv(ptabs, file.path(out_dir, "pairwise_tables.csv"),
            row.names = FALSE, fileEncoding = "UTF-8")

  # ---- 稀疏度 / raking 漏掉多少 -------------------------------------------
  message("  計算 TVD 與 permutation 虛無基準（B = ", NULL_PERM, "）…")
  s_full <- tvd_stats(df,  ALL_VARS)
  s_th3  <- tvd_stats(df3, ALL_VARS)
  s_demo <- tvd_stats(df,  DEMO_VARS)

  singleton <- function(tb) sum(tb$n == 1)
  cover     <- function(s, tb) sprintf("%s / %s (%.3f%%)",
                                       format(s$n_cells_observed, big.mark = ","),
                                       format(s$n_cells_possible, big.mark = ","),
                                       100 * s$n_cells_observed / s$n_cells_possible)

  md <- file.path(out_dir, "sparsity_report.md")
  con <- file(md, open = "w", encoding = "UTF-8")
  writeLines(sprintf("# %s：八個 X 的聯合分布診斷\n", cfg$title), con)
  writeLines(sprintf("資料檔：`%s`  \n設計權數欄位：%s\n",
                     basename(cfg$sav),
                     if (is.null(wcol)) "**未偵測到**（以下皆為未加權）" else sprintf("`%s`", wcol)), con)

  writeLines("\n## 1. 稀疏度\n", con)
  writeLines("| 版本 | 變數 | 有效 N | 出現過的 cell / 理論 cell | 只有 1 人的 cell | 最大 cell 的 n |", con)
  writeLines("|---|---|---:|---|---:|---:|", con)
  writeLines(sprintf("| 完整（溫度計 0-10）| 8 | %s | %s | %s | %s |",
                     format(s_full$n, big.mark = ","), cover(s_full, jt_full),
                     format(singleton(jt_full), big.mark = ","), format(max(jt_full$n))), con)
  writeLines(sprintf("| 溫度計併 3 類 | 8 | %s | %s | %s | %s |",
                     format(s_th3$n, big.mark = ","), cover(s_th3, jt_th3),
                     format(singleton(jt_th3), big.mark = ","), format(max(jt_th3$n))), con)
  writeLines(sprintf("| 只有人口學 | 5 | %s | %s | %s | %s |",
                     format(s_demo$n, big.mark = ","), cover(s_demo, jt_demo),
                     format(singleton(jt_demo), big.mark = ","), format(max(jt_demo$n))), con)

  writeLines("\n## 2. raking 漏掉多少\n", con)
  writeLines("TVD = 觀察到的聯合分布，與「假設八個變數彼此獨立」推出的聯合分布之間的", con)
  writeLines("total variation distance。raking 只校正邊際，等於預設 TVD = 0。\n", con)
  writeLines("**但 TVD 會被稀疏度嚴重灌水**：格子數遠多於樣本數時，就算變數真的互相獨立，", con)
  writeLines("經驗聯合分布也只會落在少數幾個 cell 上，TVD 自然逼近 1。所以要看的是", con)
  writeLines("`excess = TVD − 虛無基準`，也就是扣掉噪音之後真正的關聯結構。", con)
  writeLines(sprintf("虛無基準 = 把每個變數各自獨立打亂 %d 次後的平均 TVD。\n", NULL_PERM), con)
  writeLines("| 版本 | TVD | 虛無基準 (SD) | excess | 幾個 SD |", con)
  writeLines("|---|---:|---:|---:|---:|", con)
  row <- function(nm, s) {
    if (is.na(s$null_mean))
      sprintf("| %s | %.4f | — | — | — |", nm, s$tvd)
    else
      sprintf("| %s | %.4f | %.4f (%.4f) | **%.4f** | %.1f |",
              nm, s$tvd, s$null_mean, s$null_sd, s$excess, s$excess / s$null_sd)
  }
  writeLines(row("完整（溫度計 0-10）", s_full), con)
  writeLines(row("溫度計併 3 類",       s_th3),  con)
  writeLines(row("只有人口學",         s_demo), con)
  writeLines("\n> excess 越接近 0，代表在這個粒度下，資料量根本不足以偵測聯合結構；", con)
  writeLines("> 此時該做的不是更細的 post-stratification，而是用模型把聯合分布 smooth 起來。", con)

  writeLines("\n## 3. 兩兩關聯（Cramér's V，溫度計併 3 類）\n", con)
  writeLines("| 變數 1 | 變數 2 | N | Cramér's V |", con)
  writeLines("|---|---|---:|---:|", con)
  for (i in seq_len(nrow(assoc)))
    writeLines(sprintf("| %s | %s | %s | %.3f |", assoc$var1_zh[i], assoc$var2_zh[i],
                       format(assoc$n[i], big.mark = ","), assoc$cramers_v[i]), con)

  writeLines(sprintf("\n## 4. 最大的 %d 個 cell（溫度計併 3 類）\n", PREVIEW_N), con)
  writeLines(sprintf("欄位順序：%s\n", paste(VAR_ZH[ALL_VARS], collapse = " | ")), con)
  writeLines("| cell | n | % |", con)
  writeLines("|---|---:|---:|", con)
  for (i in seq_len(min(PREVIEW_N, nrow(jt_th3))))
    writeLines(sprintf("| %s | %s | %.2f%% |", jt_th3$cell[i],
                       format(jt_th3$n[i], big.mark = ","), 100 * jt_th3$prop[i]), con)
  close(con)

  message("  完成 → ", out_dir)
}

message("全部完成，輸出於：", out_root)
