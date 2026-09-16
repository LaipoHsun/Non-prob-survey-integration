# =============================================================================
#  MultiCalibration_NTUWS.R —— 以 TEDS／官方母體對 NTUWS 樣本做
#                              multilevel calibration，產出權數
#
#  方法：Ben-Michael, Feller & Hartman (2024). Multilevel calibration weighting
#        for survey data. Political Analysis 32(1), 65–83. 式 (9)
#        一階邊際「完全」對齊（= raking 約束），二階以上交互「盡量」對齊，
#        再加上權重變異數懲罰；λ 控制兩者的取捨。只做權重，不做 DRP（需要 Y）。
#
#  結構與 raking_NTUWS.R 相同：讀樣本、harmonize、collapse、對齊檢查（§0–5）
#  完全沿用；§5b 新增聯合目標；§6 以 multical 取代 anesrake；§7 輸出同格式。
#
#  用法：改最上面的 CONFIG 區塊，然後
#        Rscript data/code/MultiCalibration_NTUWS.R
#        Rscript data/code/MultiCalibration_NTUWS.R member
#
#  需要套件：multical（GitHub: ebenmichael/multical）、osqp、Matrix
#
#  設計原則：原始資料檔一律不修改；所有重編碼與類別合併都在本檔進行，
#            且母體端（邊際檔與聯合表）與樣本端「同步」套用同一份 collapse 設定。
# =============================================================================


# ############################################################################
# ## CONFIG —— 你只需要改這一段 ##############################################
# ############################################################################

# 樣本來源：
#   "wave"   逐波原始檔（lottery_repeated_raw_by_wave.xlsx 的某一個分頁）
#   "member" 個人層彙整檔（Phase0 人口學 + Phase2 政黨溫度計，已跨波整併）
# 也可由命令列覆寫：Rscript MultiCalibration_NTUWS.R LS_23NY   /   ... member
SAMPLE_TYPE <- "wave"

SAMPLE_FILE <- "data/NTUWS/raw_data/lottery_repeated_raw_by_wave.xlsx"
WAVE        <- "LS_23NY"      # SAMPLE_TYPE = "wave" 時要跑哪一波（xlsx 的分頁名）

# SAMPLE_TYPE = "member" 時使用
MEMBER <- list(
  demo_file   = "data/Input/NTUWS_pooled/ntuws_member_demographics.csv",
  therm_file  = "data/Input/NTUWS_pooled/ntuws_party_thermometer_resolved.xlsx",
  therm_sheet = "總表",
  therm_stat  = "mean",   # "median" 或 "mean"（mean 為小數，配合分組使用）
  edu_col     = "education",# "education"（已整理的 5 類）或 "education_raw"（原始用詞）
  ref_year    = 2024,       # 算年齡的基準年
  keep_splits = TRUE        # TRUE 保留 Phase2 拆分出來的 out_id；FALSE 只留未拆分者
)
BASE_SHEET  <- "Welcome"      # 波次缺值時的補充來源；設 NA 則不補
WAVE_YEAR   <- NA             # 調查年（算年齡用）。NA = 由 WAVE 名稱自動推導

TARGET_DIR  <- "data/Input/population_targets"

# 每個變數各自指定母體檔（一階邊際），可以混用不同來源
#   TARGET_SOURCE = "joint" 時這些檔只用來決定類別，年份要和聯合表一致
TARGET_FILES <- c(
  sex       = "targets_census_2025.csv",
  age       = "targets_census_2025.csv",
  edu       = "targets_census_2025.csv",
  arear     = "targets_census_2025.csv",
  ethnicity = "targets_teds_2025.csv",
  party_kmt = "targets_teds_2025.csv",
  party_dpp = "targets_teds_2025.csv",
  party_tpp = "targets_teds_2025.csv"
)

# 這次真的要拿來校準的欄位
RAKE_VARS <- c("sex", "age", "edu", "arear","party_kmt","party_dpp","party_tpp")

# 類別合併設定：給預設代號（見 README），或直接給自訂 list
COLLAPSE <- list(
  age       = "A2",   # 18–19 歲兩邊都設為 NA（LS_23NY 沒有 18–19 歲選項；母體定義 = 20 歲以上）
  arear     = "A",
  edu       = "B",
  ethnicity = "4class",
  party_kmt = "C",
  party_dpp = "C",
  party_tpp = "C"
)

OPTS <- list(
  sex_other_to_na   = TRUE,    # 性別「其他」→ NA
  island_to_na      = TRUE,    # 外島（連江/金門/澎湖）→ NA
  age_1819          = "auto",  # "auto" / "keep" / "na"
  edu_auto_fallback = TRUE,    # 教育類別對不上時自動退回較粗的版本
  ethnicity_dk      = "na",    # "na" / "other"
  dedupe            = "smart", # "smart" / "first" / "none"
  therm_scale       = "auto",  # "auto" / "asis"
  therm_round       = TRUE     # 溫度計出現非整數（member 模式的 median/mean）時取整
)

# 母體目標的來源（同 raking_NTUWS.R）：
#   "joint" 一階邊際 = 下面聯合表依 count_col 加總（主分析；與 raking、PAPP-BART 同一個母體）
#   "files" 一階邊際 = TARGET_FILES
TARGET_SOURCE <- "joint"

# 聯合分布：multilevel calibration 用來平衡交互的母體格數；TARGET_SOURCE = "joint" 時也是一階邊際的來源
#   聯合表必須含 RAKE_VARS 各欄（TEDS 原始類別標籤；溫度計 00–10）與 n、n_wt
JOINT <- list(
  file      = "data/output/portion_of_TEDS/2025/joint/joint_full_raw.csv",
  count_col = "n_wt",  # "n_wt"（TEDS W 加權，主分析）／"n"（未加權）
  anchor    = TRUE,    # TRUE：以 IPF 把聯合表的一階邊際拉到目標邊際（TARGET_SOURCE = "joint" 時兩者相同，不會改動）
                       # FALSE：直接用聯合表自己的邊際
  ipf_maxit = 5000,
  ipf_tol   = 1e-10    # IPF 停止條件：各類別比例與目標的最大差距
)

# multical 參數（對應論文式 9 與 §5）
MULTICAL <- list(
  order             = 2,      # 平衡到幾階交互；1 = 只對齊邊際（變異數懲罰版的 raking）
  n_lambda          = 40,     # λ 路徑長度（論文 §5：40 個對數等距的 λ）
  lambda_min_ratio  = 1e-10,  # 最小 λ / 最大 λ
  lambda            = NULL,   # 指定單一 λ 時填數字；NULL = 跑整條路徑再自動選
  balance_threshold = 0.95,   # 選 λ：達到「最小 λ 相對 raking 的平衡改善」的 95%，
                              #       其中取有效樣本數最大者（論文 §3.2 末段、§5）
  lowlim            = 0.01,   # 權數下限（平均 = 1 的尺度；0 = 允許權數為 0）
  uplim             = Inf,    # 權數上限（同 anesrake 的 cap 尺度，例如 5）。
                              #   邊際是硬約束，上限太低會使問題無解
  report_order      = 3,      # 交互平衡表／圖檢查到幾階
  osqp              = list(eps_abs = 1e-7, eps_rel = 1e-7,
                           max_iter = 200000L, polish = TRUE)
)

# 欄位自動偵測失敗時在這裡指定欄名，例如 COLUMN_OVERRIDE <- c(edu = "S3 ")
COLUMN_OVERRIDE <- c()

RUN_NAME <- NA                 # 輸出檔名的方法標籤；NA = 自動（例如 mlcal_o2）
OUT_ROOT <- "data/output"      # 輸出根目錄；實驗（例如合併聯合表、leave-one-variable-out）可以指到別處
OUT_DIR  <- NA                 # NA = <OUT_ROOT>/multical/<WAVE>

# ############################################################################
# ## 以下為引擎，一般不需要修改 ##############################################
# ############################################################################

invisible(suppressWarnings(Sys.setlocale("LC_ALL", "zh_TW.UTF-8")))
if (!grepl("UTF-8", Sys.getlocale("LC_CTYPE"), fixed = TRUE))
  invisible(suppressWarnings(Sys.setlocale("LC_ALL", "en_US.UTF-8")))

for (pkg in c("multical", "osqp", "Matrix"))
  if (!requireNamespace(pkg, quietly = TRUE))
    stop("缺少套件 ", pkg, "。安裝：install.packages(c(\"remotes\", \"osqp\"))；",
         "remotes::install_github(\"ebenmichael/multical\")")

suppressPackageStartupMessages({
  library(readxl); library(dplyr); library(tidyr)
  library(ggplot2); library(scales)
})

