#!/usr/bin/env Rscript
# =============================================================================
# clean_lottery_panel.R
#
# 抽獎問卷追蹤資料清理：從原始 xlsx 產出受訪者層級的 demographic 主表，
# 並把無法調和的矛盾單獨列出供人工檢查。
#
# -----------------------------------------------------------------------------
# 執行 —— 工作目錄在哪都可以，程式會從自己的所在位置往上找到 NTUWS/：
#     Rscript data/NTUWS/Code/Phase0_demographic_matching/clean_lottery_panel.R
#
# 只讀 raw_data/ 底下的原始 xlsx，只寫 NTUWS/output/Phase0_demographic_matching/。
# 不會修改任何原始資料，也不會改變呼叫端的工作目錄
#（全程使用絕對路徑，不呼叫 setwd）。
# output/ 整個資料夾都是可拋棄的 —— 刪掉重跑就會回來。
#
# -----------------------------------------------------------------------------
# 輸入（相對於 data/NTUWS/）
#     raw_data/lottery_repeated_raw_by_wave.xlsx        原始資料（18 個 sheet）
#     Supplementary_material/抽獎問卷資料使用說明.pdf    判定標準依據
#                                                       （程式不讀，人工參照）
#
# 輸出（data/NTUWS/output/Phase0_demographic_matching/）
#   —— 檔名一律加 ntuws_ 前綴，與 ABS 那邊的 abs_* 產出區隔
#     ntuws_member_demographics.csv       主表，每人一列
#     ntuws_demographic_conflicts.csv     矛盾清單，每人每欄位一列
#                                         （含該人該欄的完整作答軌跡，
#                                          見下方「矛盾清單怎麼看」）
#     ntuws_wave_participation_long.csv   標準化長表，供矛盾回溯
#
# -----------------------------------------------------------------------------
# 流程
#     STAGE 1  來源檔結構驗證     sheet 名稱、欄索引、題目文字比對
#     STAGE 2  讀取與值標準化     -> 長表
#     STAGE 3  參與軌跡彙整       -> 填答次數、首末波次
#     STAGE 4  矛盾判定           -> 依使用說明 §4 的優先序
#     STAGE 5  主表組裝           -> 不變欄位補值、可變欄位取最新
#     STAGE 6  輸出與摘要
#
# -----------------------------------------------------------------------------
# 要改東西看「SECTION 1 設定」，所有可調參數都集中在那裡：
#     BIRTH_YEAR_TOL    出生年容忍度（目前 ±1 年）
#     WAVE_MONTH        波次的調查月份，決定時間順序
#     SHEET_COLS        各 sheet 的 demographic 欄位位置
#     FIXED_FIELDS      哪些欄位算「不變」（會做矛盾判定）
#     BIRTH_YEAR_RANGE  合理出生年範圍
#
# 值的歸併規則（性別、學歷、籍貫、縣市）在「SECTION 3 值標準化」，
# 每個函式上方都寫了各波原始選項長什麼樣、為什麼這樣歸。
#
# -----------------------------------------------------------------------------
# 矛盾清單怎麼看（ntuws_demographic_conflicts.csv）
#
# 排除規則是「人」層級的 all-or-nothing：任一欄位、任一波次出現矛盾，
# 該 memberId 的所有波次全部不進主表。所以看清單時要能判斷
# 「這人是單次手滑，還是根本反覆不一致」，欄位分兩組：
#
#   判定依據（誰被排除是看這幾欄算出來的）
#     n_distinct_values / conflicting_values / reason / source_sheets
#     source_sheets 只含真正參與判定的作答
#     （不含 Welcome 備援值、不含 father_ethnicity 的「不知道」）
#
#   完整軌跡（純供人工判讀，不影響判定結果）
#     n_answers            該人該欄的全部作答筆數（含 Welcome、含「不知道」）
#     n_answers_counted    其中計入矛盾判定的筆數
#     value_counts         值的次數分布，例：男x4; 女x1
#     dominant_value       次數最多的值
#     n_minority_answers   非最多數值的作答數 —— 主要的篩選欄位
#                            == 1 多半是單次填錯，可考慮救回
#                            >= 2 反覆不一致，救不回來
#     dominant_is_tied     並列最多（例：男x2; 女x2），此時 dominant_value
#                          只是排序結果，不代表多數決答案
#     full_trace           依時序排好的完整作答，例：
#                            Welcome[r5]=男~; LS_2210[r7]=女; LS_2303[r12]=男
#                          結尾的 ~ = 該筆未計入矛盾判定
#                          birth_year 的 Welcome 標為 (基準)
#
# 相依套件：readxl, dplyr, tidyr, stringr, purrr
# =============================================================================


# =============================================================================
# SECTION 1 — 設定
# =============================================================================

# 原始資料檔名。整條 pipeline 靠它定位 NTUWS/，改檔名的話這裡也要改。
RAW_XLSX_NAME <- "lottery_repeated_raw_by_wave.xlsx"

# 這支程式屬於哪一個 phase。輸出資料夾用同一個名字，
# 之後再開 Phase1/Phase2 時只要改這一行，產出就會自動分流到新資料夾。
PHASE <- "Phase0_demographic_matching"

# 定位用的路標：NTUWS/ 底下一定有這個相對路徑
NTUWS_MARKER <- file.path("raw_data", RAW_XLSX_NAME)

# -----------------------------------------------------------------------------
# 自動定位 data/NTUWS/
#
# 目的：不管從哪裡執行都能跑，接手的人不必先搞懂該 setwd 到哪。
# 作法是先問「這支腳本自己放在哪」，再從那裡逐層往上找到含有
# raw_data/lottery_repeated_raw_by_wave.xlsx 的資料夾（也就是 NTUWS/）。
# 腳本位置問不到時（極少數 IDE），退而從目前工作目錄往上找。
#
# 以下用法都可以：
#   cd <專案根目錄> && Rscript data/NTUWS/Code/Phase0_demographic_matching/clean_lottery_panel.R
#   cd data/NTUWS/Code/Phase0_demographic_matching && Rscript clean_lottery_panel.R
#   RStudio 裡 source("data/NTUWS/Code/Phase0_demographic_matching/clean_lottery_panel.R")
#
# 找到 NTUWS/ 之後所有路徑都轉成絕對路徑，
# 因此程式全程不呼叫 setwd()，不會偷改呼叫端的工作目錄。
# -----------------------------------------------------------------------------

# 這支腳本自己的所在資料夾。Rscript 走 --file=，source() 走呼叫堆疊裡的 ofile。
script_dir <- function() {
  a <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
  if (length(a)) {
    # ⚠️ Rscript 會把 --file= 裡的空白換成 "~+~"（本專案路徑含空白，一定會中）
    f <- gsub("~+~", " ", sub("^--file=", "", a[1]), fixed = TRUE)
    if (file.exists(f)) return(dirname(normalizePath(f)))
  }
  for (i in seq_len(sys.nframe())) {
    of <- sys.frame(i)$ofile
    if (!is.null(of) && file.exists(of)) return(dirname(normalizePath(of)))
  }
  NULL
}

