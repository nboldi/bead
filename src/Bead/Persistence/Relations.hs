module Bead.Persistence.Relations (
    userAssignmentKeys
  , userAssignmentKeyList
  , submissionDesc
  , submissionListDesc
  , submissionDetailsDesc
  , groupDescription
  , isAdminedSubmission
  , canUserCommentOn
  , submissionTables
  , courseSubmissionTableInfo
  , userSubmissionDesc
  , userLastSubmissionInfo
  , courseOrGroupOfAssignment
  , courseNameAndAdmins
  , administratedGroupsWithCourseName
  , groupsOfUsersCourse
  , removeOpenedSubmission
  , deleteUserFromCourse -- Deletes a user from a course, searching the group id for the unsubscription
  , isThereASubmissionForGroup -- Checks if the user submitted any solutions for the group
  , isThereASubmissionForCourse -- Checks if the user submitted any solutions for the course
  , testScriptInfo -- Calculates the test script information for the given test key
  ) where

{-
This module contains higher level functionality for querying information
useing the primitves defined in the Persist module. Mainly Relations module
related information is computed.
-}

import           Control.Applicative ((<$>))
import           Control.Arrow
import           Control.Monad (forM, when)
import           Control.Monad.Transaction.TIO
import           Data.Function (on)
import           Data.List (nub, sortBy, intersect, find)
import           Data.Map (Map)
import qualified Data.Map as Map
import           Data.Maybe (catMaybes)
import           Data.Time (UTCTime, getCurrentTime)

import           Bead.Domain.Entities
import           Bead.Domain.Relationships
import           Bead.Persistence.Persist
import           Bead.View.Snap.Translation

-- * Combined Persistence Tasks

-- Computes the Group key list, which should contain one element,
-- for a course key and a user, which the user attends in.
groupsOfUsersCourse :: Username -> CourseKey -> Persist [GroupKey]
groupsOfUsersCourse u ck = do
  ugs <- nub <$> userGroups u
  cgs <- nub <$> groupKeysOfCourse ck
  return $ intersect ugs cgs

-- Produces a Just Assignment list, if the user is registered for some courses,
-- otherwise Nothing.
userAssignmentKeys :: Username -> Persist (Maybe [AssignmentKey])
userAssignmentKeys u = do
  gs <- userGroups u
  cs <- userCourses u
  case (cs,gs) of
    ([],[]) -> return Nothing
    _       -> do
      asg <- concat <$> (mapM (groupAssignments)  (nub gs))
      asc <- concat <$> (mapM (courseAssignments) (nub cs))
      return . Just $ nub (asg ++ asc)

-- Produces the assignment key list for the user, it the user
-- is not registered in any course the result is the empty list
userAssignmentKeyList :: Username -> Persist [AssignmentKey]
userAssignmentKeyList u = (maybe [] id) <$> (userAssignmentKeys u)

courseOrGroupOfAssignment :: AssignmentKey -> Persist (Either CourseKey GroupKey)
courseOrGroupOfAssignment ak = do
  mGk <- groupOfAssignment ak
  case mGk of
    Just gk -> return . Right $ gk
    Nothing -> do
      mCk <- courseOfAssignment ak
      case mCk of
        Just ck -> return . Left $ ck
        Nothing -> error $ "Impossible: No course or groupkey was found for the assignment:" ++ show ak

administratedGroupsWithCourseName :: Username -> Persist [(GroupKey, Group, String)]
administratedGroupsWithCourseName u = do
  gs <- administratedGroups u
  forM gs $ \(gk,g) -> do
    fn <- fullGroupName gk
    return (gk,g,fn)

-- Produces a full name for a group including the name of the course.
fullGroupName :: GroupKey -> Persist String
fullGroupName gk = do
  ck <- courseOfGroup gk
  course <- loadCourse ck
  group <- loadGroup gk
  return $ concat [(courseName course), " - ", (groupName group)]

groupDescription :: GroupKey -> Persist (GroupKey, GroupDesc)
groupDescription gk = do
  name <- fullGroupName gk
  admins <- mapM (userDescription) =<< (groupAdmins gk)
  let gd = GroupDesc {
    gName   = name
  , gAdmins = map ud_fullname admins
  }
  return (gk,gd)