find_root <- function() {
  p <- normalizePath(getwd())
  while (!file.exists(file.path(p, "data", "code")) && dirname(p) != p) p <- dirname(p)
  if (!file.exists(file.path(p, "data", "code"))) stop("找不到專案根目錄（需含 data/code）")
  p
}
.args <- commandArgs(trailingOnly = TRUE)
# 命令列：第一個不含「=」的參數是樣本（member 或波次名）；其餘 key=value 覆寫 CONFIG
#   joint=2024_ind   → data/output/portion_of_TEDS/2024_ind/joint/joint_full_raw.csv（也可給完整路徑）
#   order=1  uplim=5  lowlim=0  count_col=n  target=files  anchor=FALSE  run_name=自訂標籤
#   drop=edu         從 RAKE_VARS 拿掉這些變數（逗號分隔）
#   out_root=data/output/experiments/xxx   輸出根目錄
.kv  <- grepl("=", .args, fixed = TRUE)
.pos <- .args[!.kv & nzchar(.args)]
if (length(.pos) >= 1) {
  if (identical(.pos[1], "member")) SAMPLE_TYPE <- "member"
  else { SAMPLE_TYPE <- "wave"; WAVE <- .pos[1] }
}
for (.a in .args[.kv]) {
  .key <- sub("=.*$", "", .a); .val <- sub("^[^=]*=", "", .a)
  switch(.key,
    joint     = JOINT$file <- if (grepl("/", .val, fixed = TRUE)) .val else
                  file.path("data/output/portion_of_TEDS", .val, "joint/joint_full_raw.csv"),
    count_col = JOINT$count_col <- .val,
    anchor    = JOINT$anchor <- as.logical(.val),
    order     = MULTICAL$order <- as.integer(.val),
    uplim     = MULTICAL$uplim <- as.numeric(.val),
    lowlim    = MULTICAL$lowlim <- as.numeric(.val),
    target    = TARGET_SOURCE <- .val,
    run_name  = RUN_NAME <- .val,
    drop      = RAKE_VARS <- {
                  .d <- strsplit(.val, ",", fixed = TRUE)[[1]]
                  if (length(setdiff(.d, RAKE_VARS)))
                    stop("drop= 的變數不在 RAKE_VARS 裡：", paste(setdiff(.d, RAKE_VARS), collapse = ", "))
                  setdiff(RAKE_VARS, .d)
                },
    out_root  = OUT_ROOT <- .val,
    collapse  = for (.c in strsplit(.val, ",", fixed = TRUE)[[1]]) {
                  .p <- strsplit(.c, ":", fixed = TRUE)[[1]]
                  if (length(.p) != 2) stop("collapse= 的格式是 變數:代號，例如 collapse=arear:B")
                  COLLAPSE[[.p[1]]] <- .p[2]
                },
    stop("不認得的命令列參數：", .key,
         "（可用 joint、order、uplim、lowlim、count_col、target、anchor、run_name、drop、out_root、collapse）"))
}
run_label <- if (identical(SAMPLE_TYPE, "member")) "member_pooled" else WAVE

# 方法標籤：預設依設定自動組出，避免不同設定互相覆蓋；和預設不同的設定才加註
# 預設 = 聯合表 2025、W 加權（n_wt）、目標來自聯合表、錨定、lowlim = 0.01、無上限
joint_name <- basename(dirname(dirname(JOINT$file)))
method_tag <- if (!is.na(RUN_NAME)) RUN_NAME else paste0(
  "mlcal_o", MULTICAL$order,
  if (!identical(joint_name, "2025")) paste0("_j", joint_name) else "",
  if (identical(JOINT$count_col, "n")) "_Njoint" else "",
  if (identical(TARGET_SOURCE, "files")) "_tfiles" else "",
  if (!isTRUE(JOINT$anchor)) "_noanchor" else "",
  if (!isTRUE(all.equal(MULTICAL$lowlim, 0.01))) sprintf("_low%g", MULTICAL$lowlim) else "",
  if (is.finite(MULTICAL$uplim)) sprintf("_cap%g", MULTICAL$uplim) else "",
  if (!is.null(MULTICAL$lambda)) sprintf("_lam%g", MULTICAL$lambda) else "")
tag <- paste0(method_tag, "_", run_label)

root    <- find_root()
abs_in  <- function(p) if (grepl("^[/~]", p) || file.exists(p)) p else file.path(root, p)
# 一個 run 一個子資料夾（order、lowlim、聯合表等設定不同就分開放），檔名仍帶方法標籤
out_dir <- if (is.na(OUT_DIR)) file.path(abs_in(OUT_ROOT), "multical", run_label, method_tag) else abs_in(OUT_DIR)
dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)

NUMERIC_VARS <- c("party_kmt", "party_dpp", "party_tpp")   # 以 code 而非 label 對齊
log_lines <- c()
say <- function(...) { m <- paste0(...); message(m); log_lines <<- c(log_lines, m) }

# ---------------------------------------------------------------------------
# 0. collapse 預設版本
# ---------------------------------------------------------------------------
# 每個 spec 是 list(新類別 = c(舊類別...))；未提及的類別原樣保留；
# 特殊項 .drop = c(舊類別...) 表示設為 NA（母體端同步移除並重新標準化）
PRESETS <- list(
  age = list(
    "A"  = list(),
    "A2" = list(.drop = "18至19歲"),
    "B"  = list("20-39歲" = c("20至29歲", "30至39歲"),
                "40-59歲" = c("40至49歲", "50至59歲"),
                .drop = "18至19歲"),
    "C"  = list("20-49歲" = c("20至29歲", "30至39歲", "40至49歲"),
                "50歲及以上" = c("50至59歲", "60歲及以上"),
                .drop = "18至19歲")
  ),
  # 註：2024 與 2025 的區域用詞不同（高屏區/高屏澎湖區、花東區/花東外島區），
  #     兩種寫法都列入，兩個年度都能用同一組預設
  arear = list(
    "A" = list(),
    "B" = list("北部" = c("北北基宜蘭區", "桃竹苗區"), "中部" = "中彰投區",
               "南部" = c("雲嘉南區", "高屏區", "高屏澎湖區"),
               "東部" = c("花東區", "花東外島區")),
    "C" = list("北部" = c("北北基宜蘭區", "桃竹苗區"), "中部" = "中彰投區",
               "南部" = c("雲嘉南區", "高屏區", "高屏澎湖區",
                          "花東區", "花東外島區"))
  ),
  edu = list(
    "A" = list(),
    "B" = list("高中職及以下" = c("小學及以下", "國、初中", "高中、職")),
    "C" = list("高中職及以下" = c("小學及以下", "國、初中", "高中、職"),
               "專科及以上"   = c("專科", "大學及以上", "專科或大學"))
  ),
  ethnicity = list(
    "raw"    = list(),
    "4class" = list("其他" = c("原住民", "平埔族原住民", "大陸新住民", "外國新住民",
                               "台灣僑胞/華僑", "外籍人士", "台灣人", "其他"))
  ),
  party = list(
    "A" = list(),
    "C" = list("0-4 冷淡" = 0:4, "5 中間" = 5, "6-10 溫暖" = 6:10),
    "E" = list("0-2 很冷" = 0:2, "3-4 偏冷" = 3:4, "5 中立" = 5,
               "6-7 偏暖" = 6:7, "8-10 很暖" = 8:10)
  )
)
PRESETS$party_kmt <- PRESETS$party_dpp <- PRESETS$party_tpp <- PRESETS$party

get_spec <- function(var) {
  s <- COLLAPSE[[var]]
  if (is.null(s)) return(list())
  if (is.list(s)) return(s)                      # 使用者自訂
  p <- PRESETS[[var]]
  if (is.null(p) || is.null(p[[s]]))
    stop(sprintf("變數 %s 沒有名為 '%s' 的預設 collapse 版本", var, s))
  p[[s]]
}

# 顯示用的版本名稱
ver_name <- function(var) {
  s <- COLLAPSE[[var]]
  if (is.null(s)) "原始" else if (is.character(s)) s else "自訂"
}

# 把 spec 套用到一組類別標籤上
apply_collapse <- function(x, spec) {
  x <- as.character(x)
  drop <- as.character(spec[[".drop"]])
  spec <- spec[names(spec) != ".drop"]
  for (new in names(spec)) x[x %in% as.character(spec[[new]])] <- new
  if (length(drop)) x[x %in% drop] <- NA
  x
}

# collapse 後各類別的排序：依原始順序，合併者取其第一次出現的位置
collapse_levels <- function(orig_levels, spec) {
  new <- apply_collapse(orig_levels, spec)
  unique(new[!is.na(new)])
}

# ---------------------------------------------------------------------------
# 1. 讀樣本
# ---------------------------------------------------------------------------
wave_year <- {
  if (identical(SAMPLE_TYPE, "member")) MEMBER$ref_year
  else if (!is.na(WAVE_YEAR)) WAVE_YEAR
  else {
    m <- regmatches(WAVE, regexec("LS_(\\d{2})", WAVE))[[1]]
    if (length(m) < 2) stop("無法從 WAVE 名稱推導年份，請直接設定 WAVE_YEAR")
    2000 + as.numeric(m[2])
  }
}
say("樣本：", run_label, "（基準年 ", wave_year, "）；方法：", method_tag)

read_sheet <- function(path, sheet) {
  d <- suppressMessages(read_excel(path, sheet = sheet, col_types = "text"))
  q <- as.character(unlist(d[1, ]))              # 第 1 列是題目全文
  d <- d[-1, , drop = FALSE]
  list(data = as.data.frame(d), q = q)
}

# --- 欄位自動偵測（同時比對欄名與題目文字）---------------------------------
PATTERNS <- list(
  sex       = "性別",
  birth     = "出生",
  ageband   = "您的年齡|^年齡$|請問您的年齡",   # 已分好組的年齡題
  edu       = "學歷|教育程度",
  ethnicity = "省籍|本省客家|籍貫|族群",
  city      = "哪一個縣市|居住的縣市|居住縣市|^地區$",
  zip       = "郵遞區號",
  party_kmt = "國民黨",
  party_dpp = "民主進步黨|民進黨",
  party_tpp = "民眾黨"
)

