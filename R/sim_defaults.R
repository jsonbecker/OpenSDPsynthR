## Break into discrete functions

## Calculate ages, toss out non-sensical records
## add longitudinal indicators
##

#' Generate student-level attributes
#'
#' @param nstu integer, number of students to simulate
#' @param control a list, defined by \code{\link{sim_control}}
#' @import dplyr
#' @importFrom wakefield sex
#' @importFrom wakefield dob
#' @importFrom wakefield race
#' @importFrom magrittr "%<>%"
#' @details The default is to generate students in racial groups and male/female
#' in proportion to the U.S. population.
#' @return a data.frame
#' @export
gen_students <- function(nstu, control = sim_control()){
  if(!is.null(control$minyear)){
    tmp <- paste0(control$minyear, "-01-01")
    start <- as.integer(Sys.Date() - as.Date(tmp))
    start <- start + (365 * 6) # trying to not generate PK data
  }
  K <- 365L * control$n_cohorts
  demog_master <- data.frame(
    sid = wakefield::id(nstu, random = TRUE),
    "Sex" = wakefield::sex(nstu),
    "Birthdate" = wakefield::dob(nstu, start = Sys.Date() - start,
                           k = K, by = "1 days"),
    "Race" = wakefield::race(nstu, x = control$race_groups, prob = control$race_prob)
  )
  demog_master$Race <- factor(demog_master$Race)
  demog_master %<>% make_inds("Race")
  # Recode race into binary indicators
  demog_master %<>% mutate_at(5:ncol(demog_master),
                              funs(recode(., `0` = "No", `1` = "Yes")))
  demog_master <- as.data.frame(demog_master)
  demog_master$id_type <- "Local"
  # Do not need to be warned about NAs in binomial
  return(demog_master)
}


