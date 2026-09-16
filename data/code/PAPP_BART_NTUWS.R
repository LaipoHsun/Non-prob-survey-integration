# =============================================================================
#  PAPP_BART_NTUWS.R —— 以 TEDS 為參考樣本，對 NTUWS 樣本做
#                       PAPP quasi-randomization（BART），產出擬權數
#
#  方法：Rafei, Flannagan & Elliott (2020). Big data for finite population
#        inference: applying quasi-random approaches to naturalistic driving
#        data using Bayesian additive regression trees. JSSAM 8(1), 148–180.
#        式 (2.5)、(2.7)：π_B(x) ∝ π_R(x) · e(x) / (1 − e(x))
#          模型 A：在 TEDS 上以 X 迴歸 logit(π_R)，π_R ∝ 1/W（BART 連續）
#          模型 B：NTUWS（Z = 1）與 TEDS（Z = 0）疊起來、不加權，以 X 分類 Z（BART probit）
#          擬權數 = (1/π̂_R) · (1 − ê)/ê，再做 trimming（§2.3）
#        不做 §2.4 的變異數估計（需要 Y）。
#
#  結構與 raking_NTUWS.R 相同：讀樣本、harmonize、collapse、對齊檢查（§0–5）
#  完全沿用；§5b 讀 TEDS 參考樣本並計算加權目標；§6 以 PAPP-BART 取代 anesrake；
#  §7 輸出同格式，TRIM$methods 列出的每一種 trimming 各輸出一組檔案（BART 只跑一次）。
#
#  用法：改最上面的 CONFIG 區塊，然後
#        Rscript data/code/PAPP_BART_NTUWS.R
#        Rscript data/code/PAPP_BART_NTUWS.R member
#
#  需要套件：BART（CRAN）
#
#  設計原則：原始資料檔一律不修改；所有重編碼與類別合併都在本檔進行，
#            且參考樣本端與樣本端「同步」套用同一份 collapse 設定。
# =============================================================================


# ############################################################################
# ## CONFIG —— 你只需要改這一段 ##############################################
# ############################################################################

# 樣本來源：
#   "wave"   逐波原始檔（lottery_repeated_raw_by_wave.xlsx 的某一個分頁）
#   "member" 個人層彙整檔（Phase0 人口學 + Phase2 政黨溫度計，已跨波整併）
# 也可由命令列覆寫：Rscript PAPP_BART_NTUWS.R LS_23NY   /   ... member
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

# 每個變數各自指定母體檔。PAPP 不對齊邊際，這些檔在這裡只用來
# 決定類別（harmonize、collapse、對齊檢查）；REF$target = "files" 時才當報表的母體
#   年份要和 REF$file 的聯合表一致（區域、年齡組的標籤不同）
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

# 這次真的要拿來建模（兩個 BART 模型的 X）的欄位
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

# 參考樣本：TEDS 聯合表（一列 = 一種 8 變數組合，n 人、W 總和 n_wt）
#   PAPP 需要個人層的 X 與 W。TEDS 的 W 在 sex×age×edu×arear 每一格內是常數，
#   聯合表的格更細，所以每格展開成 n 列、W = n_wt / n 就是每個人真正的 W。
REF <- list(
  file      = "data/output/portion_of_TEDS/2025/joint/joint_full_raw.csv",
  target    = "weighted",  # 報表（dist 表與圖）的「母體」：
                           #   "weighted" 參考樣本以 W 加權的分布（PAPP 實際逼近的母體）
                           #   "files"    TARGET_FILES 的邊際（與 raking 報表相同）
  pop_total = NA           # 算 π_R = 1 / (W · N / ΣW) 用的母體總數；NA = TARGET_FILES 第一個
                           #   變數的 N 總和。只影響 logit 的尺度，權數正規化後幾乎無差別
)

# BART 參數（論文 §5：MCMC 1,100 次，前 100 次 burn-in）
BART <- list(
  ntree_a = 200L,      # 模型 A（wbart 預設）
  ntree_b = 50L,       # 模型 B（pbart 預設）
  ndpost  = 1000L,
  nskip   = 100L,
  seed    = 20200205L, # MCMC 有隨機性，固定 seed 才能重現
  cores   = 1L,        # > 1 時改用 mc.wbart / mc.pbart 平行運算（macOS/Linux）
  e_clip  = 1e-6       # ê 夾在 [e_clip, 1 − e_clip]，避免 odds 為 0 或無限大
)