# 從 start 逐層往上（最多 levels 層）找出含有 marker 的資料夾
find_up <- function(marker, starts, levels = 6L) {
  for (s in starts) {
    d <- normalizePath(s, mustWork = FALSE)
    for (i in seq_len(levels)) {
      if (file.exists(file.path(d, marker))) return(d)
      parent <- dirname(d)
      if (identical(parent, d)) break
      d <- parent
    }
  }
  NULL
}

find_ntuws_dir <- function() {
  starts <- c(script_dir(), getwd())
  hit <- find_up(NTUWS_MARKER, starts)
  if (is.null(hit)) {
    stop("找不到 data/NTUWS/（判定依據：底下要有 ", NTUWS_MARKER, "）。\n",
         "  目前工作目錄：", getwd(), "\n",
         "  已從這些位置逐層往上找：", paste(starts, collapse = ", "), "\n",
         "  請確認原始 xlsx 放在 data/NTUWS/raw_data/ 底下。",
         call. = FALSE)
  }
  hit
}

NTUWS_DIR <- find_ntuws_dir()

PATHS <- list(
  xlsx   = file.path(NTUWS_DIR, NTUWS_MARKER),
  # 產出依 phase 分流：NTUWS/output/<PHASE>/
  output = file.path(NTUWS_DIR, "output", PHASE)
)

# -----------------------------------------------------------------------------
# 波次與人口母體月份
# 來源：抽獎問卷資料使用說明.pdf §6「波次與母體月份」
#
# ⚠️ 活頁簿的 sheet 排列不等於時間順序。LS_*NY 是「新年波」，
#    實際落在該年 1–2 月，比相鄰的 LS_23xx / LS_24xx / LS_26xx 更早。
#    「取最新一波的值」必須依這裡的月份排序，不能依 sheet 出現順序。
# -----------------------------------------------------------------------------
WAVE_MONTH <- c(
  Welcome   = NA_character_,   # 總名冊，不是調查波次
  LS_2210   = "2022-10",
  LS_2211   = "2022-11",
  LS_23NY   = "2023-02",
  LS_2303   = "2023-03",
  LS_2305   = "2023-05",
  LS_2306   = "2023-06",
  LS_2310   = "2023-10",
  LS_24NY   = "2024-02",
  LS_2405   = "2024-05",
  LS_2408   = "2024-08",
  LS_2410_1 = "2024-10",
  LS_2410_2 = "2024-10",
  LS_25NY   = "2025-01",
  LS_2509   = "2025-08",
  LS_2512   = "2025-12",
  LS_26NY   = "2026-02",
  LS_2604   = "2026-04"
)

# Welcome 排最前（基準），其餘依調查月份；同月份（LS_2410_1/2）沿用宣告順序。
RESPONSE_SHEETS <- setdiff(names(WAVE_MONTH), "Welcome")
WAVE_ORDER <- c(
  "Welcome",
  RESPONSE_SHEETS[order(WAVE_MONTH[RESPONSE_SHEETS], seq_along(RESPONSE_SHEETS))]
)

# -----------------------------------------------------------------------------
# 各 sheet 的 demographic 欄位位置
#
# 數字 = 該 sheet 的欄索引（第 1 欄固定是 memberId）。
# 活頁簿結構：第 1 列 = raw 變項名、第 2 列 = 原始題目文字、第 3 列起 = 資料，
# 因此讀取時 skip = 2，欄索引對應到第 1/2 列的位置。
#
# 空的 c() 表示該波只有政治態度題，完全沒有人口學欄位
# （與使用說明 §6 標註「人口變項用 Welcome」一致）。
# -----------------------------------------------------------------------------
SHEET_COLS <- list(
  Welcome   = c(sex = 2, birth_year_ce = 3, city = 4),
  LS_2210   = c(sex = 2, age = 3),
  LS_2211   = c(sex = 17, age = 18),
  LS_23NY   = c(sex = 2, age = 3, father_ethnicity = 4, education = 5, city = 6),
  LS_2303   = c(sex = 15, age = 16, father_ethnicity = 17, education = 18),
  LS_2305   = c(sex = 16, age = 17),
  LS_2306   = c(sex = 6, age = 7, education = 8, city = 9, father_ethnicity = 10),
  LS_2310   = c(sex = 7, age = 8, father_ethnicity = 9, education = 10, city = 11),
  LS_24NY   = c(birth_year_roc = 2, sex = 3, age = 4, city = 5),
  LS_2405   = c(sex = 20, birth_year_roc = 21, education = 22,
                father_ethnicity = 23, city = 24),
  LS_2408   = c(sex = 20, age = 21, education = 22),
  LS_2410_1 = c(sex = 2, birth_year_roc = 3, city = 4, education = 23,
                father_ethnicity = 24),
  LS_2410_2 = c(sex = 2, birth_year_roc = 3, education = 4,
                father_ethnicity = 5, city = 6),
  LS_25NY   = c(sex = 2, age = 3, city = 4, education = 5),
  LS_2509   = c(),
  # LS_2512 第 22 欄問的是「你的省籍背景」（受訪者本人），其餘七波問的是
  # 「父親的籍貫/省籍」。台灣調查慣例中省籍由父系繼承，兩者視為同一個構念，
  # 因此直接併入 father_ethnicity，不另立欄位。
  LS_2512   = c(sex = 18, city = 19, birth_year_ce = 20, education = 21,
                father_ethnicity = 22),
  LS_26NY   = c(),
  LS_2604   = c()
)

# 驗證用：每個欄位的題目文字必須符合的正則。
# STAGE 1 會拿第 2 列（原始題目文字）逐一比對，來源檔一改動就立刻報錯，
# 避免欄索引悄悄偏移導致抓錯欄位卻毫無察覺。
HEADER_PATTERNS <- c(
  sex              = "性別",
  age              = "年齡",
  birth_year_ce    = "出生年",
  birth_year_roc   = "民國",
  father_ethnicity = "籍貫|省籍|本省客家人",
  education        = "學歷|教育程度",
  city             = "縣市|地區|戶籍地|居住"
)

# -----------------------------------------------------------------------------
# 欄位分類
#
# FIXED   : 理論上一生不變。跨波不一致 => 資料品質問題 => 列入 conflicts 檔。
# VARYING : 本來就會隨時間改變（2022→2026 差 4 年，年齡與學歷當然會變）。
#           不做矛盾判定，一律取最新一波（依 WAVE_MONTH）的值。
# -----------------------------------------------------------------------------
FIXED_FIELDS   <- c("sex", "birth_year", "father_ethnicity")
VARYING_FIELDS <- c("age", "education", "city")