#' Grand simulation
#' @rdname simpop
#' @param nstu integer, number of students to simulate
#' @param seed integer, random seed to make simulation reproducible across
#' sessions, optional
#' @param control a list, defined by \code{\link{sim_control}}
#' @return a list with simulated data
#' @importFrom lubridate year
#' @import dplyr
#' @importFrom tidyr gather
#' @export
#' @examples
#' \dontrun{
#' out <- simpop(nstu = 20, seed = 213)
#' }
simpop <- function(nstu, seed=NULL, control = sim_control()){
  ## Generate student-year data
  # Set seed
  if (!is.null(seed))
    set.seed(seed)
  else if (!exists(".Random.seed", envir = .GlobalEnv))
    runif(1)
  message("Preparing student identities for ", nstu, " students...")
  suppressMessages({
    demog_master <- gen_students(nstu = nstu, control = control)
  })
  message("Creating annual enrollment for ", nstu, " students...")
  suppressMessages({
    stu_year <- gen_student_years(data = demog_master, control = control)
  })
  idvar <- names(demog_master)[which(names(demog_master) %in%
                                       c("ID", "id", "sid"))]
  # Get first observed year for student
  stu_first <- stu_year %>% group_by_(idvar) %>%
    mutate(flag = if_else(age == min(age), 1, 0)) %>%
    filter(flag == 1) %>% select(-flag) %>% as.data.frame() %>%
    select_(idvar, "year", "age")
  stu_first <- inner_join(stu_first, demog_master[, c(idvar, "Race")],
                          by = idvar)
  stu_first$age <- round(stu_first$age, 0)
  message("Assigning ", nstu, " students to initial FRPL, IEP, and ELL status")
  stu_first <- assign_baseline(baseline = "program", stu_first)
  message("Assigning initial grade levels...")
  stu_first <- assign_baseline("grade", stu_first)
  message("Organizing status variables for you...")
  stu_year <- left_join(stu_year, stu_first[, c(idvar, "ell", "iep", "frpl", "grade")],
                        by = idvar)
  rm(stu_first)
  message("Assigning ", nstu, " students longitudinal status trajectories...")
  cond_vars <- get_sim_groupvars(control)
  stu_year <- left_join(stu_year, demog_master[, c(idvar, cond_vars)],
                        by = idvar)
  stu_year <- gen_annual_status(stu_year, control = control)
  # Identify student promotion/retention
  stu_year <- stu_year %>% group_by(sid) %>% arrange(sid, year) %>%
    mutate(grade_diff = num_grade(grade) - num_grade(lag(grade))) %>%
    mutate(grade_advance = ifelse(grade_diff > 0, "Promotion", "Retention")) %>%
    mutate(grade_advance = lag(grade_advance)) %>%
    # so that promotion/retention unknown in final year
    select(-grade_diff) %>% ungroup()
  stu_year <- as.data.frame(stu_year)
  stu_year$year <- as.numeric(stu_year$year) # coerce to numeric to avoid user integer inputs
  suppressWarnings({ # ignore warning about missing values where no grade 9 exists
    stu_year <- stu_year %>% group_by(sid) %>%
      mutate(cohort_year = min(year[grade == "9"])) %>%
      mutate(cohort_grad_year = cohort_year + 3) %>% ungroup()
  })
  stu_year$cohort_year[!is.finite(stu_year$cohort_year)] <- NA
  stu_year$cohort_grad_year[!is.finite(stu_year$cohort_grad_year)] <- NA
  # Create longitudinal ell and ses here
  stu_year <- stu_year %>%
    select_(idvar, "year", "age", "grade", "frpl", "ell", "iep", "gifted",
            "grade_advance", "cohort_year", "cohort_grad_year", "exit_type",
            "enrollment_status") # hack to keep these variables in place
  message("Sorting your records")
  stu_year <- stu_year %>% arrange_(idvar, "year")
  message("Cleaning up...")
  stu_year$age <- round(stu_year$age, 0)
  stu_year <- stu_year %>% filter(age < 22)
  ## TODO: Add attendance here
  stu_year$ndays_possible <- 180
  stu_year$ndays_attend <- rpois(nrow(stu_year), 180)
  stu_year$ndays_attend <- ifelse(stu_year$ndays_attend > 180, 180, stu_year$ndays_attend)
  stu_year$att_rate <- stu_year$ndays_attend / stu_year$ndays_possible
  message("Creating ", control$nschls, " schools for you...")
  # TODO: Rewrite this so it takes control the argument
  school <- gen_schools(control = control)
  message("Assigning ", nrow(stu_year), " student-school enrollment spells...")
  stu_year <- left_join(stu_year, demog_master[, c(idvar, "White")], by = idvar)
  stu_year <- assign_schools(student = stu_year, schools = school,
                             method = "demographic")
  stu_year$White <- NULL
  message("Simulating assessment table... be patient...")
  assess <- left_join(stu_year[, c(idvar, "year", "age", "grade", "frpl",
                                   "ell", "iep", "gifted", "schid")],
                      demog_master[, 1:4], by = c(idvar))
  assess$male <- ifelse(assess$Sex == "Male", 1, 0)
  assess %<>% filter(grade %in% control$assess_grades)
  zz <- gen_assess(data = assess, control = control)
  assess <- bind_cols(assess[, c(idvar, "schid", "year")], zz)
  assess <- left_join(assess, stu_year[, c(idvar, "schid", "year", "grade")],
                      by = c(idvar, "schid", "year"))
  assess_long <- assess %>% tidyr::gather(key = "subject", value = "score", math_ss, rdg_ss)
  assess_long$subject[assess_long$subject == "math_ss"] <- "Mathematics"
  assess_long$subject[assess_long$subject == "rdg_ss"] <- "English Language Arts"
  assess_long$score_type <- "scaled"
  assess_long$assess_id <- "0001"
  assess_long$assess_name <- "State Accountability Test"
  assess_long$retest_ind <- sample(c("Yes", "No"), nrow(assess_long),
                                   replace = TRUE, prob = c(0.0001, 0.9999))

  # Organize assess tables
  proficiency_levels <- assess_long %>% group_by(year, grade, subject, assess_id) %>%
    summarize(score_mean = mean(score),
              score_error = sd(score),
              ntests = n()) %>%
    filter(ntests > 30)
  assess <- assess[, c(idvar, "schid", "year", "grade", "math_ss", "rdg_ss")]
  assess$grade_enrolled <- assess$grade
  # Add LEAID
  rm(zz)
  message("Simulating high school outcomes... be patient...")
  g12_cohort <- stu_year[stu_year$grade == "12", ] %>%
    select(1:8, schid, cohort_grad_year) %>% as.data.frame() # hack to fix alignment of tables
  # TODO: Students who repeat grade 12 have two rows in this dataframe
  g12_cohort <- na.omit(g12_cohort)
  g12_cohort <- left_join(g12_cohort, demog_master[, 1:4], by = idvar)
  g12_cohort <- left_join(g12_cohort, assess[, c("sid", "grade", "year","math_ss")] %>%
                            filter(grade == "8") %>%
                            group_by(sid) %>%
                            mutate(math_ss = math_ss[year == min(year)]) %>%
                            select(-grade, - year) %>%
                            distinct(sid, math_ss, .keep_all=TRUE),
                          by = c(idvar))
  g12_cohort$male <- ifelse(g12_cohort$Sex == "Male", 1, 0)
  g12_cohort <- group_rescale(g12_cohort, var = "math_ss", group_var = "age")
  hs_outcomes <- assign_hs_outcomes(g12_cohort, control = control)
  message("Simulating annual high school outcomes... be patient...")
  suppressWarnings({
    hs_annual <- gen_hs_annual(hs_outcomes, stu_year)
  })
  # TODO: Fix hardcoding of postsec - insert scorecard data here
  # Fix this so user can control method
  nsc_postsec <- gen_nsc(n = control$n_postsec, method = control$postsec_method)
  message("Simulating postsecondary outcomes... be patient...")
  ps_enroll <- gen_ps_enrollment(hs_outcomes = hs_outcomes, nsc = nsc_postsec,
                                 control = control)
  message("Success! Returning you student and student-year data in a list.")
  return(list(demog_master = demog_master, stu_year = stu_year,
              schools = school, stu_assess = assess, hs_outcomes = hs_outcomes,
              hs_annual = hs_annual, nsc = nsc_postsec, ps_enroll = ps_enroll,
              assessments = assess_long, proficiency = proficiency_levels))
}