# trimming（論文 §2.3）：每一種各輸出一組檔案
#   "iqr"     K = 中位數 + c_iqr × IQR（式 2.9，Trim 2；論文模擬與實證都較好）
#   "entropy" K = sqrt(c_entropy × Σw² / n)（式 2.8，Trim 1）
#   "none"    不 trimming（對照）
# 超過 K 的截到 K，多出來的總量按比例分給其他人；分完若又有人超過 K 就重複
TRIM <- list(
  methods   = c("iqr", "none"),
  c_iqr     = 5,
  c_entropy = 6,
  maxit     = 100
)

# 欄位自動偵測失敗時在這裡指定欄名，例如 COLUMN_OVERRIDE <- c(edu = "S3 ")
COLUMN_OVERRIDE <- c()

RUN_NAME <- NA                 # 輸出檔名的方法標籤；NA = 自動（例如 papp_bart_trimiqr5）
OUT_ROOT <- "data/output"      # 輸出根目錄；實驗（例如合併聯合表、leave-one-variable-out）可以指到別處
OUT_DIR  <- NA                 # NA = <OUT_ROOT>/papp_bart/<WAVE>

# ############################################################################
# ## 以下為引擎，一般不需要修改 ##############################################
# ############################################################################

invisible(suppressWarnings(Sys.setlocale("LC_ALL", "zh_TW.UTF-8")))
if (!grepl("UTF-8", Sys.getlocale("LC_CTYPE"), fixed = TRUE))
  invisible(suppressWarnings(Sys.setlocale("LC_ALL", "en_US.UTF-8")))

if (!requireNamespace("BART", quietly = TRUE))
  stop("缺少套件 BART。安裝：install.packages(\"BART\")")

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
#   joint=2024_pan   → data/output/portion_of_TEDS/2024_pan/joint/joint_full_raw.csv（也可給完整路徑）
#   trim=iqr,none  target=files  seed=1  cores=4  ndpost=1000  nskip=100  run_name=自訂標籤
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
    joint    = REF$file <- if (grepl("/", .val, fixed = TRUE)) .val else
                 file.path("data/output/portion_of_TEDS", .val, "joint/joint_full_raw.csv"),
    target   = REF$target <- .val,
    trim     = TRIM$methods <- strsplit(.val, ",", fixed = TRUE)[[1]],
    seed     = BART$seed <- as.integer(.val),
    cores    = BART$cores <- as.integer(.val),
    ndpost   = BART$ndpost <- as.integer(.val),
    nskip    = BART$nskip <- as.integer(.val),
    run_name = RUN_NAME <- .val,
    drop     = RAKE_VARS <- {
                 .d <- strsplit(.val, ",", fixed = TRUE)[[1]]
                 if (length(setdiff(.d, RAKE_VARS)))
                   stop("drop= 的變數不在 RAKE_VARS 裡：", paste(setdiff(.d, RAKE_VARS), collapse = ", "))
                 setdiff(RAKE_VARS, .d)
               },
    out_root = OUT_ROOT <- .val,
    collapse = for (.c in strsplit(.val, ",", fixed = TRUE)[[1]]) {
                 .p <- strsplit(.c, ":", fixed = TRUE)[[1]]
                 if (length(.p) != 2) stop("collapse= 的格式是 變數:代號，例如 collapse=arear:B")
                 COLLAPSE[[.p[1]]] <- .p[2]
               },
    stop("不認得的命令列參數：", .key,
         "（可用 joint、target、trim、seed、cores、ndpost、nskip、run_name、drop、out_root、collapse）"))
}
bad_trim <- setdiff(TRIM$methods, c("iqr", "entropy", "none"))
if (length(bad_trim)) stop("TRIM$methods 只能是 iqr／entropy／none：", paste(bad_trim, collapse = ", "))
if (!REF$target %in% c("weighted", "files")) stop("REF$target 必須是 \"weighted\" 或 \"files\"")
run_label <- if (identical(SAMPLE_TYPE, "member")) "member_pooled" else WAVE