# -----------------------------------------------------------------------------
# 族群分類
#
# father_ethnicity 只允許這六個值。各波原始選項如何對應，見 SECTION 3 的
# norm_ethnicity()；輸出前 SECTION 7 會斷言主表的值必落在這個集合內。
# -----------------------------------------------------------------------------
ETHNICITY_LEVELS <- c("閩南人", "客家人", "外省人", "原住民", "外籍", "不知道")

# 「不知道」是可輸出的正式類別，但**不參與矛盾判定**。
# 理由：「A 波答不知道、B 波答閩南人」是受訪者從不確定變確定，
# 不是互相矛盾的資料錯誤 —— 這種情形應該採用實質答案，而不是把人踢出主表。
# 實測：若讓它參與判定，會多出 210 人被排除，且那 210 人全部都是這種情形。
ETHNICITY_UNKNOWN <- "不知道"

# -----------------------------------------------------------------------------
# 判定參數
# -----------------------------------------------------------------------------

# 出生年容忍度：以 Welcome 為基準，±N 年內視為一致。
# 理由：跨年生日、民國/西元換算邊界、填答手誤，都會造成 ±1 年的差異。
BIRTH_YEAR_TOL <- 1L

# 合理出生年範圍，超出者視為亂填 -> NA
BIRTH_YEAR_RANGE <- c(1900L, 2020L)

# 民國轉西元的位移
ROC_OFFSET <- 1911L

# 推算年齡用的參考年份
CURRENT_YEAR <- as.integer(format(Sys.Date(), "%Y"))


# =============================================================================
# SECTION 2 — 套件與工具
# =============================================================================

# readxl : 讀 .xlsx（不需要 Java / Excel）
# dplyr  : 資料操作
# tidyr  : pivot_longer 寬轉長
# stringr: 字串正規化（性別、學歷、籍貫等文字值統一）
# purrr  : map_dfr 逐 sheet 讀取後併表
REQUIRED_PKGS <- c("readxl", "dplyr", "tidyr", "stringr", "purrr")

missing_pkgs <- setdiff(REQUIRED_PKGS, rownames(installed.packages()))
if (length(missing_pkgs)) {
  stop("缺少套件：", paste(missing_pkgs, collapse = ", "),
       "\n請先執行：install.packages(c(",
       paste0('"', missing_pkgs, '"', collapse = ", "), "))")
}

suppressPackageStartupMessages({
  library(readxl); library(dplyr); library(tidyr)
  library(stringr); library(purrr)
})

# --- 訊息輸出（只印到 console，不留檔）---------------------------------------
say <- function(...) message(paste0(...))

say_stage <- function(n, title) {
  say("\n", strrep("=", 72), "\n  STAGE ", n, " — ", title, "\n", strrep("=", 72))
}

# 帶訊息的斷言：每個階段結束後檢查不變條件，
# 一旦來源資料結構改變就立刻停在出錯的地方，而不是產出錯誤的結果。
assert <- function(condition, msg) {
  if (!isTRUE(all(condition))) stop("斷言失敗：", msg, call. = FALSE)
  invisible(TRUE)
}


# =============================================================================
# SECTION 3 — 值標準化
#
# 17 個波次是不同時間、不同問卷寫成的，同一個概念的作答選項文字各不相同。
# 沒有這一層，「男」和「男性」會被判成矛盾，衝突數會爆炸。
#
# 原則：
#   1. 只做「文字統一」，不做推論。無法確定的一律回 NA。
#   2. 原始值不丟失（呼叫端另存 *_raw 欄位或旗標）。
#   3. 「無法轉為官方分類」的值回 NA —— 依使用說明 §4，這類值不參與
#      矛盾判定，改由 Welcome 補入。
# =============================================================================

# --- 空值統一 ----------------------------------------------------------------
# 各波對「沒填」的表示法不同：空字串、NA 字串、破折號、明文「未填答」。
blank_to_na <- function(x) {
  x <- str_trim(as.character(x))
  x[x %in% c("", "NA", "N/A", "-", "無回答", "未填答")] <- NA_character_
  x
}

# --- 性別 --------------------------------------------------------------------
# 原始值：男 / 男性 / 生理男 / 女 / 女性 / 生理女 / 其他 / 其他-非二元性別 / …
#
# 使用說明 §5 的加權校準維度只有「男女兩類」，因此非二元／其他屬於
# 「回答無法轉為官方分類」，依 §4 回 NA 交由 Welcome 補入。
# 這些值不會被丟掉 —— is_nonbinary_sex() 另外標記，寫入 sex_nonbinary_reported。
norm_sex <- function(x) {
  x <- blank_to_na(x)
  case_when(
    is.na(x)                            ~ NA_character_,
    str_detect(x, "^(男|男性|生理男)$") ~ "男",
    str_detect(x, "^(女|女性|生理女)$") ~ "女",
    TRUE                                ~ NA_character_
  )
}

is_nonbinary_sex <- function(x) {
  x <- blank_to_na(x)
  !is.na(x) & !str_detect(x, "^(男|男性|生理男|女|女性|生理女)$")
}

# --- 教育程度 ----------------------------------------------------------------
# 各波用了三種不同分類系統：
#   LS_2306 / LS_2408 : 大專（專科與大學）        <- 合併
#   LS_2303 / LS_23NY : 大學 / 專科（五專…）      <- 拆開
#   LS_2310 / LS_24xx : 博士 / 碩士 / 大學、科大  <- 更細
#   LS_25NY           : 四技二專 / 五專           <- 又不同
# 統一歸成 5 級，取所有系統的最大公約數。
# case_when 由高到低排序，因為「研究所」必須先於「大學」判斷。
norm_education <- function(x) {
  x <- blank_to_na(x)
  case_when(
    is.na(x)                                           ~ NA_character_,
    str_detect(x, "研究所|碩士|博士")                  ~ "5_研究所以上",
    str_detect(x, "大學|大專|科大|專科|五專|四技二專") ~ "4_大專",
    str_detect(x, "高中|高職")                         ~ "3_高中職",
    str_detect(x, "國中|初中")                         ~ "2_國中",
    str_detect(x, "小學|國小|^無$")                    ~ "1_國小及以下",
    TRUE                                               ~ NA_character_  # 其他/拒答
  )
}