build_member_sample <- function() {
  demo <- read.csv(abs_in(MEMBER$demo_file), fileEncoding = "UTF-8",
                   stringsAsFactors = FALSE, colClasses = "character")
  say("Phase0 人口學：", nrow(demo), " 人")
  th <- as.data.frame(suppressMessages(
          read_excel(abs_in(MEMBER$therm_file), sheet = MEMBER$therm_sheet,
                     col_types = "text")))
  say("Phase2 溫度計：", nrow(th), " 個 out_id（含拆分）")
  if (!MEMBER$keep_splits) {
    th <- th[!(tolower(th$is_split) %in% "true"), ]
    say("  keep_splits = FALSE，只保留未拆分者：", nrow(th), " 筆")
  }
  st  <- MEMBER$therm_stat
  ecol <- MEMBER$edu_col
  if (!ecol %in% names(demo)) stop("Phase0 檔沒有欄位 ", ecol)

  d <- merge(th, demo, by.x = "split_from", by.y = "memberId", all.x = TRUE)
  say("併入人口學後：", nrow(d), " 筆；無人口學資料 ", sum(is.na(d$sex)), " 筆")

  data.frame(
    memberId  = d$out_id,
    sex       = d$sex,
    birth     = d$birth_year,
    ageband   = NA_character_,
    edu       = d[[ecol]],
    ethnicity = d$father_ethnicity,
    city      = d$city,
    zip       = NA_character_,
    party_kmt = d[[paste0("國民黨_", st)]],
    party_dpp = d[[paste0("民進黨_", st)]],
    party_tpp = d[[paste0("民眾黨_", st)]],
    stringsAsFactors = FALSE)
}

if (identical(SAMPLE_TYPE, "member")) {
  sam <- build_member_sample()
  cols <- setNames(rep(NA_character_, length(PATTERNS)), names(PATTERNS))
  base <- NULL
} else {

sample_path <- abs_in(SAMPLE_FILE)
sh  <- read_sheet(sample_path, WAVE)
raw <- sh$data
say("原始列數：", nrow(raw))


find_col <- function(key, dat, q) {
  if (key %in% names(COLUMN_OVERRIDE)) {
    cn <- COLUMN_OVERRIDE[[key]]
    if (!cn %in% names(dat)) stop(sprintf("COLUMN_OVERRIDE 指定的欄位 '%s' 不存在", cn))
    return(cn)
  }
  hay <- paste(names(dat), q)                    # 欄名或題目文字命中都算
  hit <- grep(PATTERNS[[key]], hay)
  if (grepl("^party_", key)) {
    # 溫度計：排除泛藍/泛綠，並且欄位本身必須真的是 0-10 量表
    # （光靠題目文字不夠——有些波次的第二、三題只寫「請問您會給民進黨多少？」）
    hit <- hit[!grepl("泛藍|泛綠", hay[hit])]
    ok <- vapply(hit, function(j) {
      v <- suppressWarnings(as.numeric(dat[[j]]))
      k <- length(unique(na.omit(v)))
      sum(!is.na(v)) > 0.5 * length(v) && k >= 8 &&
        min(v, na.rm = TRUE) >= 0 && max(v, na.rm = TRUE) <= 10
    }, logical(1))
    hit <- hit[ok]
  }
  if (!length(hit)) return(NA_character_)
  names(dat)[hit[1]]
}

cols <- sapply(names(PATTERNS), find_col, dat = raw, q = sh$q)
say("偵測到的欄位：",
    paste(sprintf("%s=%s", names(cols), ifelse(is.na(cols), "-", cols)), collapse = "  "))

# --- 用 Welcome 補缺 --------------------------------------------------------
base <- NULL
if (!is.na(BASE_SHEET)) {
  bs   <- read_sheet(sample_path, BASE_SHEET)
  bcol <- sapply(names(PATTERNS), find_col, dat = bs$data, q = bs$q)
  base <- bs$data
  attr(base, "cols") <- bcol
  say("補充來源 ", BASE_SHEET, "：", nrow(base), " 筆")
}

pick <- function(dat, cn) {
  if (is.na(cn) || !cn %in% names(dat)) rep(NA_character_, nrow(dat))
  else as.character(dat[[cn]])
}

sam <- data.frame(memberId = as.character(raw$memberId), stringsAsFactors = FALSE)
for (k in names(PATTERNS)) sam[[k]] <- pick(raw, cols[[k]])

if (!is.null(base)) {                            # 波次自填優先，缺的用 Welcome 補
  bcol <- attr(base, "cols")
  b <- data.frame(memberId = as.character(base$memberId), stringsAsFactors = FALSE)
  for (k in names(PATTERNS)) b[[paste0(k, "__b")]] <- pick(base, bcol[[k]])
  b <- b[!duplicated(b$memberId), ]
  sam <- left_join(sam, b, by = "memberId")
  filled <- c()
  for (k in names(PATTERNS)) {
    bk <- paste0(k, "__b"); if (!bk %in% names(sam)) next
    need <- is.na(sam[[k]]) | !nzchar(trimws(ifelse(is.na(sam[[k]]), "", sam[[k]])))
    n_fill <- sum(need & !is.na(sam[[bk]]))
    sam[[k]][need] <- sam[[bk]][need]
    if (n_fill > 0) filled <- c(filled, sprintf("%s(+%d)", k, n_fill))
    sam[[bk]] <- NULL
  }
  if (length(filled)) say("由 ", BASE_SHEET, " 補值：", paste(filled, collapse = " "))
}

}   # end SAMPLE_TYPE 分支

# --- 重複 memberId ----------------------------------------------------------
dup_note <- "無重複"
if (OPTS$dedupe != "none") {
  key <- do.call(paste, c(sam[, setdiff(names(sam), "memberId")], sep = "|"))
  if (OPTS$dedupe == "first") {
    keep <- !duplicated(sam$memberId)
    dup_note <- sprintf("first：移除 %d 筆重複 memberId", sum(!keep))
    sam <- sam[keep, ]
  } else {                                       # smart：回答一致才去重
    keep <- !duplicated(data.frame(id = sam$memberId, key = key))
    n_same <- sum(!keep)
    sam <- sam[keep, ]
    n_diff <- sum(duplicated(sam$memberId))
    dup_note <- sprintf("smart：回答一致去重 %d 筆；回答不同視為獨立樣本 %d 筆",
                        n_same, n_diff)
  }
  say("重複 memberId 處理 -> ", dup_note)
}
sam$caseid <- seq_len(nrow(sam))
say("進入分析的列數：", nrow(sam))

# ---------------------------------------------------------------------------
# 2. harmonize：把 NTUWS 原始值映到「母體檔的類別標籤」
# ---------------------------------------------------------------------------
norm_tw <- function(x) gsub("臺", "台", trimws(ifelse(is.na(x), NA, x)))

# 縣市 -> 區域代碼 1-6（與 TEDS 的 AREAR 編碼一致），外島另計
REGION <- list(
  "1" = c("台北市", "新北市", "基隆市", "宜蘭縣"),
  "2" = c("桃園市", "桃園縣", "新竹市", "新竹縣", "苗栗縣"),
  "3" = c("台中市", "台中縣", "彰化縣", "南投縣"),
  "4" = c("雲林縣", "嘉義市", "嘉義縣", "台南市", "台南縣"),
  "5" = c("高雄市", "高雄縣", "屏東縣"),
  "6" = c("花蓮縣", "台東縣"),
  "澎湖" = "澎湖縣",
  "金馬" = c("金門縣", "連江縣", "馬祖", "馬祖(連江縣)", "馬祖（連江縣）")
)
ZIP3_REGION <- list(                              # 郵遞區號前三碼 -> 區域代碼
  "1" = c(100:116, 200:208, 220:253, 260:272),
  "2" = c(300:315, 320:338, 350:369),
  "3" = c(400:439, 500:530, 540:558),
  "4" = c(600:655, 700:745),
  "5" = c(800:852, 900:947),
  "6" = c(950:983),
  "澎湖" = 880:885, "金馬" = c(209:212, 890:896)
)

# 已分好組的年齡題（部分波次不問出生年，直接問年齡組）
AGE_BAND_MAP <- c(
  "18-19歲" = "18至19歲", "18至19歲" = "18至19歲",
  "20-29歲" = "20至29歲", "20至29歲" = "20至29歲",
  "30-39歲" = "30至39歲", "30至39歲" = "30至39歲",
  "40-49歲" = "40至49歲", "40至49歲" = "40至49歲",
  "50-59歲" = "50至59歲", "50至59歲" = "50至59歲",
  "60-69歲" = "60歲及以上", "70歲以上" = "60歲及以上",
  "60歲以上" = "60歲及以上", "60歲及以上" = "60歲及以上"
)

