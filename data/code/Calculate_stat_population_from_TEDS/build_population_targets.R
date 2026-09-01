# =============================================================================
# 產生 raking 用的「母體目標」檔 —— 統一 tidy 格式，之後換母體只要換檔／換 source
#
#   兩種來源
#     census_2024 / census_2025
#         解析 TEDS .sps 中 `NPAR TEST/CHI <var>(a,b)/EXP=...` 的官方母體數
#         （sex / age / edu / arear）。TEDS2024 定群樣本的 .sps 沒有這組數字，
#         依約定沿用 census_2024。
#     teds_2024_ind / teds_2024_pan / teds_2025
#         TEDS 樣本本身的邊際分配（未加權），供沒有官方母體的變數使用
#         （city / ethnicity / 三個政黨情感溫度計）。
#
#   重要：本檔一律輸出「原始類別」，不做任何合併（省籍、情感溫度計皆然）。
#         所有 collapse 都留在後續 raking 的 R 裡進行，母體與樣本同步合併。
#
#   輸出：data/Input/population_targets/targets_<source>.csv
#         欄位 source, variable, var, code, label, N, prop
# =============================================================================

invisible(suppressWarnings(Sys.setlocale("LC_ALL", "zh_TW.UTF-8")))
if (!grepl("UTF-8", Sys.getlocale("LC_CTYPE"), fixed = TRUE))
  invisible(suppressWarnings(Sys.setlocale("LC_ALL", "en_US.UTF-8")))

suppressPackageStartupMessages({
  library(haven)
  library(dplyr)
})

find_root <- function() {
  p <- normalizePath(getwd())
  while (!file.exists(file.path(p, "data", "code")) && dirname(p) != p) p <- dirname(p)
  if (!file.exists(file.path(p, "data", "code"))) stop("找不到專案根目錄（需含 data/code）")
  p
}
root     <- find_root()
teds_dir <- file.path(root, "data", "TEDS")
out_dir  <- file.path(root, "data", "Input", "population_targets")
dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)

# ---- 各 TEDS 資料集：檔案位置與變數對照 -------------------------------------
teds <- list(
  "2024_ind" = list(
    sav = file.path(teds_dir, "TEDS2024/Independence/TEDS2024_indQ.sav"), enc = "CP950",
    sps = file.path(teds_dir, "TEDS2024/Independence/TEDS2024_indQ.sps"),
    vars = c(sex = "SEX", age = "AGE", edu = "EDU", arear = "AREAR", city = "City",
             ethnicity = "Q2",
             party_kmt = "P2a", party_dpp = "P2b", party_tpp = "P2c")),
  "2024_pan" = list(
    sav = file.path(teds_dir, "TEDS2024/Panel/TEDS2024_panQ.sav"), enc = "CP950",
    sps = NA_character_,                                   # 無官方母體數，沿用 census_2024
    vars = c(sex = "PSEX", age = "PAGE", edu = "PEDU", arear = "PAREAR", city = "PCity",
             ethnicity = "PQ2",
             party_kmt = "PP2a", party_dpp = "PP2b", party_tpp = "PP2c")),
  "2025" = list(
    sav = file.path(teds_dir, "TEDS2025/TEDS2025/TEDS2025.sav"), enc = "UTF-8",
    sps = file.path(teds_dir, "TEDS2025/TEDS2025/TEDS2025.sps"),
    vars = c(sex = "SEX", age = "AGE", edu = "EDU", arear = "AREAR", city = "City",
             ethnicity = "H2a",
             party_kmt = "G2a", party_dpp = "G2b", party_tpp = "G2c"))
)

# 依 value label 判定「非實質回答」，不列入母體目標
nonsubstantive <- c("拒答", "不知道", "無意見", "看情形", "跳題", "無反應", "沒聽過", "遺漏值")