# --- 籍貫 / 省籍 -------------------------------------------------------------
# 目標編碼：閩南人 / 客家人 / 外省人 / 原住民 / 外籍 / 不知道（ETHNICITY_LEVELS）
#
# 八個波次用了四種不同的選項設計，逐一對應如下：
#
#   LS_2303、LS_23NY（五分法，本省籍與客家並列）
#     本省籍               -> 閩南人   ← 客家已獨立成類，故本省籍即閩南
#     客家                 -> 客家人
#     外省籍(大陸各省市)   -> 外省人
#     原住民               -> 原住民
#     外籍                 -> 外籍
#
#   LS_2306（八分法）
#     本省閩南人           -> 閩南人      本省客家人         -> 客家人
#     大陸各省市           -> 外省人      中國籍（含港澳）   -> 外省人
#     原住民               -> 原住民      外籍（不含中港澳） -> 外籍
#     其他                 -> 外籍        不清楚             -> 不知道
#
#   LS_2310、LS_2405、LS_2410_1、LS_2410_2（九分法）
#     本省閩南人           -> 閩南人      本省客家人   -> 客家人
#     大陸各省市(外省人)   -> 外省人      原住民       -> 原住民
#     外國新住民           -> 外籍        大陸新住民   -> 外籍
#     其他，請說明         -> 外籍
#     不知道 / 拒答        -> 不知道
#
#   LS_2512（四分法，問的是受訪者本人的省籍背景）
#     本省閩南人           -> 閩南人      本省客家人   -> 客家人
#     大陸各省市人         -> 外省人
#     其他（原住民、新住民等） -> NA      ← 見下方說明
#
# case_when 由上而下短路，順序不可任意調換，關鍵三處：
#
#   1. 「其他（原住民、新住民等）」必須最先攔截。它是 LS_2512 把原住民與
#      新住民混在一起的籠統殘差類別，語意上無法歸入任何單一類別，因此視為
#      缺值。字串內含「原住民」三字，不先攔下會被原住民分支吃掉而錯標。
#      （「其他，請說明」不會誤中，因為它後面接的是逗號不是括號。）
#
#   2. 「原住民」必須早於「其他 -> 外籍」，否則會被 ^其他 之外的分支影響；
#      同時「原住民」與「新住民」是不同字，不會互相誤中。
#
#   3. 「外籍」相關分支必須早於「大陸|外省」。因為「大陸新住民」同時含有
#      「大陸」與「新住民」，依規格應歸外籍而非外省人。
#      反過來「外省籍（大陸各省市）」不含子字串「外籍」（是外-省-籍），
#      所以不會被誤判成外籍。
norm_ethnicity <- function(x) {
  x <- blank_to_na(x)
  case_when(
    is.na(x)                                ~ NA_character_,
    str_detect(x, "^其他[（(]")             ~ NA_character_,   # 見說明 1
    str_detect(x, "不知道|不清楚|拒答")     ~ "不知道",
    str_detect(x, "客家")                   ~ "客家人",
    str_detect(x, "閩南|^本省籍$")          ~ "閩南人",
    str_detect(x, "原住民")                 ~ "原住民",         # 見說明 2
    str_detect(x, "新住民|外籍|外國|^其他") ~ "外籍",           # 見說明 3
    str_detect(x, "大陸|外省|中國籍|港澳")  ~ "外省人",
    TRUE                                    ~ NA_character_
  )
}

# --- 縣市 --------------------------------------------------------------------
# 台/臺 兩種寫法混用（Welcome 用「臺北市」，LS_2306 用「台北市」）。
# 括號註記（連江縣(馬祖)）也要去掉才能對得起來。
norm_city <- function(x) {
  x <- blank_to_na(x)
  x <- str_replace_all(x, "臺", "台")
  x <- str_remove(x, "\\(.*\\)|（.*）")
  str_trim(x)
}

# --- 年齡 --------------------------------------------------------------------
# 原始值有兩種型態並存：級距（"20～24"）與整數（"41"）。
# 不強轉數值 —— 級距無法轉，硬轉會製造假資料。只統一全形波浪號。
# 需要數值年齡時請用 age_from_birth_year（由 birth_year 推算）。
norm_age <- function(x) {
  x <- blank_to_na(x)
  str_replace_all(x, "～", "-")
}

# --- 出生年 ------------------------------------------------------------------
# 兩種紀元並存：西元（Welcome、LS_2512）與民國（LS_2405/2410_*/24NY）。
# 統一轉成西元。超出合理範圍者視為亂填 -> NA。
# 兩個參數不會同時有值（同一個 sheet 只會問其中一種紀元）。
to_birth_year <- function(ce, roc) {
  ce  <- suppressWarnings(as.integer(str_extract(blank_to_na(ce),  "\\d{4}")))
  roc <- suppressWarnings(as.integer(str_extract(blank_to_na(roc), "\\d{1,3}")))
  y <- coalesce(ce, roc + ROC_OFFSET)
  y[!is.na(y) & (y < BIRTH_YEAR_RANGE[1] | y > BIRTH_YEAR_RANGE[2])] <- NA_integer_
  y
}


# =============================================================================
# SECTION 4 — 讀取與結構驗證
# =============================================================================

# --- 結構驗證 ----------------------------------------------------------------
# 在讀資料之前先確認來源檔的結構符合 SHEET_COLS 的假設。檢查三件事：
#   1. 活頁簿的 sheet 名稱與設定完全一致（沒有新增/改名/刪除）
#   2. 每個宣告的欄索引沒有超出該 sheet 的欄數
#   3. 每個欄位的題目文字符合 HEADER_PATTERNS
#      -> 這是最重要的一項。若供應方在中間插入一欄，索引會整排偏移，
#         沒有這道檢查就會安靜地抓錯欄位並產出看似正常的錯誤結果。
validate_workbook <- function(xlsx = PATHS$xlsx) {
  assert(file.exists(xlsx), paste0("找不到來源檔：", xlsx))

  actual <- excel_sheets(xlsx)
  assert(setequal(actual, names(SHEET_COLS)),
         paste0("活頁簿 sheet 與設定不符。\n  多出：",
                paste(setdiff(actual, names(SHEET_COLS)), collapse = ", "),
                "\n  缺少：",
                paste(setdiff(names(SHEET_COLS), actual), collapse = ", ")))
  say("  sheet 名稱檢查通過（", length(actual), " 個）")

  problems <- character()
  for (sheet in names(SHEET_COLS)) {
    cols <- SHEET_COLS[[sheet]]
    if (!length(cols)) next

    # 只讀前兩列（變項名 + 題目文字），成本極低
    hdr <- suppressMessages(
      read_excel(xlsx, sheet = sheet, col_names = FALSE, n_max = 2)
    )
    q_text <- as.character(unlist(hdr[2, ]))

    for (field in names(cols)) {
      idx <- cols[[field]]
      if (idx > ncol(hdr)) {
        problems <- c(problems, sprintf("%s$%s: 欄索引 %d 超出範圍（共 %d 欄）",
                                        sheet, field, idx, ncol(hdr)))
        next
      }
      pat <- HEADER_PATTERNS[[field]]
      if (!is.na(q_text[idx]) && !str_detect(q_text[idx], pat)) {
        problems <- c(problems,
                      sprintf("%s$%s [欄%d]: 題目文字「%s」不符合預期樣式 /%s/",
                              sheet, field, idx, str_sub(q_text[idx], 1, 30), pat))
      }
    }
  }

  if (length(problems)) {
    stop("欄位對照驗證失敗，共 ", length(problems), " 項：\n  ",
         paste(problems, collapse = "\n  "),
         "\n\n來源檔結構可能已變動，請更新 SECTION 1 的 SHEET_COLS。",
         call. = FALSE)
  }
  say("  欄位對照檢查通過（", sum(lengths(SHEET_COLS)), " 個 demographic 欄位）")
  invisible(TRUE)
}