# 「專科或大學」是一個無法再細分的合併類別：部分來源把專科與大學問成同一個
# 選項（例如 LS_2306 的「大專（專科與大學）」、Phase0 的「4_大專」）。
# 它只在 edu 版本 C 之下才對得上母體，版本 A/B 會觸發自動退回。
EDU_MAP <- c(                                     # 各波用詞 -> TEDS 5 類
  "小學（含以下）" = "小學及以下", "小學及以下" = "小學及以下", "國小及以下" = "小學及以下",
  "小學" = "小學及以下", "高中以下" = "小學及以下",
  "國中初中" = "國、初中", "國中/初中" = "國、初中", "初中、國中" = "國、初中",
  "國中" = "國、初中", "國（初）中" = "國、初中",
  "高中/高職" = "高中、職", "高中、高職" = "高中、職", "高中職" = "高中、職",
  "專科（五專、三專、二專）" = "專科", "專科" = "專科",
  "四技二專" = "專科", "五專" = "專科",
  "大學" = "大學及以上", "大學、科大" = "大學及以上", "研究所以上" = "大學及以上",
  "研究所及以上" = "大學及以上", "碩士" = "大學及以上", "博士" = "大學及以上",
  # 專科與大學問在同一個選項裡，無法拆開
  "大專（專科與大學）" = "專科或大學", "大專(專科與大學)" = "專科或大學",
  "大專（大學及專科）" = "專科或大學", "大專(大學及專科)" = "專科或大學",
  # Phase0 個人層彙整檔的 education 欄
  "1_國小及以下" = "小學及以下", "2_國中" = "國、初中", "3_高中職" = "高中、職",
  "4_大專" = "專科或大學", "5_研究所以上" = "大學及以上"
)
ETH_MAP <- c(
  "本省客家人" = "本省客家人", "本省閩南人" = "本省閩南人",
  "本省閩南（臺：河洛）人" = "本省閩南人",
  "大陸各省市" = "大陸各省市", "大陸各省市人" = "大陸各省市",
  "原住民" = "原住民", "大陸新住民" = "大陸新住民", "外國新住民" = "外國新住民",
  "中國籍（含港澳）" = "大陸新住民", "外籍（不含中港澳）" = "外籍人士",
  # LS_23NY 的「父親的籍貫/族群」用詞
  "本省籍" = "本省閩南人", "客家" = "本省客家人",
  "外省籍(大陸各省市)" = "大陸各省市", "外省籍（大陸各省市）" = "大陸各省市",
  "外籍" = "外籍人士",
  # Phase0 個人層彙整檔的 father_ethnicity 欄
  "閩南人" = "本省閩南人", "客家人" = "本省客家人", "外省人" = "大陸各省市"
)
ETH_DK <- c("不知道", "不清楚", "拒答", "無反應", "無意見")

# tg0 = 該變數的母體類別表（level, N），用來決定母體到底有沒有某個類別
harmonize <- function(sam, var, tg0) {
  switch(var,
    sex = {
      x <- norm_tw(sam$sex)
      out <- ifelse(x %in% c("男", "男性"), "男性",
             ifelse(x %in% c("女", "女性"), "女性", NA))
      if (!OPTS$sex_other_to_na && any(!is.na(x) & is.na(out)))
        out[!is.na(x) & is.na(out)] <- "其他"
      out
    },
    age = {
      b <- suppressWarnings(as.numeric(sam$birth))
      b <- ifelse(!is.na(b) & b < 200, b + 1911, b)          # 民國年 -> 西元
      a <- wave_year - b
      out <- as.character(cut(a, breaks = c(-Inf, 17, 19, 29, 39, 49, 59, Inf),
                              labels = c("未滿18", "18至19歲", "20至29歲", "30至39歲",
                                         "40至49歲", "50至59歲", "60歲及以上")))
      out[out %in% "未滿18"] <- NA
      # 有些波次不問出生年，改問已分好組的年齡（例如 LS_23NY 的「您的年齡」）。
      # 依「波次自填優先」原則，該波自己問到的年齡組優先於 Welcome 的出生年。
      if (!is.null(sam$ageband)) {
        band <- unname(AGE_BAND_MAP[trimws(sam$ageband)])
        unmapped <- unique(trimws(sam$ageband)[!is.na(sam$ageband) &
                     nzchar(trimws(sam$ageband)) & is.na(band)])
        if (length(unmapped))
          say("  ! 年齡組有未對應的選項（改用出生年推算）：", paste(unmapped, collapse = "／"))
        n_band <- sum(!is.na(band))
        if (n_band > 0) say("  age：", n_band, " 人採用該波自填的年齡組，其餘由出生年推算")
        out <- ifelse(is.na(band), out, band)
      }
      # auto：母體沒有 18-19 這組就設 NA；na 一律設 NA；keep 保留（母體沒有會報錯）
      drop1819 <- switch(OPTS$age_1819,
                         "na" = TRUE, "keep" = FALSE,
                         !("18至19歲" %in% tg0$level))
      if (drop1819) {
        n <- sum(out %in% "18至19歲", na.rm = TRUE)
        if (n > 0) say("  ! age：母體無 18-19 歲組，該組 ", n, " 人設為 NA")
        out[out %in% "18至19歲"] <- NA
      }
      out
    },
    edu = {
      x <- trimws(sam$edu)
      out <- unname(EDU_MAP[x])
      unmapped <- unique(x[!is.na(x) & nzchar(x) & is.na(out)])
      if (length(unmapped))
        say("  ! 教育程度有未對應的選項（設為 NA）：", paste(unmapped, collapse = "／"))
      out
    },
    arear = {
      city <- norm_tw(sam$city)
      out  <- rep(NA_character_, nrow(sam))      # 先算出區域代碼 1-6 / 澎湖 / 金馬
      for (r in names(REGION)) out[city %in% REGION[[r]]] <- r
      z <- suppressWarnings(as.numeric(substr(trimws(sam$zip), 1, 3)))   # 只有郵遞區號的波
      for (r in names(ZIP3_REGION)) out[is.na(out) & z %in% ZIP3_REGION[[r]]] <- r

      # 外島歸屬由母體用詞決定：census_2024 的第 5、6 區含澎湖與金馬，
      # census_2025 則不含（標籤為「高屏區」「花東區」）
      lab5 <- tg0$level[match("5", as.character(tg0$code))]
      lab6 <- tg0$level[match("6", as.character(tg0$code))]
      out[out %in% "澎湖"] <- if (!is.na(lab5) && grepl("澎湖", lab5)) "5" else "外島"
      out[out %in% "金馬"] <- if (!is.na(lab6) && grepl("外島|金馬", lab6)) "6" else "外島"

      n_isl <- sum(out %in% "外島", na.rm = TRUE)
      if (n_isl > 0) {
        if (OPTS$island_to_na) {
          say("  ! arear：母體不含外島，外島 ", n_isl, " 人設為 NA")
          out[out %in% "外島"] <- NA
        } else say("  ! arear：外島 ", n_isl, " 人保留為獨立類別（母體無此類別將報錯）")
      }
      # 代碼換成母體檔的區域名稱
      i <- match(out, as.character(tg0$code))
      ifelse(is.na(i), out, tg0$level[i])
    },
    ethnicity = {
      x <- trimws(sam$ethnicity)
      x <- sub("^其他.*", "其他", x)
      out <- unname(ETH_MAP[x])
      out[is.na(out) & x %in% "其他"] <- "其他"
      out[x %in% ETH_DK] <- if (identical(OPTS$ethnicity_dk, "other")) "其他" else NA
      out
    },
    {   # party_kmt / party_dpp / party_tpp
      v <- suppressWarnings(as.numeric(sam[[var]]))
      if (identical(OPTS$therm_scale, "auto") && length(na.omit(v)) &&
          min(v, na.rm = TRUE) >= 1 && max(v, na.rm = TRUE) == 10 &&
          length(unique(na.omit(v))) <= 10) {
        say("  ! ", var, " 偵測為 1-10 量表，已平移為 0-9 以對齊母體（請確認是否合理）")
        v <- v - 1
      }
      # member 模式取跨波的 median／mean，波數為偶數時會出現 5.5 這種半整數，
      # 對不上母體的 0-10。四捨五入為整數（.5 一律進位）。
      if (isTRUE(OPTS$therm_round)) {
        n_half <- sum(!is.na(v) & v != floor(v))
        if (n_half > 0) {
          say("  ! ", var, "：", n_half, " 筆為非整數（跨波 ",
              if (identical(SAMPLE_TYPE, "member")) MEMBER$therm_stat else "統計值",
              "），已四捨五入為整數")
          v <- floor(v + 0.5)
        }
      }
      as.character(v)
    })
}

# ---------------------------------------------------------------------------
# 3. 讀母體
# ---------------------------------------------------------------------------
read_target <- function(var) {
  f <- TARGET_FILES[[var]]
  if (is.null(f)) stop(sprintf("TARGET_FILES 沒有指定變數 %s 的母體檔", var))
  p <- file.path(abs_in(TARGET_DIR), f)
  if (!file.exists(p)) stop("找不到母體檔：", p)
  d <- read.csv(p, fileEncoding = "UTF-8", stringsAsFactors = FALSE)
  d <- d[d$variable == var, ]
  if (!nrow(d)) stop(sprintf("母體檔 %s 裡沒有變數 %s", f, var))
  level <- if (var %in% NUMERIC_VARS) as.character(d$code) else norm_tw(d$label)
  data.frame(code = as.character(d$code), level = level, N = d$N,
             stringsAsFactors = FALSE)
}

# ---------------------------------------------------------------------------
# 4-5. collapse（母體與樣本同步）+ 對齊檢查
# ---------------------------------------------------------------------------
build_var <- function(sam, var, spec) {
  tg0 <- read_target(var)
  sv  <- norm_tw(harmonize(sam, var, tg0))

  tg <- tg0
  tg$level <- apply_collapse(tg$level, spec)
  tg <- tg[!is.na(tg$level), ]
  tg <- as.data.frame(tg |> group_by(level) |> summarise(N = sum(N), .groups = "drop"))
  sv <- apply_collapse(sv, spec)

  lv <- collapse_levels(tg0$level, spec)
  lv <- lv[lv %in% tg$level]
  tg <- tg[match(lv, tg$level), ]
  tg$prop <- tg$N / sum(tg$N)

  list(values = sv, target = tg, levels = lv,
       extra = setdiff(unique(na.omit(sv)), lv),
       empty = lv[!lv %in% unique(na.omit(sv))])
}