# 方法標籤：每一種 trimming 一個，依設定自動組出，避免不同設定互相覆蓋
# 聯合表來源取自路徑 portion_of_TEDS/<來源>/joint/；預設的 2025 不加註
joint_name <- basename(dirname(dirname(REF$file)))
trim_label <- function(m) switch(m, iqr = sprintf("trimiqr%g", TRIM$c_iqr),
                                 entropy = sprintf("trimentropy%g", TRIM$c_entropy), none = "notrim")
method_tag_of <- function(m) {
  if (!is.na(RUN_NAME)) return(paste0(RUN_NAME, "_", trim_label(m)))
  paste0("papp_bart_", trim_label(m),
         if (!identical(joint_name, "2025")) paste0("_j", joint_name) else "",
         if (identical(REF$target, "files")) "_tfiles" else "")
}
method_tag <- paste(vapply(TRIM$methods, method_tag_of, ""), collapse = "／")

root    <- find_root()
abs_in  <- function(p) if (grepl("^[/~]", p) || file.exists(p)) p else file.path(root, p)
out_dir <- if (is.na(OUT_DIR)) file.path(abs_in(OUT_ROOT), "papp_bart", run_label) else abs_in(OUT_DIR)
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
# 5b. 參考樣本：TEDS 聯合表 → 同一套 collapse → 展開成個人列 → 加權目標
# ---------------------------------------------------------------------------
# PAPP 需要參考樣本的個人層 X 與入樣機率。聯合表每格 n 人，W = n_wt / n 是
# 每個人真正的 W（TEDS 的 W 只依 sex×age×edu×arear 而定，聯合表的格更細）。
# 參考樣本只保留 RAKE_VARS 在 collapse 後都有值、且類別對得上的人。
say("")
say("---- 參考樣本（TEDS）----")
ref_path <- abs_in(REF$file)
if (!file.exists(ref_path)) stop("找不到聯合表：", ref_path)
jt <- read.csv(ref_path, fileEncoding = "UTF-8", colClasses = "character",
               check.names = FALSE)
miss_col <- setdiff(c(RAKE_VARS, "n", "n_wt"), names(jt))
if (length(miss_col)) stop("聯合表缺少欄位：", paste(miss_col, collapse = ", "))
jt$.n <- as.numeric(jt$n)
jt$.w <- as.numeric(jt$n_wt) / jt$.n
say("聯合表：", REF$file, "（", nrow(jt), " 格；TEDS n = ", sum(jt$.n), "）")

# 原始標籤（collapse 前），報表的加權目標要依各自的 collapse 版本重算
ref_vars <- intersect(names(TARGET_FILES), names(jt))
norm_ref <- function(v) if (v %in% NUMERIC_VARS)
  as.character(suppressWarnings(as.numeric(jt[[v]]))) else norm_tw(jt[[v]])   # "05" -> "5"

keep_j <- rep(TRUE, nrow(jt))
for (v in RAKE_VARS) {
  x <- apply_collapse(norm_ref(v), get_spec(v))  # edu 會用自動退回後的版本
  bad <- setdiff(unique(na.omit(x)), built[[v]]$levels)
  if (length(bad))
    say("  ! 聯合表的 ", v, " 有母體檔沒有的類別（該格捨棄）：", paste(bad, collapse = "／"))
  keep_j <- keep_j & !is.na(x) & !(x %in% bad)
}
if (any(!keep_j))
  say(sprintf("  捨棄含 NA／對不上類別的格：%d 格（TEDS n = %g，%.1f%%）",
              sum(!keep_j), sum(jt$.n[!keep_j]), 100 * sum(jt$.n[!keep_j]) / sum(jt$.n)))

idx     <- rep(which(keep_j), jt$.n[keep_j])     # 每格展開成 n 列
ref_raw <- lapply(setNames(ref_vars, ref_vars), function(v) norm_ref(v)[idx])
ref_W   <- jt$.w[idx]
ref_x   <- data.frame(lapply(setNames(RAKE_VARS, RAKE_VARS), function(v)
  factor(apply_collapse(ref_raw[[v]], get_spec(v)), levels = built[[v]]$levels)))