submissionDesc :: SubmissionKey -> Persist SubmissionDesc
submissionDesc sk = do
  s  <- solution <$> loadSubmission sk
  un <- usernameOfSubmission sk
  u  <- u_name <$> loadUser un
  ak <- assignmentOfSubmission sk
  asg <- loadAssignment ak
  cgk <- courseOrGroupOfAssignment ak
  (c,gr) <- case cgk of
    Left ck  -> (courseEvalConfig &&& courseName) <$> loadCourse ck
    Right gk -> do
      cfg  <- groupEvalConfig <$> loadGroup gk
      name <- fullGroupName gk
      return (cfg, name)
  cs  <- mapM (loadComment) =<< (commentsOfSubmission sk)
  return SubmissionDesc {
    eGroup    = gr
  , eStudent  = u
  , eSolution = s
  , eConfig = c
  , eAssignmentKey   = ak
  , eAssignmentTitle = assignmentName asg
  , eAssignmentDesc  = assignmentDesc asg
  , eComments = cs
  }

courseNameAndAdmins :: AssignmentKey -> Persist (CourseName, [UsersFullname])
courseNameAndAdmins ak = do
  eCkGk <- courseOrGroupOfAssignment ak
  (name, admins) <- case eCkGk of
    Left  ck -> do
      name   <- courseName <$> loadCourse ck
      admins <- courseAdmins ck
      return (name, admins)
    Right gk -> do
      name   <- fullGroupName gk
      admins <- groupAdmins gk
      return (name, admins)
  adminNames <- mapM (fmap ud_fullname . userDescription) admins
  return (name, adminNames)


submissionListDesc :: Username -> AssignmentKey -> Persist SubmissionListDesc
submissionListDesc u ak = do
  (name, adminNames) <- courseNameAndAdmins ak
  asg <- loadAssignment ak
  now <- hasNoRollback getCurrentTime

  -- User submissions should not shown for urn typed assignments, only after the end
  -- period
  submissions <- assignmentTypeCata
    -- Normal assignment
    (Right <$> (mapM submissionStatus =<< userSubmissions u ak))
    -- Urn assignment
    (case (assignmentEnd asg < now) of
       True  -> Right <$> (mapM submissionStatus =<< userSubmissions u ak)
       False -> Left  <$> (mapM submissionTime =<< userSubmissions u ak))
    (assignmentType asg)

  return SubmissionListDesc {
    slGroup = name
  , slTeacher = adminNames
  , slAssignment = asg
  , slSubmissions = submissions
  }
  where
    submissionStatus sk = do
      time <- solutionPostDate <$> loadSubmission sk
      si <- submissionInfo sk
      return (sk, time, si, "TODO: EvaluatedBy")

    submissionTime sk = solutionPostDate <$> loadSubmission sk

submissionEvalStr :: SubmissionKey -> Persist (Maybe String)
submissionEvalStr sk = do
  mEk <- evaluationOfSubmission sk
  case mEk of
    Nothing -> return Nothing
    Just ek -> eString <$> loadEvaluation ek
  where
    eString = Just . translateMessage trans . resultString . evaluationResult

submissionDetailsDesc :: SubmissionKey -> Persist SubmissionDetailsDesc
submissionDetailsDesc sk = do
  ak <- assignmentOfSubmission sk
  (name, adminNames) <- courseNameAndAdmins ak
  asg <- loadAssignment ak
  sol <- solution       <$> loadSubmission sk
  cs  <- mapM (loadComment) =<< (commentsOfSubmission sk)
  s   <- submissionEvalStr sk
  return SubmissionDetailsDesc {
    sdGroup   = name
  , sdTeacher = adminNames
  , sdAssignment = asg
  , sdStatus     = s
  , sdSubmission = sol
  , sdComments   = cs
  }

-- | Checks if the assignment of the submission is adminstrated by the user
isAdminedSubmission :: Username -> SubmissionKey -> Persist Bool
isAdminedSubmission u sk = do
  -- Assignment of the submission
  ak <- assignmentOfSubmission sk

  -- Assignment Course Key
  ack <- either return (courseOfGroup) =<< (courseOrGroupOfAssignment ak)

  -- All administrated courses
  groupCourses <- mapM (courseOfGroup . fst) =<< (administratedGroups u)
  courses <- map fst <$> administratedCourses u
  let allCourses = nub (groupCourses ++ courses)

  return $ elem ack allCourses