say("")
say("---- collapse 與對齊檢查 ----")
built <- list(); problems <- c()
for (v in RAKE_VARS) {
  spec <- get_spec(v)
  b <- build_var(sam, v, spec)

  # 教育：母體有而樣本沒有的類別出現時，自動退回較粗版本
  if (v == "edu" && isTRUE(OPTS$edu_auto_fallback)) {
    order_fb <- c("A", "B", "C")
    cur <- if (is.character(COLLAPSE$edu)) COLLAPSE$edu else NA
    while (!is.na(cur) && (length(b$empty) || length(b$extra)) &&
           match(cur, order_fb) < length(order_fb)) {
      nxt <- order_fb[match(cur, order_fb) + 1]
      say("  edu：類別「", paste(c(b$empty, b$extra), collapse = "／"),
          "」對不上，自動退回版本 ", nxt)
      cur <- nxt; COLLAPSE$edu <- nxt
      b <- build_var(sam, v, PRESETS$edu[[nxt]])
    }
  }

  if (length(b$extra))
    problems <- c(problems, sprintf("%s：樣本出現母體沒有的類別 -> %s",
                                    v, paste(b$extra, collapse = "／")))
  if (length(b$empty))
    problems <- c(problems, sprintf("%s：母體有但樣本 0 人的類別 -> %s",
                                    v, paste(b$empty, collapse = "／")))

  n_na <- sum(is.na(b$values))
  say(sprintf("  %-10s 版本=%-7s 類別數=%d  NA=%d (%.1f%%)  類別：%s",
              v, ver_name(v),
              length(b$levels), n_na, 100 * n_na / nrow(sam),
              paste(b$levels, collapse = " / ")))
  built[[v]] <- b
}
if (length(problems)) {
  for (p in problems) say("  !! ", p)
  stop("母體與樣本的類別對不齊，請調整 COLLAPSE 或 OPTS 後重跑（詳見上方訊息）")
}

# ---------------------------------------------------------------------------
# 5a. 母體目標：TEDS 聯合表（TARGET_SOURCE = "joint"）
# ---------------------------------------------------------------------------
# TARGET_FILES 只用來決定類別；目標比例改成聯合表依 JOINT$count_col 加總。
# 只保留 RAKE_VARS 在 collapse 後都有值、類別對得上的格，
# raking、MultiCalibration、PAPP-BART 因此用同一群 TEDS 受訪者當母體。
if (!TARGET_SOURCE %in% c("joint", "files")) stop("TARGET_SOURCE 必須是 \"joint\" 或 \"files\"")
if (!JOINT$count_col %in% c("n", "n_wt")) stop("JOINT$count_col 必須是 \"n\" 或 \"n_wt\"")
tj_path <- abs_in(JOINT$file)
if (!file.exists(tj_path)) stop("找不到聯合表：", tj_path)
tj <- read.csv(tj_path, fileEncoding = "UTF-8", colClasses = "character", check.names = FALSE)
tj_miss <- setdiff(c(RAKE_VARS, "n", "n_wt"), names(tj))
if (length(tj_miss)) stop("聯合表缺少欄位：", paste(tj_miss, collapse = ", "))
tj_vars <- intersect(names(TARGET_FILES), names(tj))
tj_raw  <- lapply(setNames(tj_vars, tj_vars), function(v)
  if (v %in% NUMERIC_VARS) as.character(suppressWarnings(as.numeric(tj[[v]]))) else norm_tw(tj[[v]]))  # "05" -> "5"
tj_keep <- Reduce(`&`, lapply(RAKE_VARS, function(v) {
  x <- apply_collapse(tj_raw[[v]], get_spec(v))   # edu 會用自動退回後的版本
  !is.na(x) & x %in% built[[v]]$levels
}))
if (!any(tj_keep)) stop("聯合表沒有任何一格對得上 RAKE_VARS 的類別；TARGET_FILES 與聯合表的年份是否一致？")
tj_count <- as.numeric(tj[[JOINT$count_col]])[tj_keep]
tj_margin <- function(v, spec, levels) {
  x  <- apply_collapse(tj_raw[[v]][tj_keep], spec)
  ok <- !is.na(x) & x %in% levels
  s  <- tapply(tj_count[ok], factor(x[ok], levels = levels), sum)
  s[is.na(s)] <- 0
  as.numeric(s) / sum(s)
}
use_joint_target <- function(b, v, spec) {
  if (!identical(TARGET_SOURCE, "joint") || !v %in% tj_vars) return(b)
  p <- tj_margin(v, spec, b$levels)
  b$target$prop <- p
  b$target$N    <- p * sum(tj_count)
  b
}
target_label <- function(v) {
  if (identical(TARGET_SOURCE, "joint") && v %in% tj_vars)
    sprintf("TEDS %s 聯合表（%s）", joint_name, if (identical(JOINT$count_col, "n_wt")) "W 加權" else "未加權")
  else TARGET_FILES[[v]]
}

say("")
if (identical(TARGET_SOURCE, "joint")) {
  say("---- 母體目標：", JOINT$file, "（", JOINT$count_col, "）----")
  say(sprintf("  使用 %d / %d 格（TEDS n = %g / %g）", sum(tj_keep), nrow(tj),
              sum(as.numeric(tj$n)[tj_keep]), sum(as.numeric(tj$n))))
  say("  與 TARGET_FILES 邊際的最大差距：")
  for (v in RAKE_VARS) {
    old <- built[[v]]$target$prop
    built[[v]] <- use_joint_target(built[[v]], v, get_spec(v))
    say(sprintf("    %-10s %.2f 個百分點", v, 100 * max(abs(built[[v]]$target$prop - old))))
    zero <- built[[v]]$levels[built[[v]]$target$prop == 0]
    if (length(zero)) say("    ! ", v, " 的聯合表目標在「", paste(zero, collapse = "／"), "」為 0")
  }
} else say("---- 母體目標：TARGET_FILES ----")

# ---------------------------------------------------------------------------
# 5b. 聯合目標：TEDS 聯合表 → 同一套 collapse → 依 RAKE_VARS 加總 → IPF 錨定
# ---------------------------------------------------------------------------
# 論文式 (9) 需要母體每一格的人數 N_s。邊際檔只有一階，所以另讀 TEDS 聯合表，
# 套用和樣本端相同的 collapse，再以 IPF 把它的一階邊際拉到 TARGET_FILES 的邊際：
# 一階邊際 = raking 的目標，交互結構 = TEDS 的關聯。IPF 不會創造新格，
# TEDS 沒出現過的格仍為 0（論文註 5：母體不存在的格不列入）。
say("")
say("---- 聯合目標 ----")
joint_path <- abs_in(JOINT$file)
if (!file.exists(joint_path)) stop("找不到聯合表：", joint_path)
if (!JOINT$count_col %in% c("n", "n_wt")) stop("JOINT$count_col 必須是 \"n\" 或 \"n_wt\"")
jt <- read.csv(joint_path, fileEncoding = "UTF-8", colClasses = "character",
               check.names = FALSE)
miss_col <- setdiff(c(RAKE_VARS, "n", "n_wt"), names(jt))
if (length(miss_col)) stop("聯合表缺少欄位：", paste(miss_col, collapse = ", "))
jt$.n    <- as.numeric(jt$n)
jt$.n_wt <- as.numeric(jt$n_wt)
say("聯合表：", JOINT$file, "（", nrow(jt), " 格；TEDS n = ", sum(jt$.n),
    "；計數欄 = ", JOINT$count_col, "）")

for (v in RAKE_VARS) {
  x <- if (v %in% NUMERIC_VARS) as.character(suppressWarnings(as.numeric(jt[[v]])))  # "05" -> "5"
       else norm_tw(jt[[v]])
  x <- apply_collapse(x, get_spec(v))            # edu 會用自動退回後的版本
  bad <- setdiff(unique(na.omit(x)), built[[v]]$levels)
  if (length(bad))
    say("  ! 聯合表的 ", v, " 有母體檔沒有的類別（該格捨棄）：", paste(bad, collapse = "／"))
  x[x %in% bad] <- NA
  jt[[v]] <- x
}
keep_j <- stats::complete.cases(jt[, RAKE_VARS, drop = FALSE])
if (any(!keep_j))
  say(sprintf("  捨棄含 NA／對不上類別的格：%d 格（TEDS n = %g，%.1f%%）",
              sum(!keep_j), sum(jt$.n[!keep_j]), 100 * sum(jt$.n[!keep_j]) / sum(jt$.n)))

tg_joint <- as.data.frame(jt[keep_j, ] |>
  group_by(across(all_of(RAKE_VARS))) |>
  summarise(n_teds = sum(.n), n_teds_wt = sum(.n_wt), .groups = "drop"))
n_theory <- prod(vapply(RAKE_VARS, function(v) length(built[[v]]$levels), numeric(1)))
say(sprintf("  依 %d 個調整變數加總：%d 格（理論 %d 格，%.1f%%）",
            length(RAKE_VARS), nrow(tg_joint), n_theory, 100 * nrow(tg_joint) / n_theory))

for (v in RAKE_VARS) {
  miss_lv <- setdiff(built[[v]]$levels, tg_joint[[v]])
  if (length(miss_lv))
    stop(sprintf("聯合表的 %s 缺少類別「%s」，無法錨定；請調整 COLLAPSE",
                 v, paste(miss_lv, collapse = "／")))
}

pop_total <- sum(built[[RAKE_VARS[1]]]$target$N)   # 只決定計數的尺度，不影響權數
margin_gap <- function(N) max(vapply(RAKE_VARS, function(v) {
  cur <- tapply(N, factor(tg_joint[[v]], levels = built[[v]]$levels), sum) / sum(N)
  max(abs(as.numeric(cur) - built[[v]]$target$prop))
}, numeric(1)))