n_R <- length(ref_W)
say(sprintf("  參考樣本 n_R = %d；W：min=%.3f max=%.3f mean=%.3f", n_R,
            min(ref_W), max(ref_W), mean(ref_W)))
if (n_R < 30) stop("參考樣本太少，無法建模")

for (v in RAKE_VARS) {
  miss_lv <- setdiff(built[[v]]$levels, as.character(ref_x[[v]]))
  if (length(miss_lv))
    say(sprintf("  ! 參考樣本的 %s 在「%s」0 人：這些 NTUWS 受訪者的 ê 會趨近 1、權數趨近 0",
                v, paste(miss_lv, collapse = "／")))
}

# 參考樣本以 W 加權的分布（在給定的 collapse 版本與類別上）
ref_dist <- function(v, spec, levels) {
  x  <- apply_collapse(ref_raw[[v]], spec)
  ok <- !is.na(x) & x %in% levels
  s  <- tapply(ref_W[ok], factor(x[ok], levels = levels), sum)
  s[is.na(s)] <- 0
  as.numeric(s) / sum(s)
}
# 把 build_var() 的目標換成加權目標；REF$target = "files" 或聯合表沒有該變數時不動
use_ref_target <- function(b, v, spec) {
  if (!identical(REF$target, "weighted") || !v %in% ref_vars) return(b)
  p <- ref_dist(v, spec, b$levels)
  b$target$prop <- p
  b$target$N    <- p * sum(ref_W)
  b
}
target_label <- function(v) {
  if (identical(REF$target, "weighted") && v %in% ref_vars)
    sprintf("TEDS 參考樣本 W 加權（%s）", joint_name) else TARGET_FILES[[v]]
}

if (identical(REF$target, "weighted")) {
  say("  報表母體 = 參考樣本 W 加權分布；與 TARGET_FILES 邊際的最大差距：")
  for (v in RAKE_VARS) {
    old <- built[[v]]$target$prop
    built[[v]] <- use_ref_target(built[[v]], v, get_spec(v))
    say(sprintf("    %-10s %.2f 個百分點", v, 100 * max(abs(built[[v]]$target$prop - old))))
    zero <- built[[v]]$levels[built[[v]]$target$prop == 0]
    if (length(zero)) say("    ! ", v, " 的加權目標在「", paste(zero, collapse = "／"), "」為 0")
  }
}

# ---------------------------------------------------------------------------
# 6. PAPP-BART
# ---------------------------------------------------------------------------
df <- data.frame(caseid = sam$caseid)
for (v in RAKE_VARS) df[[v]] <- factor(built[[v]]$values, levels = built[[v]]$levels)

complete <- stats::complete.cases(df[, RAKE_VARS, drop = FALSE])
say("")
say("完整個案：", sum(complete), " / ", nrow(df),
    "（因建模變數缺值排除 ", sum(!complete), " 人）")
if (sum(complete) < 30) stop("完整個案太少，無法建模")
dfc <- df[complete, ]
n_B <- nrow(dfc)

# 每個類別一個 0/1 欄（不設參照組）；兩個樣本用同一組類別，欄位一定一致
dummy_matrix <- function(d) {
  do.call(cbind, lapply(RAKE_VARS, function(v) {
    lv <- built[[v]]$levels
    m  <- vapply(lv, function(l) as.numeric(d[[v]] == l), numeric(nrow(d)))
    m  <- matrix(m, nrow = nrow(d), dimnames = list(NULL, paste0(v, "=", lv)))
    m
  }))
}
X_B <- dummy_matrix(dfc)
X_R <- dummy_matrix(ref_x)

key_of <- function(d) do.call(paste, c(lapply(d[RAKE_VARS], as.character), sep = "\r"))

# --- 支撐檢查（論文假設 2、Fig. 5）------------------------------------------
kB <- key_of(dfc); kR <- key_of(ref_x)
say("")
say("---- 支撐檢查（RAKE_VARS 完整交叉）----")
say(sprintf("  NTUWS 佔用 %d 格、TEDS 佔用 %d 格、兩者都有 %d 格",
            length(unique(kB)), length(unique(kR)), length(intersect(kB, kR))))