#' Generate initial student status indicators
#'
#' @param data that includes the pre-requsites for generating each status
#' @param baseline character, name of a baseline status to calculate
#'
#' @return the data with status variables appended
#' @export
gen_initial_status <- function(data, baseline){
  bl_data <- get_baseline(baseline)
  data$race <- map_CEDS(data$Race)
  # Move CEDS Xwalk out of this function eventually
  stopifnot(all(bl_data$keys %in% names(data)))
  # Assign baseline creates a new vector, so assign it
  out <- assign_baseline(baseline = baseline, data = data)
  # Recode it
  out <- ifelse(out == 1, "Yes", "No")
  return(out)
}

#' Generate annual status trajectories per student
#'
#' @param data student-year data
#' @param control control list
#'
#' @return the \code{data} object, with additional variables appended
#' @export
gen_annual_status <- function(data, control = sim_control()){
  reqdVars <- get_sim_groupvars(control)
  reqdVars <- c(reqdVars, c("iep", "ell", "frpl", "grade"))
  stopifnot(all(reqdVars %in% names(data)))
  idvar <- names(data)[which(names(data) %in% c("ID", "id", "sid"))]
  data <- data %>% group_by_(idvar) %>% arrange(year) %>%
    mutate(iep = markov_cond_list(Sex[1], n = n()-1, lst = control$iep_list,
                                  t0 = iep[1], include.t0 = TRUE),
           gifted = markov_cond_list(Sex[1], n = n(), lst = control$gifted_list),
           ell = markov_cond_list("ALL", n = n() - 1, lst = control$ell_list,
                                  t0 = ell[1], include.t0 = TRUE),
           frpl = markov_cond_list(Race[1], n = n()-1, lst = control$ses_list,
                                  t0 = frpl[1], include.t0 = TRUE),
           grade = markov_cond_list("ALL", n = n() - 1, lst = control$grade_levels,
                                  t0 = grade[1], include.t0 = TRUE))
  return(data)
}