N_joint <- tg_joint[[if (identical(JOINT$count_col, "n_wt")) "n_teds_wt" else "n_teds"]]
N_joint <- N_joint / sum(N_joint) * pop_total
gap0 <- margin_gap(N_joint)
if (isTRUE(JOINT$anchor)) {
  it <- 0
  while (it < JOINT$ipf_maxit && margin_gap(N_joint) > JOINT$ipf_tol) {
    it <- it + 1
    for (v in RAKE_VARS) {
      f   <- factor(tg_joint[[v]], levels = built[[v]]$levels)
      cur <- as.numeric(tapply(N_joint, f, sum))
      N_joint <- N_joint * (built[[v]]$target$prop * pop_total / cur)[as.integer(f)]
    }
  }
  gap1 <- margin_gap(N_joint)
  say(sprintf("  IPF 錨定：%d 輪；一階邊際與目標邊際的最大差距 %.4f → %.2e",
              it, gap0, gap1))
  if (gap1 > 1e-6)
    stop("IPF 沒有收斂（聯合表的零格使各邊際無法同時對齊），請合併類別或設 JOINT$anchor = FALSE")
} else {
  say(sprintf("  未錨定：聯合表邊際與 TARGET_FILES 的最大差距 %.4f（multical 對齊的是聯合表自己的邊際）",
              gap0))
}
tg_joint$N_target <- N_joint
write.csv(tg_joint, file.path(out_dir, sprintf("target_%s.csv", tag)),
          row.names = FALSE, fileEncoding = "UTF-8")

# ---------------------------------------------------------------------------
# 6. multical
# ---------------------------------------------------------------------------
df <- data.frame(caseid = sam$caseid)
for (v in RAKE_VARS) df[[v]] <- factor(built[[v]]$values, levels = built[[v]]$levels)

complete <- stats::complete.cases(df[, RAKE_VARS, drop = FALSE])
say("")
say("完整個案：", sum(complete), " / ", nrow(df),
    "（因調整變數缺值排除 ", sum(!complete), " 人）")
if (sum(complete) < 30) stop("完整個案太少，無法校準")
dfc <- df[complete, ]

key_of <- function(d) do.call(paste, c(lapply(d[RAKE_VARS], as.character), sep = "\r"))

# --- 格層級資料：樣本格（n_s）與母體格（N_s）合併 ---------------------------
# 論文把權數定義在格上（同格同權數）。multical() 的公開介面在個人層級解，
# 二次規劃矩陣是 n × n（member 模式 n ≈ 8,800 時非常慢且吃記憶體）；
# 這裡改在格層級呼叫同一個求解器 multical:::calibrate_，解完全相同
# （已用模擬資料驗證：同 λ 下與 multical() 的權數差 < 1e-8），只是快很多。
samp_cells <- as.data.frame(dfc |> count(across(all_of(RAKE_VARS)), name = "n_s"))
samp_cells[RAKE_VARS] <- lapply(samp_cells[RAKE_VARS], as.character)
units <- full_join(samp_cells, tg_joint[, c(RAKE_VARS, "N_target")], by = RAKE_VARS)
units$n_s[is.na(units$n_s)] <- 0L
units$N_target[is.na(units$N_target)] <- 0
for (v in RAKE_VARS) units[[v]] <- factor(units[[v]], levels = built[[v]]$levels)
nz <- units$n_s > 0
ns <- units$n_s[nz]

# --- 支撐檢查（論文 Fig. 1、Assumption 2）------------------------------------
# pop_uncovered   ：母體中落在「樣本 0 人」的格的比例 —— 權數無法觸及
# sample_no_target：樣本中落在「聯合表 0 人」的格的比例 —— 交互約束會把這些人的權數往下壓
cov_orders <- sort(unique(c(seq_len(min(MULTICAL$report_order, length(RAKE_VARS))),
                            length(RAKE_VARS))))
coverage <- bind_rows(lapply(cov_orders, function(k) {
  bind_rows(lapply(combn(RAKE_VARS, k, simplify = FALSE), function(vs) {
    g <- units |> group_by(across(all_of(vs))) |>
      summarise(n = sum(n_s), N = sum(N_target), .groups = "drop")
    data.frame(order = k, vars = paste(vs, collapse = " × "),
               cells_target = sum(g$N > 0), cells_sample = sum(g$n > 0),
               cells_uncovered = sum(g$N > 0 & g$n == 0),
               pop_uncovered = sum(g$N[g$n == 0]) / sum(g$N),
               sample_no_target = sum(g$n[g$N == 0]) / sum(g$n))
  }))
}))
write.csv(coverage, file.path(out_dir, sprintf("coverage_%s.csv", tag)),
          row.names = FALSE, fileEncoding = "UTF-8")
say("")
say("---- 支撐檢查（各階取最差的變數組合）----")
for (k in cov_orders) {
  ck <- coverage[coverage$order == k, ]
  say(sprintf("  %d 階：母體落在樣本空格的比例 最大 %.2f%%（%s）；樣本落在聯合表空格的比例 最大 %.2f%%（%s）",
              k, 100 * max(ck$pop_uncovered), ck$vars[which.max(ck$pop_uncovered)],
              100 * max(ck$sample_no_target), ck$vars[which.max(ck$sample_no_target)]))
}

# --- 求解 --------------------------------------------------------------------
run_calibrate <- function(order, lambda) {
  do.call(multical:::calibrate_, c(list(
    cells = units[, RAKE_VARS], sample_counts = units$n_s,
    target_counts = units$N_target, order = order, exact_order = 1,
    lambda = lambda, lambda_max = NULL, n_lambda = MULTICAL$n_lambda,
    lambda_min_ratio = MULTICAL$lambda_min_ratio,
    lowlim = MULTICAL$lowlim, uplim = MULTICAL$uplim, base_weights = NULL,
    scale_by_order = TRUE, verbose = FALSE), MULTICAL$osqp))
}
mc_warn <- c()
solve_safely <- function(order, lambda) withCallingHandlers(
  tryCatch(run_calibrate(order, lambda), error = function(e)
    stop("multical 求解失敗：", conditionMessage(e),
         if (is.finite(MULTICAL$uplim))
           "\n  → 權數上限 uplim 可能讓邊際約束無解，試著調高或設為 Inf" else "",
         call. = FALSE)),
  warning = function(cnd) {
    m <- conditionMessage(cnd)
    if (!grepl("deprecated", m)) mc_warn <<- c(mc_warn, m)
    invokeRestart("muffleWarning")
  })

say("")
say("---- 執行 multical（order = ", MULTICAL$order, "）----")
t0 <- Sys.time()
# order = 1 時交互項為空，目標函數只剩權數變異數懲罰，任何 λ > 0 的解都相同
# （= 論文式 4 的平方距離版 raking）。multical 在 order = 1、lambda = NULL 時會把 λ 設為 0，
# 目標函數整個消失、解只是任一可行解，所以這裡改用 λ = 1。
# 同一個 λ = 1 的 order = 1 解也拿來當「raking」基準（論文 Fig. 2、3 的比較對象）。
rake_w <- as.matrix(solve_safely(1, 1))[, 1]
lam_arg <- if (MULTICAL$order == 1 && is.null(MULTICAL$lambda)) 1 else MULTICAL$lambda
Wm <- if (MULTICAL$order == 1) {
  matrix(rake_w, ncol = 1, dimnames = list(NULL, lam_arg))
} else {
  as.matrix(solve_safely(MULTICAL$order, lam_arg))
}
lam_vec <- as.numeric(colnames(Wm))
say(sprintf("求解 %d 個 λ，耗時 %.1f 秒（樣本格 %d、母體格 %d、合併 %d 格）",
            length(lam_vec), as.numeric(difftime(Sys.time(), t0, units = "secs")),
            sum(nz), sum(units$N_target > 0), nrow(units)))
for (m in unique(mc_warn)) say("  [multical 警告] ", gsub("\n+", " ", m))

# --- λ 路徑：不平衡 vs 有效樣本數（論文 Fig. 2）------------------------------
# 不平衡的定義與 multical 相同：一階 + 各階交互（依階數縮放）的
# 「加權比例 − 目標比例」之平方和開根號
D_bal <- Matrix::sparse.model.matrix(~ . - 1, units[, RAKE_VARS])
term_order <- rep(1L, ncol(D_bal))
if (MULTICAL$order > 1) {
  D_int <- multical:::create_design_matrix(units[, RAKE_VARS], MULTICAL$order)
  # 縮放後欄名會消失，階數要先從未縮放的欄名（冒號個數）算出來
  term_order <- c(term_order,
                  nchar(colnames(D_int)) - nchar(gsub(":", "", colnames(D_int), fixed = TRUE)) + 1L)
  D_bal <- cbind(D_bal, multical:::scale_design_matrix(D_int))
}
imbalance_of <- function(g) {
  w_full <- numeric(nrow(units)); w_full[nz] <- g
  multical:::compute_balance(D_bal, w_full, units$n_s, units$N_target)
}
path_row <- function(g, lambda) {
  imb <- imbalance_of(g)
  row <- data.frame(lambda = lambda, n_eff = sum(ns * g)^2 / sum(ns * g^2),
                    min_w = min(g), max_w = max(g), imbalance = sqrt(sum(imb^2)))
  for (k in seq_len(MULTICAL$order))
    row[[paste0("imbalance_order", k)]] <- sqrt(sum(imb[term_order == k]^2))
  row
}
path <- bind_rows(lapply(seq_along(lam_vec), function(i) path_row(Wm[, i], lam_vec[i])))
rake_row <- path_row(rake_w, NA_real_)