say(sprintf("  NTUWS 落在 TEDS 沒有的格：%.1f%%（模型 A 靠 BART 平滑外推 π_R）",
            100 * mean(!kB %in% kR)))
say(sprintf("  TEDS（W 加權）落在 NTUWS 沒有的格：%.1f%%（權數無法觸及的母體）",
            100 * sum(ref_W[!kR %in% kB]) / sum(ref_W)))

fit_bart <- function(kind, x.train, y.train, x.test, ntree) {
  args <- list(x.train = x.train, y.train = y.train, ntree = ntree,
               ndpost = BART$ndpost, nskip = BART$nskip, printevery = 100000L)
  if (!is.null(x.test)) args$x.test <- x.test
  if (BART$cores > 1) {
    f <- if (kind == "w") BART::mc.wbart else BART::mc.pbart
    args$mc.cores <- BART$cores; args$seed <- BART$seed
  } else {
    f <- if (kind == "w") BART::wbart else BART::pbart
    set.seed(BART$seed)
  }
  fit <- NULL
  invisible(utils::capture.output(fit <- do.call(f, args)))   # BART 會印很多進度訊息
  fit
}

say("")
say("---- 執行 PAPP-BART ----")
t0 <- Sys.time()

# 模型 A：logit(π_R) ~ X（TEDS 上），預測到 NTUWS
pop_total <- if (!is.na(REF$pop_total)) REF$pop_total else sum(read_target(RAKE_VARS[1])$N)
if (pop_total < 100 * n_R) {
  say(sprintf("  ! 母體總數 %g 不到參考樣本的 100 倍（TARGET_FILES 可能是樣本數），改用 1000 × n_R", pop_total))
  pop_total <- 1000 * n_R
}
pi_R <- 1 / (ref_W * pop_total / sum(ref_W))
y_A  <- stats::qlogis(pi_R)
fitA <- fit_bart("w", X_R, y_A, X_B, BART$ntree_a)
r2_A <- 1 - sum((y_A - fitA$yhat.train.mean)^2) / sum((y_A - mean(y_A))^2)
pi_R_hat <- stats::plogis(fitA$yhat.test.mean)
say(sprintf("模型 A（wbart，ntree = %d）：logit(π_R) 的 pseudo-R² = %.4f；σ 後驗平均 = %.4f",
            BART$ntree_a, r2_A, mean(fitA$sigma[-seq_len(BART$nskip)])))
W_hat_B <- (1 / pi_R_hat) * sum(ref_W) / pop_total   # 換回 TEDS 的 W 尺度
say(sprintf("  NTUWS 預測的 Ŵ = 1/π̂_R（TEDS W 尺度；TEDS 的 W 範圍 %.3f–%.3f）：min=%.3f max=%.3f",
            min(ref_W), max(ref_W), min(W_hat_B), max(W_hat_B)))

# 模型 B：Z ~ X（疊起來、不加權）
X_all <- rbind(X_B, X_R)
Z     <- c(rep(1L, n_B), rep(0L, n_R))
fitB  <- fit_bart("p", X_all, Z, NULL, BART$ntree_b)
e_all <- pmin(pmax(fitB$prob.train.mean, BART$e_clip), 1 - BART$e_clip)
e_B   <- e_all[Z == 1]; e_R <- e_all[Z == 0]
auc <- (sum(rank(e_all)[Z == 1]) - n_B * (n_B + 1) / 2) / (n_B * n_R)
say(sprintf("模型 B（pbart，ntree = %d）：AUC = %.3f（樣本內）；Z = 1 的基準比例 = %.3f",
            BART$ntree_b, auc, n_B / (n_B + n_R)))
say(sprintf("  ê 分位數（NTUWS）：1%%=%.3f 25%%=%.3f 50%%=%.3f 75%%=%.3f 99%%=%.3f",
            quantile(e_B, .01), quantile(e_B, .25), quantile(e_B, .5),
            quantile(e_B, .75), quantile(e_B, .99)))