#' Generate annual student observations
#'
#' @param data students to generate annual data for
#' @param control a list, defined by \code{\link{sim_control}}
#' @importFrom lubridate year
#' @importFrom magrittr %<>%
#' @return a data.frame
#' @export
gen_student_years <- function(data, control=sim_control()){
  stu_year <- vector(mode = "list", nrow(data))
  stopifnot(any(c("ID", "id", "sid") %in% names(data)))
  if(is.null(control$minyear)){
    control$minyear <- 1997
  }
  if(is.null(control$maxyear)){
    control$maxyear <- 2017
  }
  idvar <- names(data)[which(names(data) %in% c("ID", "id", "sid"))]
  # Make a list of dataframes, one for each student, for each year
  for(i in 1:nrow(data)){
    tmp <- expand_grid_df(data[i, idvar],
                          data.frame(year = control$minyear:control$maxyear))
    stu_year[[i]] <- tmp; rm(tmp)
  }
  stu_year <- bind_rows(stu_year) %>% as.data.frame()
  names(stu_year) <- c(idvar, "year")
  bdvar <- names(data)[which(names(data) %in% c("DOB", "dob", "Birthdate"))]
  stu_year <- left_join(stu_year, data[, c(idvar, bdvar)], by = idvar)
  # Drop rows that occur before the birthdate
  stu_year %<>% filter(stu_year$year > lubridate::year(stu_year[, bdvar]))
  stu_year$age <- age_calc(dob = stu_year[, bdvar],
                          enddate = as.Date(paste0(stu_year$year, "-09-21")),
                          units = "years", precise = TRUE)
  # Cut off ages before X
  stu_year %<>% filter(stu_year$age >= 4)
  stu_year$enrollment_status <- "Currently Enrolled"
  # Fill out CEDS Spec
  stu_year$cohort_grad_year <- NA
  stu_year$cohort_year <- NA
  stu_year$exit_type <- NA
  return(stu_year)
}




#' Get grouping variables
#'
#' @param control a control list produced by \code{\link{sim_control}}
#'
#' @return a character vector of grouping terms in control lists
#' @export
get_sim_groupvars <- function(control = sim_control()){
  # consider
  #https://stat.ethz.ch/R-manual/R-devel/library/base/html/rapply.html
  out <- c(control$iep_list$GROUPVARS,
           control$gifted_list$GROUPVARS,
           control$ses_list$GROUPVARS)
  unique(out)
}