# 選 λ：以 raking 為基準、最小 λ 為最佳，達到 balance_threshold 的改善量後取 n_eff 最大者
if (length(lam_vec) == 1) {
  sel <- 1L
} else {
  base_imb <- rake_row$imbalance
  best_imb <- path$imbalance[nrow(path)]
  goal     <- base_imb - MULTICAL$balance_threshold * (base_imb - best_imb)
  meets    <- which(path$imbalance <= goal + 1e-12)
  sel <- if (!length(meets)) nrow(path) else meets[which.max(path$n_eff[meets])]
}
den <- rake_row$imbalance - min(path$imbalance)
path$pct_improvement <- if (den > 0) 100 * (rake_row$imbalance - path$imbalance) / den else NA_real_
path$deff     <- sum(ns) / path$n_eff
path$selected <- seq_len(nrow(path)) == sel
write.csv(path, file.path(out_dir, sprintf("lambda_path_%s.csv", tag)),
          row.names = FALSE, fileEncoding = "UTF-8")

g_sel <- Wm[, sel]
w <- g_sel[match(key_of(dfc), key_of(units[nz, ]))]
w <- w / mean(w)
w_rake <- rake_w[match(key_of(dfc), key_of(units[nz, ]))]
w_rake <- w_rake / mean(w_rake)

say(sprintf("選中的 λ = %.4g（第 %d / %d 個；平衡改善 %.1f%%）", lam_vec[sel], sel,
            length(lam_vec), path$pct_improvement[sel]))
say(sprintf("權數：min=%.3f max=%.3f mean=%.3f sd=%.3f", min(w), max(w), mean(w), sd(w)))
deff <- 1 + (sd(w) / mean(w))^2
say(sprintf("design effect = %.3f；有效樣本數 = %.0f", deff, length(w) / deff))
deff_r <- 1 + (sd(w_rake) / mean(w_rake))^2
say(sprintf("（對照：order = 1 的 raking 解 design effect = %.3f；有效樣本數 = %.0f；權數 %.3f–%.3f）",
            deff_r, length(w_rake) / deff_r, min(w_rake), max(w_rake)))

# ---------------------------------------------------------------------------
# 7. 輸出
# ---------------------------------------------------------------------------
sam$weight <- NA_real_
sam$weight[complete] <- w
sam$excluded_reason <- NA_character_
for (v in rev(RAKE_VARS))
  sam$excluded_reason[is.na(built[[v]]$values)] <- paste0(v, " 缺值")

wt <- sam[, c("memberId", "caseid", "weight", "excluded_reason")]
write.csv(wt, file.path(out_dir, sprintf("weights_%s.csv", tag)),
          row.names = FALSE, fileEncoding = "UTF-8")

# --- 要出圖出表的變數 --------------------------------------------------------
# 除了 RAKE_VARS，只要 TARGET_FILES 有指定、而且這一波真的問得到的變數，
# 都會一併畫出分布（例如沒有拿來校準的省籍），方便檢查校準
# 對這些變數造成了什麼影響。
report_vars <- character(0)
for (v in names(TARGET_FILES)) {
  if (v %in% RAKE_VARS) { report_vars <- c(report_vars, v); next }
  b <- tryCatch(build_var(sam, v, get_spec(v)), error = function(e) NULL)
  if (is.null(b) || all(is.na(b$values))) next
  # edu 沒有參與調整時（例如 drop=edu）也要自動退回較粗版本，否則對不上就不會出表
  if (v == "edu" && isTRUE(OPTS$edu_auto_fallback) && is.character(COLLAPSE$edu)) {
    order_fb <- c("A", "B", "C")
    while (length(b$extra) && match(COLLAPSE$edu, order_fb) < length(order_fb)) {
      nxt <- order_fb[match(COLLAPSE$edu, order_fb) + 1]
      say("  [出圖] edu：類別「", paste(b$extra, collapse = "／"), "」對不上，自動退回版本 ", nxt)
      COLLAPSE$edu <- nxt
      b <- build_var(sam, v, PRESETS$edu[[nxt]])
    }
  }
  if (length(b$extra)) {
    say("  [僅出圖] ", v, "：樣本有母體沒有的類別 ", paste(b$extra, collapse = "／"),
        "，不列入報表")
    next
  }
  built[[v]] <- use_joint_target(b, v, get_spec(v))
  report_vars <- c(report_vars, v)
}
say("出圖／出表的變數：", paste(report_vars, collapse = ", "),
    "（其中 ", paste(RAKE_VARS, collapse = ", "), " 有納入校準）")

# --- 重新編碼後的分析樣本 ----------------------------------------------------
# compare_raking_multical.R 需要每個人 collapse 後的類別，才能用同一份聯合目標
# 評估 anesrake 權數的交互平衡（raking_NTUWS.R 的輸出沒有保留這些欄位）
analysis <- data.frame(memberId = sam$memberId, caseid = sam$caseid)
for (v in report_vars) analysis[[v]] <- built[[v]]$values
analysis$complete <- complete
write.csv(analysis, file.path(out_dir, sprintf("analysis_%s.csv", tag)),
          row.names = FALSE, fileEncoding = "UTF-8")

# --- 分布表：母體 / 樣本(校準前) / 樣本(校準後) ------------------------------
# 欄名沿用 raking_NTUWS.R（pct_raked = 校準後），方便與 raking 結果直接比較
dist <- lapply(report_vars, function(v) {
  x  <- built[[v]]$values[complete]
  lv <- built[[v]]$levels
  ok <- !is.na(x)                       # 未納入校準的變數可能仍有缺值
  n  <- sapply(lv, function(l) sum(x[ok] == l))
  wn <- sapply(lv, function(l) sum(w[ok][x[ok] == l]))
  data.frame(variable = v, in_raking = v %in% RAKE_VARS,
             collapse_version = ver_name(v), label = lv, n_sample = n,
             pct_sample = round(100 * n / sum(n), 2),
             pct_target = round(100 * built[[v]]$target$prop, 2),
             pct_raked  = round(100 * wn / sum(wn), 2), row.names = NULL)
}) |> bind_rows()
write.csv(dist, file.path(out_dir, sprintf("dist_%s.csv", tag)),
          row.names = FALSE, fileEncoding = "UTF-8")

say(sprintf("校準後與母體的最大差距（納入校準者）：%.3f 個百分點",
            max(abs(dist$pct_raked[dist$in_raking] - dist$pct_target[dist$in_raking]))))
d_off <- dist[!dist$in_raking, ]
if (nrow(d_off))
  say(sprintf("未納入校準者與母體的最大差距：%.3f 個百分點",
              max(abs(d_off$pct_raked - d_off$pct_target))))
if (is.finite(MULTICAL$uplim)) {
  n_cap <- sum(w >= MULTICAL$uplim - 1e-6)
  if (n_cap > 0)
    say(sprintf("有 %d 人 (%.1f%%) 的權數觸到上限 uplim=%g", n_cap, 100 * n_cap / length(w),
                MULTICAL$uplim))
}

# --- 交互平衡表（論文 Fig. 3）：raking 解 vs multilevel calibration -----------
units$w_rake <- 0; units$w_rake[nz] <- ns * rake_w
units$w_sel  <- 0; units$w_sel[nz]  <- ns * g_sel
bal_orders <- seq_len(min(MULTICAL$report_order, length(RAKE_VARS)))
balance <- bind_rows(lapply(bal_orders, function(k) {
  bind_rows(lapply(combn(RAKE_VARS, k, simplify = FALSE), function(vs) {
    g <- units |> group_by(across(all_of(vs))) |>
      summarise(n = sum(n_s), N = sum(N_target), wr = sum(w_rake), ws = sum(w_sel),
                .groups = "drop")
    data.frame(order = k, vars = paste(vs, collapse = " × "),
               cell = do.call(paste, c(lapply(g[vs], as.character), sep = " | ")),
               target_count = g$N, target_pct = 100 * g$N / sum(g$N),
               sample_n = g$n, sample_pct = 100 * g$n / sum(g$n),
               raking_pct = 100 * g$wr / sum(g$wr),
               mlcal_pct  = 100 * g$ws / sum(g$ws))
  }))
}))
balance$rel_imbalance_raking <- ifelse(balance$target_count > 0,
  (balance$raking_pct - balance$target_pct) / balance$target_pct, NA_real_)
balance$rel_imbalance_mlcal  <- ifelse(balance$target_count > 0,
  (balance$mlcal_pct - balance$target_pct) / balance$target_pct, NA_real_)
write.csv(balance, file.path(out_dir, sprintf("balance_%s.csv", tag)),
          row.names = FALSE, fileEncoding = "UTF-8")

say("")
say("---- 交互平衡（每個變數組合的 TVD 取平均，單位：百分點）----")
tvd_by <- balance |> group_by(order, vars) |>
  summarise(sample = sum(abs(sample_pct - target_pct)) / 2,
            raking = sum(abs(raking_pct - target_pct)) / 2,
            mlcal  = sum(abs(mlcal_pct  - target_pct)) / 2, .groups = "drop") |>
  group_by(order) |>
  summarise(sample = mean(sample), raking = mean(raking), mlcal = mean(mlcal), .groups = "drop")
for (i in seq_len(nrow(tvd_by)))
  say(sprintf("  %d 階：未加權 %.2f　raking %.2f　multilevel calibration %.2f",
              tvd_by$order[i], tvd_by$sample[i], tvd_by$raking[i], tvd_by$mlcal[i]))

SERIES_COLS <- c("母體" = "#B0413E", "樣本（校準前）" = "#9AA5AD",
                 "樣本（校準後）" = "#3F6C8F")

base_theme <- function() {
  theme_minimal(base_size = 12, base_family = "Heiti TC") +
    theme(legend.position = "top", panel.grid.major.x = element_blank(),
          plot.title = element_text(face = "bold"), plot.subtitle = element_text(size = 9))
}