say(sprintf("  ê 分位數（TEDS） ：1%%=%.3f 25%%=%.3f 50%%=%.3f 75%%=%.3f 99%%=%.3f",
            quantile(e_R, .01), quantile(e_R, .25), quantile(e_R, .5),
            quantile(e_R, .75), quantile(e_R, .99)))
say(sprintf("  NTUWS 的 ê 低於 TEDS 第 1 百分位：%.1f%%；高於 TEDS 第 99 百分位：%.1f%%",
            100 * mean(e_B < quantile(e_R, .01)), 100 * mean(e_B > quantile(e_R, .99))))
say(sprintf("BART 耗時 %.1f 秒", as.numeric(difftime(Sys.time(), t0, units = "secs"))))

# 擬權數：1/π̂_B ∝ (1/π̂_R) · (1 − ê)/ê，正規化到平均 = 1（論文正規化到 ΣW，只差常數倍）
w_raw <- (1 / pi_R_hat) * (1 - e_B) / e_B
w_raw <- w_raw / mean(w_raw)

trim_weights <- function(w, method) {
  if (method == "none") return(list(w = w, K = Inf, n_trim = 0L, it = 0L))
  K <- switch(method,
              iqr     = stats::median(w) + TRIM$c_iqr * stats::IQR(w),
              entropy = sqrt(TRIM$c_entropy * sum(w^2) / length(w)))
  total <- sum(w); capped <- rep(FALSE, length(w)); it <- 0L
  while (any(w > K * (1 + 1e-10)) && it < TRIM$maxit) {
    it <- it + 1L
    capped <- capped | w > K * (1 + 1e-10)
    rest <- total - K * sum(capped)
    if (rest <= 0) stop("trimming 的截斷點太低，超過的總量無法重新分配")
    w[capped]  <- K
    w[!capped] <- w[!capped] * rest / sum(w[!capped])
  }
  list(w = w, K = K, n_trim = sum(capped), it = it)
}

# ---------------------------------------------------------------------------
# 7. 輸出（TRIM$methods 每一種各一組檔案）
# ---------------------------------------------------------------------------
sam$excluded_reason <- NA_character_
for (v in rev(RAKE_VARS))
  sam$excluded_reason[is.na(built[[v]]$values)] <- paste0(v, " 缺值")

# --- 要出圖出表的變數 --------------------------------------------------------
# 除了 RAKE_VARS，只要 TARGET_FILES 有指定、而且這一波真的問得到的變數，
# 都會一併畫出分布（例如沒有拿來建模的省籍），方便檢查加權
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
  built[[v]] <- use_ref_target(b, v, get_spec(v))
  report_vars <- c(report_vars, v)
}
say("出圖／出表的變數：", paste(report_vars, collapse = ", "),
    "（其中 ", paste(RAKE_VARS, collapse = ", "), " 有納入建模）")

# --- 重新編碼後的分析樣本（與 MultiCalibration_NTUWS.R 同格式）--------------
analysis <- data.frame(memberId = sam$memberId, caseid = sam$caseid)
for (v in report_vars) analysis[[v]] <- built[[v]]$values
analysis$complete <- complete

SERIES_COLS <- c("母體" = "#B0413E", "樣本（加權前）" = "#9AA5AD",
                 "樣本（加權後）" = "#3F6C8F")
COLLAPSE_COLS <- c("母體" = "#B0413E", "樣本" = "#9AA5AD")

base_theme <- function() {
  theme_minimal(base_size = 12, base_family = "Heiti TC") +
    theme(legend.position = "top", panel.grid.major.x = element_blank(),
          plot.title = element_text(face = "bold"), plot.subtitle = element_text(size = 9))
}

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

common_log <- log_lines