# --- 單一 sheet 讀取 ---------------------------------------------------------
# 全部欄位以 col_types = "text" 讀入，理由：
#   - memberId 是 16 位十六進位字串，讓 readxl 自動判型會被轉成科學記號
#   - 郵遞區號「062」的前導零會被吃掉
#   - 年齡欄同時有級距與整數，自動判型會產生一半 NA
# 型別轉換一律在 SECTION 3 明確進行。
read_wave_sheet <- function(sheet, xlsx = PATHS$xlsx) {
  raw <- suppressMessages(
    read_excel(xlsx, sheet = sheet, col_names = FALSE, skip = 2, col_types = "text")
  )
  cols <- SHEET_COLS[[sheet]]

  # 取某個 demographic 欄；該 sheet 沒問這一題就回整欄 NA，
  # 這樣所有 sheet 都能組成同樣寬度的表。
  grab <- function(field) {
    if (!field %in% names(cols)) return(rep(NA_character_, nrow(raw)))
    raw[[cols[[field]]]]
  }

  out <- tibble(
    sheet        = sheet,
    row_in_sheet = seq_len(nrow(raw)),   # 保留原始列號，供矛盾追溯回原檔
    memberId     = blank_to_na(raw[[1]]),

    # --- 不變欄位（會做矛盾判定）---
    sex              = norm_sex(grab("sex")),
    sex_nonbinary    = is_nonbinary_sex(grab("sex")),
    birth_year       = to_birth_year(grab("birth_year_ce"), grab("birth_year_roc")),
    father_ethnicity = norm_ethnicity(grab("father_ethnicity")),

    # --- 可變欄位（取最新一波）---
    age           = norm_age(grab("age")),
    education     = norm_education(grab("education")),
    education_raw = blank_to_na(grab("education")),   # 保留原始文字供查核
    city          = norm_city(grab("city"))
  )

  n_dropped <- sum(is.na(out$memberId))
  if (n_dropped > 0) say("  [警告] ", sheet, "：", n_dropped, " 列無 memberId，已捨棄")

  out %>% filter(!is.na(memberId))
}

# --- 全部 sheet ---------------------------------------------------------------
# sheet 轉成 factor 且 levels = WAVE_ORDER（依使用說明 §6 的調查月份排序）。
# 後續「最新一波」的判斷完全依賴這個 factor 的 level 順序。
extract_all <- function(xlsx = PATHS$xlsx) {
  long <- map_dfr(WAVE_ORDER, read_wave_sheet, xlsx = xlsx) %>%
    mutate(sheet = factor(sheet, levels = WAVE_ORDER))

  # 不變條件：所有波次的 memberId 都必須在 Welcome 名冊裡
  roster <- long$memberId[long$sheet == "Welcome"]
  orphan <- setdiff(long$memberId[long$sheet != "Welcome"], roster)
  if (length(orphan)) {
    say("  [警告] 有 ", length(orphan), " 個 memberId 不在 Welcome 名冊中")
  } else {
    say("  名冊完整性檢查通過：所有波次 ID 皆在 Welcome 中")
  }

  assert(!anyNA(long$memberId), "memberId 不應有 NA")
  say("  讀入 ", format(nrow(long), big.mark = ","), " 列，",
      format(n_distinct(long$memberId), big.mark = ","), " 個 unique memberId")

  long
}


# =============================================================================
# SECTION 5 — 參與軌跡
# =============================================================================

# Welcome 是總名冊不是調查波次，不計入次數
# （使用說明 §2 明載「不是獨立調查波次」）。
#
# n_waves  依需求採「實際列數」：同一波重複填答算多次。
# n_sheets 另存不重複波次數，兩者不同即代表有同波重複填答。
build_participation <- function(long) {
  p <- long %>%
    filter(sheet %in% RESPONSE_SHEETS) %>%
    arrange(memberId, sheet, row_in_sheet) %>%
    group_by(memberId) %>%
    summarise(
      n_waves    = n(),
      n_sheets   = n_distinct(as.character(sheet)),
      waves      = paste(as.character(sheet), collapse = ";"),
      first_wave = as.character(first(sheet)),
      last_wave  = as.character(last(sheet)),
      .groups    = "drop"
    ) %>%
    mutate(first_month = unname(WAVE_MONTH[first_wave]),
           last_month  = unname(WAVE_MONTH[last_wave]))

  say("  ", format(nrow(p), big.mark = ","), " 人有填答紀錄；",
      "同波重複填答 ", sum(p$n_waves - p$n_sheets), " 筆")
  p
}


# =============================================================================
# SECTION 6 — 矛盾判定
#
# 判定標準來源：抽獎問卷資料使用說明.pdf §4「樣本保留與排除」
#
#   「各波先排除不完整調查。加權時再檢查性別、年齡與地區：
#     若該波有詢問，優先使用該波回答；沒有詢問或回答無法轉為官方分類時，
#     才以 Welcome 補入。若兩處皆無法取得，該筆不進入最終資料。」
#
# 這段話定義的是「優先序」，不是「一致性檢查」。關鍵推論：
#
#   Welcome 是備援基準，不是與各波平起平坐的第 18 個資料來源。
#   => 波次答案與 Welcome 不同，不算矛盾（該波本來就以自己的答案為準）
#   => 只有「波次 vs 波次」互相矛盾，才是真正無法解決的資料品質問題
#
# 例外：birth_year 以 Welcome 為標準值，容忍 ±BIRTH_YEAR_TOL 年。
# =============================================================================

# --- Welcome 基準表 ----------------------------------------------------------
# 每個 memberId 在 Welcome 只有一列，但仍用 first(非NA) 防禦性取值。
build_welcome_reference <- function(long) {
  ref <- long %>%
    filter(sheet == "Welcome") %>%
    group_by(memberId) %>%
    summarise(across(all_of(FIXED_FIELDS), ~ first(.x[!is.na(.x)])),
              .groups = "drop") %>%
    rename_with(~ paste0("welcome_", .x), all_of(FIXED_FIELDS))

  say("  Welcome 基準表：", format(nrow(ref), big.mark = ","), " 人",
      "（性別 ", sum(!is.na(ref$welcome_sex)),
      " / 出生年 ", sum(!is.na(ref$welcome_birth_year)), " 有值）")
  ref
}