#' Generate a roster of schools to assign students to
#'
#' @param control simulation control parameters from \code{\link{sim_control}}
#' @details Controls include:
#'
#' \describe{
#' \item{n}{number of schools}
#' \item{mean}{a vector of means for the school attributes}
#' \item{sigma}{a covariance matrix for the school attributes}
#' \item{names}{vector to draw names from}
#' \item{best_schl}{a character value specifiying the ID of the best school}
#' }
#' @return a data.frame with schools and their attributes
#' @importFrom mvtnorm rmvnorm
#' @export
gen_schools <- function(control){
  n <- control$nschls
  mean <- control$school_means
  sigma <- control$school_cov_mat
  names <- control$school_names
  if(missing(mean)){
    mean_vec <- structure(
      c(0, 0, 0, 0, 0),
      .Names = c("male_per",
                 "frpl_per", "sped_per", "lep_per", "gifted_per")
    )
  } else{
    mean_vec <- mean
  }
  if(missing(sigma)){
    cov_mat <- structure(
      c(rep(0, 25)),
      .Dim = c(5L, 5L),
      .Dimnames = list(
        c("male_per", "frpl_per", "sped_per", "lep_per", "gifted_per"),
        c("male_per","frpl_per", "sped_per", "lep_per", "gifted_per")
      )
    )
  } else{
    cov_mat <- sigma
  }
  if(missing(names)){
    names <- c(LETTERS, letters)
  }
  if(length(n) > length(names)){
    stop("Please add more names or select a smaller n to generate unique names")
  }
  ids <- wakefield::id(n)
  if(any(nchar(ids) < 2)){
    ids <- sprintf("%02d", as.numeric(ids))
  }
  enroll <- rnbinom(n, size = 0.5804251, mu = 360.8085106) # starting values from existing district
  names <- sample(names, size = n, replace = FALSE)
  attribs <- mvtnorm::rmvnorm(n, mean = mean_vec, sigma = cov_mat)
  attribs[attribs < 0] <- 0
  attribs[attribs >=1] <- 0.99
  K <- length(enroll[enroll == 0])
  enroll[enroll == 0] <- sample(1:25, K, replace = FALSE)
  out <- data.frame(schid = ids, name = names, enroll = enroll,
                    stringsAsFactors = FALSE)
  out <- cbind(out, attribs)
  out$lea_id <- "0001"
  out$id_type <- "Local"
  t1Codes <- c("TGELGBNOPROG", "TGELGBTGPROG" ,"SWELIGTGPROG", "SWELIGNOPROG", "SWELIGSWPROG", "NOTTITLE1ELIG")
  out$title1_status <- sample(t1Codes, nrow(out), replace = TRUE)
  t3Codes <- c("DualLanguage", "TwoWayImmersion", "TransitionalBilingual",
               "DevelopmentalBilingual", "HeritageLanguage",
               "ShelteredEnglishInstruction", "StructuredEnglishImmersion",
               "SDAIE", "ContentBasedESL", "PullOutESL", "Other")
  out$title3_program_type <- sample(t3Codes, nrow(out), replace=TRUE)
  out$type <- sample(c("K12School", "EducationOrganizationNetwork",
                       "CharterSchoolManagementOrganization"), nrow(out),
                     replace=TRUE, prob = c(0.9, 0.05, 0.05))
  out$poverty_desig <- sample(c("HighQuartile", "LowQuartile", "Neither"),
                              nrow(out), replace = TRUE, prob = c(0.25, 0.25, 0.5))
  hip <- sample(out$schid[!out$schid %in% control$best_schl], nrow(out) %/% 4)
  # Add the high flier school to the low poverty school list
  lop <- c(sample(out$schid[!out$schid %in% hip], nrow(out) %/% 4), control$best_schl)
  out$poverty_desig <- "Neither"
  out$poverty_desig[out$schid %in% hip] <- "HighQuartile"
  out$poverty_desig[out$schid %in% lop] <- "LowQuartile"
  if(nrow(out) < 4 & nrow(out) > 1){
    if(length(out$poverty_desig[out$poverty_desig == "HighQuartile"]) == 0){
      out$poverty_desig[[1]] <- "HighQuartile"
    }
    if(length(out$poverty_desig[out$poverty_desig == "LowQuartile"]) == 0){
      out$poverty_desig[[2]] <- "LowQuartile"
    }
  }
  return(out)
}