# ---- 1. 從 .sps 解析官方母體數 ----------------------------------------------
# 例：NPAR TEST/CHI sex(1,2)/EXP=9564894,10025638
parse_census <- function(sps_path, sav, enc, vars) {
  txt <- readLines(sps_path, warn = FALSE, encoding = "UTF-8")
  hit <- grep("NPAR\\s+TEST/CHI", txt, value = TRUE)
  if (!length(hit)) return(NULL)

  dat <- read_sav(sav, encoding = enc)

  out <- lapply(hit, function(ln) {
    m <- regmatches(ln, regexec(
      "NPAR\\s+TEST/CHI\\s+([A-Za-z0-9_]+)\\s*\\(\\s*(\\d+)\\s*,\\s*(\\d+)\\s*\\)\\s*/\\s*EXP\\s*=\\s*([0-9,\\s]+)", ln))[[1]]
    if (!length(m)) return(NULL)
    key <- tolower(m[2]); lo <- as.numeric(m[3]); hi <- as.numeric(m[4])
    N   <- as.numeric(strsplit(gsub("[\\s\\.]", "", m[5], perl = TRUE), ",")[[1]])
    N   <- N[!is.na(N)]
    codes <- lo:hi
    if (length(N) != length(codes))
      stop(sprintf("%s：EXP 個數(%d)與 code 範圍(%d)不符", key, length(N), length(codes)))

    # 類別文字取自 .sav 的 value label，確保與樣本端對得起來
    v    <- vars[[key]]
    labs <- if (!is.null(v) && v %in% names(dat)) attr(dat[[v]], "labels") else NULL
    lab  <- if (is.null(labs)) as.character(codes)
            else { i <- match(codes, as.numeric(labs))
                   ifelse(is.na(i), as.character(codes), names(labs)[i]) }

    data.frame(variable = key, var = ifelse(is.null(v), NA_character_, v),
               code = codes, label = lab, N = N)
  })
  bind_rows(out)
}

# ---- 2. 從 .sav 取樣本邊際分配（供無官方母體的變數用） ----------------------
sample_margins <- function(sav, enc, vars) {
  dat <- read_sav(sav, encoding = enc)
  lapply(names(vars), function(key) {
    v <- vars[[key]]
    if (!v %in% names(dat)) return(NULL)
    x    <- dat[[v]]
    labs <- attr(x, "labels")
    num  <- as.numeric(x); num <- num[!is.na(num)]
    if (!length(num)) return(NULL)

    tb  <- as.data.frame(table(code = num), stringsAsFactors = FALSE)
    tb$code <- as.numeric(tb$code)
    lab <- if (is.null(labs)) as.character(tb$code)
           else { i <- match(tb$code, as.numeric(labs))
                  ifelse(is.na(i), as.character(tb$code), names(labs)[i]) }
    data.frame(variable = key, var = v, code = tb$code, label = lab, N = tb$Freq) |>
      filter(!label %in% nonsubstantive)          # 排除拒答／不知道／無反應
  }) |> bind_rows()
}

add_prop <- function(d, src) {
  d |>
    group_by(variable) |>
    mutate(prop = round(N / sum(N), 6)) |>
    ungroup() |>
    mutate(source = src, .before = 1) |>
    arrange(variable, code)
}

write_targets <- function(d, src) {
  path <- file.path(out_dir, sprintf("targets_%s.csv", src))
  write.csv(d, path, row.names = FALSE, fileEncoding = "UTF-8")
  message(sprintf("  寫出 %-28s  變數：%s", basename(path),
                  paste(unique(d$variable), collapse = ", ")))
}

# ---- 主流程 -----------------------------------------------------------------
# (a) 官方母體（census）
for (tag in c("2024_ind", "2025")) {
  cfg <- teds[[tag]]
  src <- paste0("census_", sub("_ind$", "", tag))
  message("解析官方母體：", src)
  d <- parse_census(cfg$sps, cfg$sav, cfg$enc, cfg$vars)
  if (is.null(d)) { warning(src, "：.sps 找不到 NPAR TEST/CHI 母體數"); next }
  write_targets(add_prop(d, src), src)
}

# 定群樣本沿用 census_2024（.sps 未提供）
f24 <- file.path(out_dir, "targets_census_2024.csv")
if (file.exists(f24)) {
  d <- read.csv(f24, fileEncoding = "UTF-8") |> mutate(source = "census_2024_pan")
  write_targets(d, "census_2024_pan")
  message("  註：定群樣本無官方母體數，census_2024_pan 內容與 census_2024 相同")
}

# (b) TEDS 樣本分配（city / ethnicity / 情感溫度計等無官方母體者亦包含在內）
for (tag in names(teds)) {
  cfg <- teds[[tag]]
  src <- paste0("teds_", tag)
  message("計算 TEDS 樣本分配：", src)
  write_targets(add_prop(sample_margins(cfg$sav, cfg$enc, cfg$vars), src), src)
}

message("完成，輸出於：", out_dir)