-- TODO
canUserCommentOn :: Username -> SubmissionKey -> Persist Bool
canUserCommentOn u sk = return True

-- Returns all the submissions of the users for the groups that the
-- user administrates
submissionTables :: Username -> Persist [SubmissionTableInfo]
submissionTables u = do
  groupKeys <- map fst <$> administratedGroups u
  groupTables  <- mapM (groupSubmissionTableInfo) groupKeys
  return groupTables

groupSubmissionTableInfo :: GroupKey -> Persist SubmissionTableInfo
groupSubmissionTableInfo gk = do
  ck <- courseOfGroup gk
  gassignments <- groupAssignments gk
  cassignments <- courseAssignments ck
  usernames   <- subscribedToGroup gk
  name <- fullGroupName gk
  evalCfg <- groupEvalConfig <$> loadGroup gk
  mkGroupSubmissionTableInfo name evalCfg usernames cassignments gassignments ck gk

-- Returns the course submission table information for the given course key
courseSubmissionTableInfo :: CourseKey -> Persist SubmissionTableInfo
courseSubmissionTableInfo ck = do
  assignments <- courseAssignments ck
  usernames   <- subscribedToCourse ck
  (name,evalCfg) <- (courseName &&& courseEvalConfig) <$> loadCourse ck
  mkCourseSubmissionTableInfo name evalCfg usernames assignments ck

-- Sort the given keys into an ordered list based on the time function
sortKeysByTime :: (key -> Persist UTCTime) -> [key] -> Persist [key]
sortKeysByTime time keys = map snd . sortBy (compare `on` fst) <$> mapM getTime keys
  where
    getTime k = do
      t <- time k
      return (t,k)

loadAssignmentInfos :: [AssignmentKey] -> Persist (Map AssignmentKey Assignment)
loadAssignmentInfos as = Map.fromList <$> mapM loadAssignmentInfo as
  where
    loadAssignmentInfo a = do
       asg <- loadAssignment a
       return (a,asg)

submissionInfoAsgKey :: Username -> AssignmentKey -> Persist (AssignmentKey, SubmissionInfo)
submissionInfoAsgKey u ak = addKey <$> (userLastSubmissionInfo u ak)
  where
    addKey s = (ak,s)

calculateResult evalCfg = evaluateResults evalCfg . map sbmResult . filter hasResult
  where
    hasResult (Submission_Result _ _) = True
    hasResult _                       = False

    sbmResult (Submission_Result _ r) = r
    sbmResult _ = error "sbmResult: impossible"


mkCourseSubmissionTableInfo
  :: String -> EvaluationConfig -> [Username] -> [AssignmentKey] -> CourseKey
  -> Persist SubmissionTableInfo
mkCourseSubmissionTableInfo courseName evalCfg us as key = do
  assignments <- sortKeysByTime assignmentCreatedTime as
  assignmentInfos <- loadAssignmentInfos as
  ulines <- forM us $ \u -> do
    ud <- userDescription u
    asi <- mapM (submissionInfoAsgKey u) as
    let result = case asi of
                   [] -> Nothing
                   _  -> calculateResult evalCfg $ map snd asi
    return (ud, result, Map.fromList asi)
  return CourseSubmissionTableInfo {
      stiCourse = courseName
    , stiEvalConfig = evalCfg
    , stiUsers = us
    , stiAssignments = assignments
    , stiUserLines = ulines
    , stiAssignmentInfos = assignmentInfos
    , stiCourseKey = key
    }

mkGroupSubmissionTableInfo
  :: String -> EvaluationConfig
  -> [Username] -> [AssignmentKey] -> [AssignmentKey]
  -> CourseKey -> GroupKey
  -> Persist SubmissionTableInfo