# --- 波次層級的不變欄位（長格式）---------------------------------------------
# 排除 Welcome，只留下真正的調查作答。
#
# 兩種值不參與矛盾判定：
#   NA                  「沒作答」不是「答錯」
#   father_ethnicity 的
#   「不知道」           受訪者從不確定變確定，不是資料互相矛盾。
#                        它仍是可輸出的正式類別（見 SECTION 7 的解析邏輯），
#                        只是不拿來判定誰該被排除。
build_wave_fixed <- function(long) {
  long %>%
    filter(sheet != "Welcome") %>%
    mutate(birth_year = as.character(birth_year)) %>%  # pivot 需要同型別
    select(memberId, sheet, row_in_sheet, all_of(FIXED_FIELDS)) %>%
    pivot_longer(all_of(FIXED_FIELDS), names_to = "field", values_to = "value") %>%
    filter(!is.na(value)) %>%
    filter(!(field == "father_ethnicity" & value == ETHNICITY_UNKNOWN))
}

# --- 完整作答軌跡（只供人工判讀，不影響判定）--------------------------------
# build_wave_fixed() 是「判定依據」，刻意丟掉 Welcome 與「不知道」；
# 但人在看矛盾清單時要的是「這個人這一欄到底填過哪些東西」的全貌，
# 才分得出「填過 5 次只錯 1 次」和「男女各半、根本無從判斷」。
#
# 所以這裡另外做一份完整軌跡：保留每一筆非 NA 的作答，
# 包含 Welcome 的備援值與 father_ethnicity 的「不知道」，
# 未計入判定者以 TRACE_MARK_UNCOUNTED 標記、birth_year 的 Welcome 標為 (基準)。
#
# 判定用的 wave_fixed 一個字都沒改 —— conflict_ids 與主表人數完全不變。
TRACE_MARK_UNCOUNTED <- "~"

build_full_trace <- function(long) {
  long %>%
    mutate(birth_year = as.character(birth_year)) %>%
    select(memberId, sheet, row_in_sheet, all_of(FIXED_FIELDS)) %>%
    pivot_longer(all_of(FIXED_FIELDS), names_to = "field", values_to = "value") %>%
    filter(!is.na(value)) %>%
    mutate(
      # 與 build_wave_fixed() 的兩道 filter 一一對應
      counted = sheet != "Welcome" &
                !(field == "father_ethnicity" & value == ETHNICITY_UNKNOWN),
      mark    = case_when(
        field == "birth_year" & sheet == "Welcome" ~ "(基準)",
        !counted                                   ~ TRACE_MARK_UNCOUNTED,
        TRUE                                       ~ ""
      )
    )
}

# 每人每欄一列：值的次數分布 + 依時序排好的完整軌跡。
#
# n_minority_answers 是給人下篩選條件用的：
#   == 1  多半是單次填錯（例：男×4、女×1）      -> 可考慮救回
#   >= 2  反覆不一致，救不回來                    -> 該排除
summarise_full_trace <- function(full_trace) {
  counts <- full_trace %>%
    count(memberId, field, value, name = "n_value") %>%
    arrange(memberId, field, desc(n_value), value) %>%
    group_by(memberId, field) %>%
    summarise(
      n_answers          = sum(n_value),
      n_distinct_answers = n(),
      value_counts       = paste0(value, "x", n_value, collapse = "; "),
      dominant_value     = value[1],
      n_dominant_answers = n_value[1],
      n_minority_answers = sum(n_value) - n_value[1],
      # 並列最多時 dominant 只是排序結果，標出來免得被誤讀成「多數決答案」
      dominant_is_tied   = sum(n_value == n_value[1]) > 1,
      .groups = "drop"
    )

  traces <- full_trace %>%
    arrange(memberId, field, sheet, row_in_sheet) %>%
    group_by(memberId, field) %>%
    summarise(
      n_answers_counted = sum(counted),
      full_trace = paste(sprintf("%s[r%d]=%s%s", sheet, row_in_sheet, value, mark),
                         collapse = "; "),
      .groups = "drop"
    )

  left_join(counts, traces, by = c("memberId", "field"))
}

# --- 出生年：與 Welcome 基準比對，容忍 ±BIRTH_YEAR_TOL -----------------------
# 為什麼要容忍：
#   跨年生日、民國/西元換算的邊界、填答手誤，都會造成 ±1 年的差異，
#   這些不是資料錯誤。實際檢查也顯示偏差分布是連續散落的，
#   沒有 ±11 / ±1911 這種系統性換算錯誤的尖峰。
#
# 基準取捨：
#   優先用 Welcome（覆蓋率 100%）。萬一 Welcome 缺值，
#   退回該人所有波次值的中位數（比平均數耐離群值）。
detect_birth_year_conflicts <- function(wave_fixed, welcome_ref) {
  checked <- wave_fixed %>%
    filter(field == "birth_year") %>%
    left_join(select(welcome_ref, memberId, welcome_birth_year), by = "memberId") %>%
    mutate(wave_y = as.integer(value),
           ref_y  = as.integer(welcome_birth_year)) %>%
    group_by(memberId) %>%
    mutate(
      ref_y      = if (all(is.na(ref_y))) as.integer(round(median(wave_y))) else ref_y,
      is_deviant = !is.na(ref_y) & abs(wave_y - ref_y) > BIRTH_YEAR_TOL
    ) %>%
    ungroup()

  conflicts <- checked %>%
    group_by(memberId) %>%
    filter(any(is_deviant)) %>%
    arrange(sheet, row_in_sheet, .by_group = TRUE) %>%
    summarise(
      field              = "birth_year",
      n_distinct_values  = n_distinct(c(wave_y, ref_y[1])),
      conflicting_values = paste(sort(unique(c(ref_y[1], wave_y))), collapse = " | "),
      reason             = sprintf("波次值與 Welcome 基準 %d 相差超過 ±%d 年",
                                   ref_y[1], BIRTH_YEAR_TOL),
      # * 標記超出容忍範圍的那幾筆，方便直接回原檔查
      source_sheets      = paste0(
        "Welcome=", ref_y[1], " (基準); ",
        paste(sprintf("%s[r%d]=%d%s", sheet, row_in_sheet, wave_y,
                      ifelse(is_deviant, "*", "")), collapse = "; ")
      ),
      .groups = "drop"
    )

  say("  birth_year：", nrow(conflicts), " 人超出 ±", BIRTH_YEAR_TOL, " 年容忍度")
  conflicts
}

# --- 類別欄位：波次 vs 波次 --------------------------------------------------
# sex / father_ethnicity。
# 同一 sheet 內同一 memberId 的重複列若互相矛盾，一樣算矛盾
# （source_sheets 的列號可看出是同波重複填答還是跨波不一致）。
detect_categorical_conflicts <- function(wave_fixed) {
  conflicts <- wave_fixed %>%
    filter(field != "birth_year") %>%
    group_by(memberId, field) %>%
    filter(n_distinct(value) > 1) %>%
    arrange(sheet, row_in_sheet, .by_group = TRUE) %>%
    summarise(
      n_distinct_values  = n_distinct(value),
      conflicting_values = paste(sort(unique(value)), collapse = " | "),
      reason             = "不同波次給出互相矛盾的答案",
      source_sheets      = paste(sprintf("%s[r%d]=%s", sheet, row_in_sheet, value),
                                 collapse = "; "),
      .groups = "drop"
    )

  for (f in unique(conflicts$field)) {
    say("  ", f, "：", sum(conflicts$field == f), " 人波次間互相矛盾")
  }
  conflicts
}