#' Assign student enrollment spells to a school ID
#'
#' @param student data frame of student-year observations
#' @param schools data frame of schools to assign from
#' @param method currently unused, will allow for different assignment methods
#'
#' @return student, with additional column schid appended
#' @export
assign_schools <- function(student, schools, method = NULL){
  # TODO thoroughly test inputs to make sure year exists
  # TODO test that school ids match from schools
  # Assignment techniques -- purely ignorant weighting technique
  # Non-ignorant, weighted technique
  # Model based technique
  idvar <- names(student)[which(names(student) %in% c("ID", "id", "sid"))]
  school_t_list <- list(
    "ALL" = list(f = make_markov_series,
                 pars = list(tm = school_transitions(nschls = nrow(schools),
                                                     diag_limit = 0.96))),
    "GROUPVARS" = c("ALL")
  )
  # t0 should be a function of poverty, using the demographic method
  # t0 should be a function of performance using a non-demographic method
  if(is.null(method)){
    student <- student %>% group_by_(idvar) %>% arrange(year) %>%
      mutate(schid = markov_cond_list("ALL", n = n()-1, school_t_list,
                                      t0 = sample(schools$schid, 1, prob = schools$enroll),
                                      include.t0 = TRUE))
  } else if(method == "demographic"){
    schools$frpl_prob <- ifelse(schools$poverty_desig == "LowQuartile", 0.1,
                                ifelse(schools$poverty_desig == "HighQuartile",
                                       0.7, 0.2))
    schools$base_prob <- ifelse(schools$poverty_desig == "LowQuartile", 0.55,
                                ifelse(schools$poverty_desig == "HighQuartile",
                                       0.05, 0.4))
    # Create a school segregation parameter here
    schools$race_prob <- schools$frpl_prob
    schools$race_prob <- ifelse(schools$race_prob > 0.7, schools_race_prob + 0.2,
                                schools$race_prob - 0.1)
    student <- student %>% group_by(sid) %>% arrange(year) %>%
      mutate(initschid = ifelse(frpl == "1",
                                sample(schools$schid, 1, prob = schools$frpl_prob),
                                sample(schools$schid, 1, prob = schools$base_prob))) %>%
      mutate(initschid = ifelse(White == "No",
                                sample(schools$schid, 1, prob = schools$race_prob),
                                initschid)) %>%
      mutate(schid = markov_cond_list("ALL", n = n()-1, school_t_list,
                                      t0 = initschid[[1]],
                                      include.t0 =TRUE)) %>%
      select(-initschid)

  }
  return(student)
}

#' Assign high school outcomes
#'
#' @param data a dataframe with certain high school attributes
#' @param control control parameters from the \code{sim_control()} function
#'
#' @return an outcome dataframe
#' @export
assign_hs_outcomes <- function(data, control = sim_control()){
  data$scale_gpa <- gen_gpa(data = data, control = control)
  # rescale GPA
  data$gpa <- rescale_gpa(data$scale_gpa)
  zzz <- gen_grad(data = data,
                  control = control)
  data <- bind_cols(data, zzz)
  data$hs_status <- "hs_grad"
  data$hs_status[data$grad == 0] <- "none"
  data$hs_status[data$grad == 1] <- ifelse(data$cohort_grad_year == data$year,
                                           "ontime",
                                           ifelse(data$cohort_grad_year > data$year,
                                                  "early", "late"))
  data$hs_status[data$grad == 0] <-
    sapply(data$hs_status[data$grad == 0],
           function(x) {
             sample(
               c("dropout", "transferout", "still_enroll", "disappear"),
               1,
               replace = FALSE,
               prob = c(0.62, 0.31, 0.04, 0.03)
             )
           })
  data %<>% group_by(sid) %>%
    mutate(chrt_grad = min(year[grad == 1]))
  data <- bind_rows(data %>% group_by(sid) %>%
                      mutate(nrow = n()) %>% filter(nrow == 1) %>%
                      select(-nrow),
                    data %>% group_by(sid) %>%
                      mutate(nrow = n()) %>% filter(nrow > 1) %>%
                      mutate(first_flag = ifelse(year == min(year), 1, 0)) %>%
                      filter(first_flag == 1) %>% select(-first_flag, -nrow)
                    )
    zzz <- gen_ps(data, control = control)
    data <- bind_cols(data, zzz)
    outcomes <- data[, c("sid", "scale_gpa", "gpa",
                             "grad_prob", "grad", "hs_status",
                             "ps_prob", "ps", "year", "chrt_grad")]
    # outcomes$grad_cohort <- outcomes$year
    outcomes$year <- NULL

  outcomes$class_rank <- rank(outcomes$gpa, ties.method = "first")
  # Diploma codes
  diplomaCodes <- c("00806", "00807", "00808", "00809", "00810", "00811")
  nonDiplomaCodes <- c("00812", "00813", "00814",  "00815", "00816",
                       "00818", "00819", "09999")
  outcomes$ps[outcomes$grad == 0] <- 0
  outcomes$diploma_type <- NA
  #TODO Diploma type probabilities
  outcomes$diploma_type[outcomes$grad == 1] <- sample(diplomaCodes,
                                                      length(outcomes$diploma_type[outcomes$grad == 1]),
                                                      replace = TRUE)
  outcomes$diploma_type[outcomes$grad == 0] <- sample(nonDiplomaCodes,
                                                      length(outcomes$diploma_type[outcomes$grad == 0]),
                                                      replace = TRUE)
  return(outcomes)
}