mkGroupSubmissionTableInfo courseName evalCfg us cas gas ckey gkey = do
  cgAssignments   <- sortKeysByTime createdTime ((map CourseInfo cas) ++ (map GroupInfo gas))
  assignmentInfos <- loadAssignmentInfos (cas ++ gas)
  ulines <- forM us $ \u -> do
    ud <- userDescription u
    casi <- mapM (submissionInfoAsgKey u) cas
    gasi <- mapM (submissionInfoAsgKey u) gas
    let result = case gasi of
                   [] -> Nothing
                   _  -> calculateResult evalCfg $ map snd gasi
    return (ud, result, Map.fromList (casi ++ gasi))
  return GroupSubmissionTableInfo {
      stiCourse = courseName
    , stiEvalConfig = evalCfg
    , stiUsers = us
    , stiCGAssignments = cgAssignments
    , stiUserLines = ulines
    , stiAssignmentInfos = assignmentInfos
    , stiCourseKey = ckey
    , stiGroupKey  = gkey
    }
  where
    createdTime = cgInfoCata
      (assignmentCreatedTime)
      (assignmentCreatedTime)

submissionInfo :: SubmissionKey -> Persist SubmissionInfo
submissionInfo sk = do
  mEk <- evaluationOfSubmission sk
  case mEk of
    Nothing -> do
      cs <- mapM (loadComment) =<< (commentsOfSubmission sk)
      return $ case find isMessageComment cs of
        Nothing -> Submission_Unevaluated
        Just _t -> Submission_Tested
    Just ek -> (Submission_Result ek . evaluationResult) <$> loadEvaluation ek

-- Produces information of the last submission for the given user and assignment
userLastSubmissionInfo :: Username -> AssignmentKey -> Persist SubmissionInfo
userLastSubmissionInfo u ak =
  (maybe (return Submission_Not_Found) (submissionInfo)) =<< (lastSubmission ak u)

userSubmissionDesc :: Username -> AssignmentKey -> Persist UserSubmissionDesc
userSubmissionDesc u ak = do
  -- Calculate the normal fields
  asgName       <- assignmentName <$> loadAssignment ak
  courseOrGroup <- courseOrGroupOfAssignment ak
  crName <- case courseOrGroup of
              Left  ck -> courseName <$> loadCourse ck
              Right gk -> fullGroupName gk
  student <- ud_fullname <$> userDescription u
  keys    <- userSubmissions u ak
  -- Calculate the submission information list
  submissions <- flip mapM keys $ \sk -> do
    time  <- solutionPostDate <$> loadSubmission sk
    sinfo <- submissionInfo sk
    return (sk, time, sinfo)

  return UserSubmissionDesc {
    usCourse         = crName
  , usAssignmentName = asgName
  , usStudent        = student
  , usSubmissions    = submissions
  }

-- Helper computation which removes the given submission from
-- the opened submission directory, which is optimized by
-- assignment and username keys, for the quickier lookup
removeOpenedSubmission :: SubmissionKey -> Persist ()
removeOpenedSubmission sk = do
  ak <- assignmentOfSubmission sk
  u  <- usernameOfSubmission sk
  removeFromOpened ak u sk

-- Make unsibscribe a user from a course if the user attends in the course
-- otherwise do nothing
deleteUserFromCourse :: CourseKey -> Username -> Persist ()
deleteUserFromCourse ck u = do
  cs <- userCourses u
  when (ck `elem` cs) $ do
    gs <- userGroups u
    -- Collects all the courses for the user's group
    cgMap <- Map.fromList <$> (forM gs $ runKleisli ((k (courseOfGroup)) &&& (k return)))
    -- Unsubscribe the user from a given course with the found group
    maybe
      (return ()) -- TODO: Logging should be usefull
      (unsubscribe u ck)
      (Map.lookup ck cgMap)
  where
    k = Kleisli

testScriptInfo :: TestScriptKey -> Persist TestScriptInfo
testScriptInfo tk = do
  script <- loadTestScript tk
  return TestScriptInfo {
      tsiName = tsName script
    , tsiDescription = tsDescription script
    , tsiType = tsType script
    }

-- Returns True if the given student submitted at least one solution for the
-- assignments for the given group, otherwise False
isThereASubmissionForGroup :: Username -> GroupKey -> Persist Bool
isThereASubmissionForGroup u gk = do
  aks <- groupAssignments gk
  (not . null . catMaybes) <$> mapM (flip (lastSubmission) u) aks

-- Returns True if the given student submitted at least one solution for the
-- assignments for the given group, otherwise False
isThereASubmissionForCourse :: Username -> CourseKey -> Persist Bool
isThereASubmissionForCourse u ck = do
  aks <- courseAssignments ck
  (not . null . catMaybes) <$> mapM (flip (lastSubmission) u) aks