for (tm in TRIM$methods) {
  log_lines <- common_log
  mtag <- method_tag_of(tm)
  tag  <- paste0(mtag, "_", run_label)
  od   <- file.path(out_dir, mtag)   # 一種 trimming 一個子資料夾，檔名仍帶方法標籤
  dir.create(od, showWarnings = FALSE, recursive = TRUE)
  say("")
  say("==== 輸出：", tag, " ====")

  tr <- trim_weights(w_raw, tm)
  w  <- tr$w / mean(tr$w)
  if (tm != "none")
    say(sprintf("trimming（%s）：截斷點 K = %.3f；截斷 %d 人（%.1f%%），重新分配 %d 輪",
                tm, tr$K, tr$n_trim, 100 * tr$n_trim / length(w), tr$it))
  else
    say("未 trimming")
  say(sprintf("權數：min=%.3f max=%.3f mean=%.3f sd=%.3f", min(w), max(w), mean(w), sd(w)))
  deff <- 1 + (sd(w) / mean(w))^2
  say(sprintf("design effect = %.3f；有效樣本數 = %.0f", deff, length(w) / deff))
  say(sprintf("最大權數佔總和 %.2f%%；權數前 1%% 的人佔總和 %.1f%%",
              100 * max(w) / sum(w), 100 * sum(sort(w, decreasing = TRUE)[seq_len(ceiling(length(w) / 100))]) / sum(w)))

  sam$weight <- NA_real_
  sam$weight[complete] <- w

  wt <- sam[, c("memberId", "caseid", "weight", "excluded_reason")]
  write.csv(wt, file.path(od, sprintf("weights_%s.csv", tag)),
            row.names = FALSE, fileEncoding = "UTF-8")
  write.csv(analysis, file.path(od, sprintf("analysis_%s.csv", tag)),
            row.names = FALSE, fileEncoding = "UTF-8")

  # --- 分布表：母體 / 樣本(加權前) / 樣本(加權後) ----------------------------
  # 欄名沿用 raking_NTUWS.R（pct_raked = 加權後），方便與 raking 結果直接比較
  dist <- lapply(report_vars, function(v) {
    x  <- built[[v]]$values[complete]
    lv <- built[[v]]$levels
    ok <- !is.na(x)                       # 未納入建模的變數可能仍有缺值
    n  <- sapply(lv, function(l) sum(x[ok] == l))
    wn <- sapply(lv, function(l) sum(w[ok][x[ok] == l]))
    data.frame(variable = v, in_raking = v %in% RAKE_VARS,
               collapse_version = ver_name(v), label = lv, n_sample = n,
               pct_sample = round(100 * n / sum(n), 2),
               pct_target = round(100 * built[[v]]$target$prop, 2),
               pct_raked  = round(100 * wn / sum(wn), 2), row.names = NULL)
  }) |> bind_rows()
  write.csv(dist, file.path(od, sprintf("dist_%s.csv", tag)),
            row.names = FALSE, fileEncoding = "UTF-8")

  # PAPP 不強制對齊邊際，差距不為 0 是預期的，本身就是診斷指標（論文 Fig. 6）
  gap_by <- dist |> group_by(variable, in_raking) |>
    summarise(before = max(abs(pct_sample - pct_target)),
              after  = max(abs(pct_raked - pct_target)), .groups = "drop")
  say("加權前→後與母體的最大差距（個百分點）：")
  for (i in seq_len(nrow(gap_by)))
    say(sprintf("  %-10s %6.2f → %5.2f%s", gap_by$variable[i], gap_by$before[i], gap_by$after[i],
                if (gap_by$in_raking[i]) "" else "（未納入建模）"))

  # --- 圖 1：母體 / 加權前 / 加權後 ------------------------------------------
  for (v in report_vars) {
    d <- dist |> filter(variable == v) |>
      select(label, `母體` = pct_target, `樣本（加權前）` = pct_sample,
             `樣本（加權後）` = pct_raked) |>
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
                           if (v %in% RAKE_VARS) "" else "【未納入建模】"),
           subtitle = sprintf("%s；母體來源：%s；完整個案 N = %s", mtag,
                              target_label(v), format(sum(complete), big.mark = ",")),
           x = NULL, y = "百分比", fill = NULL) +
      base_theme()
    ggsave(file.path(od, sprintf("dist_%s_%s.png", tag, v)), p,
           width = max(9, 1 + 0.8 * n_lv), height = 5.5, dpi = 300)
  }

  # --- 圖 2：collapse 前後對比 -----------------------------------------------
  # 上排是母體的原始類別，下排是套用 COLLAPSE 之後的類別，看得出來合併掉了什麼
  for (v in report_vars) {
    spec <- get_spec(v)
    if (!length(spec)) {                          # 沒有合併就不必畫對比
      say("  [collapse 對比] ", v, "：版本 ", ver_name(v), " 未做任何合併，略過")
      next
    }
    before <- tryCatch(build_var(sam, v, list()), error = function(e) NULL)
    if (is.null(before)) next
    before <- use_ref_target(before, v, list())

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
           subtitle = sprintf("上：母體的原始類別；下：套用 COLLAPSE 之後。母體來源：%s", target_label(v)),
           x = NULL, y = "百分比", fill = NULL) +
      base_theme() + theme(strip.text = element_text(face = "bold", size = 10))
    ggsave(file.path(od, sprintf("collapse_%s_%s.png", tag, v)), p,
           width = max(9, 1 + 0.7 * nrow(side_by_side(before))), height = 8, dpi = 300)
  }

  # --- 圖 3：兩樣本 propensity 分布（論文 Fig. 5）與權數分布 ------------------
  ov <- data.frame(sample = factor(c(rep("NTUWS", n_B), rep("TEDS", n_R)),
                                   levels = c("NTUWS", "TEDS")),
                   logit_e = stats::qlogis(e_all))
  p <- ggplot(ov, aes(logit_e, fill = sample, colour = sample)) +
    geom_density(alpha = 0.35, adjust = 1) +
    scale_fill_manual(values = c("NTUWS" = "#3F6C8F", "TEDS" = "#B0413E")) +
    scale_colour_manual(values = c("NTUWS" = "#3F6C8F", "TEDS" = "#B0413E")) +
    labs(title = sprintf("%s：模型 B 的 propensity 分布", run_label),
         subtitle = sprintf("ê = P(屬於 NTUWS | X)，logit 尺度；AUC = %.3f；兩條曲線不重疊處 = 缺乏共同支撐",
                            auc),
         x = "logit(ê)", y = "密度", fill = NULL, colour = NULL) +
    base_theme()
  ggsave(file.path(od, sprintf("overlap_%s.png", tag)), p, width = 8, height = 5.5, dpi = 300)

  wd <- data.frame(w = w)
  p <- ggplot(wd, aes(w)) +
    geom_histogram(bins = 60, fill = "#3F6C8F", alpha = 0.9) +
    { if (is.finite(tr$K)) geom_vline(xintercept = tr$K, colour = "#B0413E", linetype = 2) } +
    scale_x_continuous(trans = "log10") +
    labs(title = sprintf("%s：擬權數分布（%s）", run_label, mtag),
         subtitle = sprintf("對數尺度；deff = %.3f；n_eff = %.0f%s", deff, length(w) / deff,
                            if (is.finite(tr$K)) sprintf("；紅虛線 = 截斷點 K = %.3f", tr$K) else ""),
         x = "權數（平均 = 1）", y = "人數") +
    base_theme() + theme(panel.grid.major.x = element_line())
  ggsave(file.path(od, sprintf("weights_%s.png", tag)), p, width = 8, height = 5.5, dpi = 300)

  diag_path <- file.path(od, sprintf("diagnostics_%s.txt", tag))
  con <- file(diag_path, open = "w", encoding = "UTF-8")
  writeLines(c(sprintf("PAPP_BART_NTUWS.R  診斷報告   %s", format(Sys.time())), "",
               log_lines, "", "---- 設定 ----",
               sprintf("參考樣本：%s；報表母體 = %s；pop_total = %g",
                       REF$file, REF$target, pop_total),
               sprintf("BART：ntree_a = %d；ntree_b = %d；ndpost = %d；nskip = %d；seed = %d；cores = %d；e_clip = %g",
                       BART$ntree_a, BART$ntree_b, BART$ndpost, BART$nskip, BART$seed,
                       BART$cores, BART$e_clip),
               sprintf("trimming：%s（c_iqr = %g；c_entropy = %g；maxit = %d）",
                       tm, TRIM$c_iqr, TRIM$c_entropy, TRIM$maxit),
               sprintf("建模欄位（%d 個 0/1 欄）：%s", ncol(X_B), paste(colnames(X_B), collapse = ", "))),
             con)
  close(con)
}

say("")
say("完成，輸出於：", out_dir)