#' Generate postsecondary institutions
#'
#' @param n number of institutions to generate
#' @param names names to use for schools
#' @param method default NULL, can be set to "scorecard" to use college scorecard data
#' @importFrom stringr str_trunc
#' @return a data.frame of names, IDs, and enrollment weights
#' @export
gen_nsc <- function(n, names = NULL, method = NULL){
  if(is.null(method)){
    ids <- wakefield::id(n)
    enroll <- rnbinom(n, size = 1.4087, mu = 74.62) # starting values from existing district
    if(is.null(names)){
      names <- c(LETTERS, letters)
    }
    if(length(n) > length(names)){
      stop("Please add more names or select a smaller n to generate unique names")
    }
    names <- sample(names, size = n, replace = FALSE)
    # attribs <- mvtnorm::rmvnorm(n, mean = mean_vec, sigma = cov_mat)
    # attribs[attribs < 0] <- 0
    # attribs[attribs >=1] <- 0.99
    K <- length(enroll[enroll == 0])
    enroll[enroll == 0] <- sample(1:25, K, replace = FALSE)
    out <- data.frame(opeid = ids, name = names, enroll = enroll,
                      stringsAsFactors = FALSE)
    out$short_name <- stringr::str_trunc(out$name, 20, "right")
    out$type <- NA
    out$type[grepl("COMMUNITY", out$name)] <- "2yr"
    out$type[grepl("UNIVERSITY", out$name)] <- "4yr"
    out$type[grepl("PRIVATE", out$name)] <- "4yr"
    out$type[grepl("COLLEGE OF", out$name)] <- "other"
    # out <- cbind(out, attribs)
  }
  if(method == "scorecard"){
    # TODO: set balance of 2yr and 4yr
    out <- bind_rows(
      college_scorecard[sample(row.names(college_scorecard[grepl("associate", college_scorecard$degrees_awarded_predominant),]), n*4),],
      college_scorecard[sample(row.names(college_scorecard[grepl("bachelor", college_scorecard$degrees_awarded_predominant),]), n*2),],
      college_scorecard[sample(row.names(college_scorecard[grepl("certificate", college_scorecard$degrees_awarded_predominant),]), n),]
      )
    out <- out[sample(row.names(out), n),]
    out$opeid <- out$ope8_id; out$ope8_id <- NULL
    out$short_name <- stringr::str_trunc(out$name, 35, "right")
    out$enroll <- out$size
    out$size <- NULL
    out$type <- NA
    out$type[grepl("associate", out$degrees_awarded_predominant)] <- "2yr"
    out$type[grepl("bachelor", out$degrees_awarded_predominant)] <- "4yr"
    out$type[grepl("certificate", out$degrees_awarded_predominant)] <- "other"
    out$degrees_awarded_predominant <- NULL
    # Jitter 0s
    # enforce positivity
    out$cutVar <- out$part_time_share
    out$cutVar[out$cutVar == 0] <- abs(jitter(out$cutVar[out$cutVar == 0]))
    out$rank <- as.numeric(cut(out$cutVar,
                           breaks = unique(quantile(out$cutVar,
                                                    probs = seq(0, 1, 0.2))),
                           include.lowest=TRUE))
    out$cutVar <- NULL
  }

  return(out)
}