# --- 圖 1：母體 / 校準前 / 校準後 --------------------------------------------
for (v in report_vars) {
  d <- dist |> filter(variable == v) |>
    select(label, `母體` = pct_target, `樣本（校準前）` = pct_sample,
           `樣本（校準後）` = pct_raked) |>
    pivot_longer(-label, names_to = "series", values_to = "pct") |>
    mutate(label  = factor(label, levels = built[[v]]$levels),
           series = factor(series, levels = names(SERIES_COLS)))

  n_lv <- length(built[[v]]$levels)
  p <- ggplot(d, aes(label, pct, fill = series)) +
    geom_col(position = position_dodge(width = 0.8), width = 0.72, alpha = 0.92) +
    geom_text(aes(label = sprintf("%.1f", pct)),
              position = position_dodge(width = 0.8), vjust = -0.35,
              size = if (n_lv > 8) 1.9 else 2.6) +
    scale_fill_manual(values = SERIES_COLS) +
    scale_y_continuous(labels = label_percent(scale = 1),
                       expand = expansion(mult = c(0, .12))) +
    labs(title = sprintf("%s：%s（collapse 版本 %s）%s", run_label, v, ver_name(v),
                         if (v %in% RAKE_VARS) "" else "【未納入校準】"),
         subtitle = sprintf("%s；母體來源：%s；完整個案 N = %s", method_tag,
                            target_label(v), format(sum(complete), big.mark = ",")),
         x = NULL, y = "百分比", fill = NULL) +
    base_theme()
  ggsave(file.path(out_dir, sprintf("dist_%s_%s.png", tag, v)), p,
         width = max(9, 1 + 0.8 * n_lv), height = 5.5, dpi = 300)
}

# --- 圖 2：collapse 前後對比 -------------------------------------------------
# 上排是母體檔的原始類別，下排是套用 COLLAPSE 之後的類別，看得出來合併掉了什麼
COLLAPSE_COLS <- c("母體" = "#B0413E", "樣本" = "#9AA5AD")

side_by_side <- function(b) {                   # 取出母體與樣本的百分比
  lv <- unique(c(b$levels, setdiff(unique(na.omit(b$values)), b$levels)))
  x  <- b$values[!is.na(b$values)]
  n  <- sapply(lv, function(l) sum(x == l))
  tp <- b$target$prop[match(lv, b$target$level)]
  data.frame(label = factor(lv, levels = lv),
             `母體` = round(100 * ifelse(is.na(tp), 0, tp), 2),
             `樣本` = round(100 * n / sum(n), 2),
             check.names = FALSE, row.names = NULL)
}

for (v in report_vars) {
  spec <- get_spec(v)
  if (!length(spec)) {                          # 沒有合併就不必畫對比
    say("  [collapse 對比] ", v, "：版本 ", ver_name(v), " 未做任何合併，略過")
    next
  }
  before <- tryCatch(build_var(sam, v, list()), error = function(e) NULL)
  if (is.null(before)) next
  before <- use_joint_target(before, v, list())

  d <- bind_rows(
    side_by_side(before)   |> mutate(stage = sprintf("collapse 前（%d 類）",
                                                     nrow(side_by_side(before)))),
    side_by_side(built[[v]]) |> mutate(stage = sprintf("collapse 後（%d 類）",
                                                     length(built[[v]]$levels)))
  ) |>
    pivot_longer(c(`母體`, `樣本`), names_to = "series", values_to = "pct") |>
    mutate(stage = factor(stage, levels = unique(stage)),
           series = factor(series, levels = names(COLLAPSE_COLS)))

  p <- ggplot(d, aes(label, pct, fill = series)) +
    geom_col(position = position_dodge(width = 0.8), width = 0.72, alpha = 0.92) +
    geom_text(aes(label = sprintf("%.1f", pct)),
              position = position_dodge(width = 0.8), vjust = -0.35, size = 2.2) +
    facet_wrap(~ stage, ncol = 1, scales = "free_x") +
    scale_fill_manual(values = COLLAPSE_COLS) +
    scale_y_continuous(labels = label_percent(scale = 1),
                       expand = expansion(mult = c(0, .15))) +
    labs(title = sprintf("%s：%s 的 collapse 前後對比（版本 %s）",
                         run_label, v, ver_name(v)),
         subtitle = "上：母體檔的原始類別；下：套用 COLLAPSE 之後。百分比皆以各自的有效樣本為分母",
         x = NULL, y = "百分比", fill = NULL) +
    base_theme() + theme(strip.text = element_text(face = "bold", size = 10))
  ggsave(file.path(out_dir, sprintf("collapse_%s_%s.png", tag, v)), p,
         width = max(9, 1 + 0.7 * nrow(side_by_side(before))), height = 8, dpi = 300)
}

# --- 圖 3：λ 路徑（論文 Fig. 2）----------------------------------------------
if (nrow(path) > 1) {
  rake_pt <- data.frame(n_eff = rake_row$n_eff, rel = 100)
  p <- ggplot(path, aes(n_eff, 100 * imbalance / rake_row$imbalance)) +
    geom_line(colour = "#3F6C8F") + geom_point(colour = "#3F6C8F", size = 1.6) +
    geom_point(data = path[path$selected, ], colour = "#B0413E", size = 3.5) +
    geom_point(data = rake_pt, aes(n_eff, rel), shape = 17, colour = "#9AA5AD", size = 3.5) +
    annotate("text", x = path$n_eff[sel], y = 100 * path$imbalance[sel] / rake_row$imbalance,
             label = sprintf("  λ = %.3g", lam_vec[sel]), hjust = 0, vjust = -0.8, size = 3.2,
             family = "Heiti TC") +
    scale_y_continuous(labels = label_percent(scale = 1)) +
    labs(title = sprintf("%s：不平衡 vs 有效樣本數（order = %d）", run_label, MULTICAL$order),
         subtitle = sprintf("縱軸 = 交互不平衡相對 raking（灰三角）的比例；紅點 = 依 %.0f%% 規則選中的 λ",
                            100 * MULTICAL$balance_threshold),
         x = "有效樣本數", y = "不平衡（raking = 100%）") +
    base_theme() + theme(panel.grid.major.x = element_line())
  ggsave(file.path(out_dir, sprintf("frontier_%s.png", tag)), p,
         width = 8, height = 5.5, dpi = 300)
}

# --- 圖 4：各階交互的不平衡分布（論文 Fig. 3）--------------------------------
bal_long <- balance |> filter(target_count > 0) |>
  select(order, raking = rel_imbalance_raking, `multilevel calibration` = rel_imbalance_mlcal) |>
  pivot_longer(-order, names_to = "method", values_to = "rel") |>
  mutate(order = factor(sprintf("%d 階", order), levels = sprintf("%d 階", bal_orders)),
         method = factor(method, levels = c("raking", "multilevel calibration")))
p <- ggplot(bal_long, aes(order, abs(rel), fill = method)) +
  geom_boxplot(outlier.size = 0.4, outlier.alpha = 0.4, width = 0.6) +
  scale_fill_manual(values = c("raking" = "#9AA5AD", "multilevel calibration" = "#3F6C8F")) +
  scale_y_continuous(labels = label_percent()) +
  coord_cartesian(ylim = c(0, max(1e-6, stats::quantile(abs(bal_long$rel), 0.98, na.rm = TRUE)))) +
  labs(title = sprintf("%s：各階交互的不平衡（%s）", run_label, method_tag),
       subtitle = "|加權比例 − 目標比例| ÷ 目標比例；只含目標 > 0 的格；縱軸截在第 98 百分位",
       x = NULL, y = "相對不平衡", fill = NULL) +
  base_theme()
ggsave(file.path(out_dir, sprintf("balance_%s.png", tag)), p, width = 8, height = 5.5, dpi = 300)


diag_path <- file.path(out_dir, sprintf("diagnostics_%s.txt", tag))
con <- file(diag_path, open = "w", encoding = "UTF-8")
writeLines(c(sprintf("MultiCalibration_NTUWS.R  診斷報告   %s", format(Sys.time())), "",
             log_lines, "", "---- multical 設定 ----",
             sprintf("order = %d；n_lambda = %d；lambda_min_ratio = %g；lambda = %s",
                     MULTICAL$order, MULTICAL$n_lambda, MULTICAL$lambda_min_ratio,
                     if (is.null(MULTICAL$lambda)) "NULL（跑路徑）" else MULTICAL$lambda),
             sprintf("balance_threshold = %g；lowlim = %g；uplim = %g",
                     MULTICAL$balance_threshold, MULTICAL$lowlim, MULTICAL$uplim),
             sprintf("osqp：%s", paste(names(MULTICAL$osqp), unlist(MULTICAL$osqp),
                                      sep = " = ", collapse = "；")),
             sprintf("RAKE_VARS = %s", paste(RAKE_VARS, collapse = ", ")),
             sprintf("TARGET_SOURCE = %s；聯合表：%s；count_col = %s；anchor = %s",
                     TARGET_SOURCE, JOINT$file, JOINT$count_col, JOINT$anchor),
             "", "---- λ 路徑 ----"), con)
path_print <- path
num_cols <- vapply(path_print, is.numeric, logical(1))
path_print[num_cols] <- lapply(path_print[num_cols], signif, digits = 4)
capture.output(print(path_print, row.names = FALSE), file = con, append = TRUE)
writeLines(c("", "---- order = 1 raking 解（對照）----"), con)
capture.output(print(signif(rake_row[, names(rake_row) != "lambda"], 4), row.names = FALSE),
               file = con, append = TRUE)
close(con)

say("")
say("完成，輸出於：", out_dir)