# --- 匯總 --------------------------------------------------------------------
adjudicate <- function(long, participation) {
  welcome_ref <- build_welcome_reference(long)
  wave_fixed  <- build_wave_fixed(long)
  trace_summary <- summarise_full_trace(build_full_trace(long))

  conflicts <- bind_rows(
    detect_birth_year_conflicts(wave_fixed, welcome_ref),
    detect_categorical_conflicts(wave_fixed)
  ) %>%
    # 判定完才接上完整軌跡：只影響看得到什麼，不影響誰被排除
    left_join(trace_summary, by = c("memberId", "field")) %>%
    left_join(participation, by = "memberId") %>%
    select(memberId, n_waves, n_sheets, first_wave, last_wave, waves,
           field, n_distinct_values, conflicting_values, reason, source_sheets,
           n_answers, n_answers_counted, n_distinct_answers,
           dominant_value, n_dominant_answers, n_minority_answers,
           dominant_is_tied, value_counts, full_trace) %>%
    arrange(memberId, field)

  say("  合計 ", format(n_distinct(conflicts$memberId), big.mark = ","),
      " 人 / ", format(nrow(conflicts), big.mark = ","), " 筆欄位矛盾")
  say("  其中僅 1 筆少數答案（疑似單次填錯）：",
      format(sum(conflicts$n_minority_answers == 1 & !conflicts$dominant_is_tied),
             big.mark = ","), " 筆欄位矛盾")

  # 完整軌跡必須真的比判定依據多（或至少一樣多），少了就是接錯表
  assert(all(conflicts$n_answers >= conflicts$n_answers_counted),
         "完整軌跡的作答數不應少於計入判定的筆數")
  assert(!anyNA(conflicts$n_answers), "有矛盾欄位接不到完整軌跡")

  list(conflicts    = conflicts,
       conflict_ids = unique(conflicts$memberId),
       welcome_ref  = welcome_ref)
}


# =============================================================================
# SECTION 7 — 主表組裝
#
# 每個 memberId 一列。兩類欄位用兩套不同邏輯：
#   不變欄位 : 波次答案優先，沒有才用 Welcome 補（使用說明 §4 優先序）
#              birth_year 例外，一律以 Welcome 為準
#   可變欄位 : 取最新一波（依 §6 的調查月份）有值者
# =============================================================================

# 取第一個非 NA。搭配已排序的資料使用，等同「最優先的有效值」。
first_non_na <- function(x) {
  x <- x[!is.na(x)]
  if (length(x)) x[1] else NA
}

# --- 不變欄位 ----------------------------------------------------------------
# 走到這裡的都是無矛盾者，所以「波次值」至多一個相異值，first_non_na 即可。
resolve_fixed <- function(keep, welcome_ref) {
  # father_ethnicity 的取值順序：實質答案 > 「不知道」。
  # 把「不知道」排到最後，first_non_na 自然會優先挑到實質答案；
  # 只有全部波次都答不知道時，才輸出「不知道」。
  wave_side <- keep %>%
    filter(sheet != "Welcome") %>%
    arrange(memberId, father_ethnicity == ETHNICITY_UNKNOWN) %>%
    group_by(memberId) %>%
    summarise(across(all_of(c("sex", "father_ethnicity")), first_non_na),
              .groups = "drop") %>%
    rename_with(~ paste0("wave_", .x), -memberId)

  # birth_year 的備援：Welcome 缺值時取波次中位數
  by_fallback <- keep %>%
    filter(sheet != "Welcome", !is.na(birth_year)) %>%
    group_by(memberId) %>%
    summarise(by_wave = as.integer(round(median(birth_year))), .groups = "drop")

  keep %>%
    distinct(memberId) %>%
    left_join(wave_side,   by = "memberId") %>%
    left_join(welcome_ref, by = "memberId") %>%
    left_join(by_fallback, by = "memberId") %>%
    transmute(
      memberId,
      # coalesce = 使用說明 §4 的優先序：波次優先，Welcome 補入
      sex              = coalesce(wave_sex, welcome_sex),
      father_ethnicity = coalesce(wave_father_ethnicity, welcome_father_ethnicity),
      # birth_year 反過來：Welcome 是標準，波次只當備援
      birth_year       = coalesce(as.integer(welcome_birth_year), by_wave),
      # 記錄性別實際採用哪一個來源，方便事後稽核
      sex_source       = case_when(!is.na(wave_sex)    ~ "wave",
                                   !is.na(welcome_sex) ~ "welcome",
                                   TRUE                ~ NA_character_)
    )
}

# --- 可變欄位 ----------------------------------------------------------------
# 依 sheet factor 的 level 倒序（= 調查月份由新到舊），取第一個非 NA。
# sheet 的 levels 在 SECTION 4 設定為 WAVE_ORDER，這裡完全依賴那個順序。
resolve_varying <- function(keep) {
  keep %>%
    arrange(memberId, desc(sheet), desc(row_in_sheet)) %>%
    group_by(memberId) %>%
    summarise(across(all_of(c("age", "education", "education_raw",
                              "city")), first_non_na),
              .groups = "drop")
}

# --- 組裝 --------------------------------------------------------------------
build_demographics <- function(long, participation, conflict_ids, welcome_ref) {
  keep <- long %>% filter(!memberId %in% conflict_ids)

  # 非二元性別的紀錄不因未進官方分類而遺失
  nonbinary <- long %>%
    group_by(memberId) %>%
    summarise(sex_nonbinary_reported = any(sex_nonbinary, na.rm = TRUE),
              .groups = "drop")

  out <- participation %>%
    filter(!memberId %in% conflict_ids) %>%
    left_join(resolve_fixed(keep, welcome_ref), by = "memberId") %>%
    left_join(resolve_varying(keep),            by = "memberId") %>%
    left_join(nonbinary,                        by = "memberId") %>%
    mutate(
      age_from_birth_year = ifelse(is.na(birth_year), NA_integer_,
                                   CURRENT_YEAR - birth_year),
      # 8 個 demographic 欄位的填答完整度，方便下游自行設門檻
      n_demo_fields = rowSums(!is.na(pick(sex, birth_year, father_ethnicity,
                                          age, education, city)))
    ) %>%
    select(memberId, n_waves, n_sheets,
           first_wave, first_month, last_wave, last_month, waves,
           sex, sex_source, sex_nonbinary_reported,
           age, birth_year, age_from_birth_year,
           father_ethnicity, education, education_raw, city,
           n_demo_fields) %>%
    arrange(desc(n_waves), memberId)

  # --- 輸出前的不變條件檢查 ---
  assert(!any(duplicated(out$memberId)), "主表出現重複 memberId")
  assert(!any(out$memberId %in% conflict_ids), "矛盾者不應出現在主表")
  assert(all(out$n_waves >= out$n_sheets), "n_waves 不應小於 n_sheets")
  assert(all(is.na(out$sex) | out$sex %in% c("男", "女")),
         "sex 只應為 男/女/NA（使用說明 §5 官方分類）")
  assert(all(is.na(out$birth_year) |
             (out$birth_year >= BIRTH_YEAR_RANGE[1] &
              out$birth_year <= BIRTH_YEAR_RANGE[2])),
         "birth_year 超出合理範圍")
  assert(all(is.na(out$father_ethnicity) |
             out$father_ethnicity %in% ETHNICITY_LEVELS),
         paste0("father_ethnicity 只應為 ",
                paste(ETHNICITY_LEVELS, collapse = "/"), "/NA"))

  say("  主表 ", format(nrow(out), big.mark = ","), " 人，",
      ncol(out), " 個欄位；輸出前檢查全數通過")
  out
}


# =============================================================================
# SECTION 8 — 輸出與摘要
#
# 全部以 UTF-8 寫出、NA 寫成空字串（Excel 開啟時顯示為空白而非字面 "NA"）。
# =============================================================================

# 在 C / POSIX locale 下，write.csv(fileEncoding = "UTF-8") 會從「native」
# 編碼轉出，中文全部被吃掉 —— 而且只丟一堆 warning，不會報錯，
# 產出的 CSV 看起來正常但性別、籍貫、reason 全空。
# 先擋下來，免得帶著壞掉的輸出往下做。
assert_utf8_locale <- function() {
  ctype <- Sys.getlocale("LC_CTYPE")
  ok <- isTRUE(l10n_info()[["UTF-8"]]) ||
        grepl("UTF-8|utf8", ctype, ignore.case = TRUE)
  if (!isTRUE(ok)) {
    stop("目前的 locale 是 ", ctype, "，不是 UTF-8，中文會在寫檔時被清掉。\n",
         "  請改用：LC_ALL=zh_TW.UTF-8 Rscript <此檔>\n",
         "  （或 en_US.UTF-8 亦可，只要是 UTF-8）", call. = FALSE)
  }
  invisible(TRUE)
}

write_csv_utf8 <- function(df, name) {
  path <- file.path(PATHS$output, name)
  write.csv(df, path, row.names = FALSE, fileEncoding = "UTF-8", na = "")
  say("  -> ", path, "  (", format(nrow(df), big.mark = ","), " 列 × ",
      ncol(df), " 欄)")
}

# 每次跑完印出關鍵數字。這些數字若與前次差異過大，
# 通常代表來源檔或參數有變動，值得停下來確認。
print_summary <- function(long, demographics, conflicts) {
  total <- n_distinct(long$memberId)
  n_cf  <- n_distinct(conflicts$memberId)

  say("\n", strrep("-", 72), "\n執行摘要\n", strrep("-", 72))
  say(sprintf("  總 memberId   : %s", format(total, big.mark = ",")))
  say(sprintf("  進入主表      : %s (%.1f%%)",
              format(nrow(demographics), big.mark = ","),
              100 * nrow(demographics) / total))
  say(sprintf("  因矛盾排除    : %s (%.1f%%)",
              format(n_cf, big.mark = ","), 100 * n_cf / total))

  say("\n  各欄位矛盾人數：")
  cf <- count(conflicts, field, name = "n")
  for (i in seq_len(nrow(cf))) say(sprintf("    %-18s %5d", cf$field[i], cf$n[i]))

  say("\n  性別採用來源（使用說明 §4 優先序）：")
  ss <- table(demographics$sex_source, useNA = "ifany")
  for (k in names(ss)) say(sprintf("    %-18s %5d", k, ss[[k]]))

  say("\n  主表欄位覆蓋率：")
  demo_cols <- c("sex", "age", "birth_year",
                 "father_ethnicity", "education", "city")
  cov <- round(colMeans(!is.na(demographics[, demo_cols])) * 100, 1)
  for (k in names(cov)) say(sprintf("    %-18s %5.1f%%", k, cov[[k]]))

  say("\n  father_ethnicity 分布：")
  fe <- table(demographics$father_ethnicity, useNA = "no")
  fe <- fe[order(match(names(fe), ETHNICITY_LEVELS))]
  for (k in names(fe)) {
    say(sprintf("    %-18s %5d  (%.1f%%)", k, fe[[k]],
                100 * fe[[k]] / sum(!is.na(demographics$father_ethnicity))))
  }
  say(sprintf("    %-18s %5d", "有值合計",
              sum(!is.na(demographics$father_ethnicity))))

  say("\n  填答次數分布（n_waves）：")
  tb <- table(demographics$n_waves)
  say("    ", paste(sprintf("%s:%d", names(tb), as.integer(tb)), collapse = "  "))
  say(strrep("-", 72))
}


# =============================================================================
# SECTION 9 — 執行
# =============================================================================

t_start <- Sys.time()

dir.create(PATHS$output, showWarnings = FALSE, recursive = TRUE)

say("\n抽獎問卷追蹤資料清理")
say("  R ", getRversion(), " on ", R.version$platform)
say("  工作目錄 ", getwd())
say("  NTUWS    ", NTUWS_DIR, "（自動偵測）")
say("  輸出     ", PATHS$output)
say("  來源     ", RAW_XLSX_NAME,
    " (", round(file.size(PATHS$xlsx) / 1024^2, 1), " MB)")
say("  ", length(RESPONSE_SHEETS), " 波 + Welcome 名冊；出生年容忍度 ±",
    BIRTH_YEAR_TOL, " 年")

say_stage(1, "來源檔結構驗證")
assert_utf8_locale()
validate_workbook()

say_stage(2, "讀取與值標準化")
long <- extract_all()

say_stage(3, "參與軌跡彙整")
participation <- build_participation(long)

say_stage(4, "矛盾判定（使用說明 §4）")
adj <- adjudicate(long, participation)

say_stage(5, "主表組裝")
demographics <- build_demographics(long, participation,
                                   adj$conflict_ids, adj$welcome_ref)

say_stage(6, "輸出")
write_csv_utf8(demographics,  "ntuws_member_demographics.csv")
write_csv_utf8(adj$conflicts, "ntuws_demographic_conflicts.csv")
# 長表：標準化後的每一筆作答，矛盾需要回溯時用這張
write_csv_utf8(long %>% mutate(sheet = as.character(sheet)),
               "ntuws_wave_participation_long.csv")

print_summary(long, demographics, adj$conflicts)
say("\n完成，耗時 ",
    round(as.numeric(difftime(Sys.time(), t_start, units = "secs")), 1), " 秒。")

