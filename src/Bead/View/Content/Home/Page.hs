{-# LANGUAGE CPP #-}
{-# LANGUAGE OverloadedStrings #-}
module Bead.View.Content.Home.Page (
    home
  , deleteUsersFromCourse
  , deleteUsersFromGroup
#ifdef TEST
  , sumBinaryResultTests
  , sumPercentageResultTests
#endif
  ) where

import           Control.Monad.IO.Class
import qualified Data.Map as Map
import           Data.Maybe (catMaybes)
import           Data.Time

import           Text.Blaze.Html5 ((!))
import qualified Text.Blaze.Html5 as H
import qualified Text.Blaze.Html5.Attributes as A (id)

import qualified Bead.Controller.Pages as Pages
import qualified Bead.Controller.UserStories as S
import           Bead.Domain.Evaluation
import           Bead.View.Content hiding (userState)
import qualified Bead.View.UserActions as UA
import           Bead.View.Content.SubmissionTable as ST

#ifdef TEST
import           Test.Tasty.TestSet
#endif

import           Bead.View.Content.Home.Data
import           Bead.View.Content.Home.View

home :: ViewHandler
home = ViewHandler homePage

deleteUsersFromCourse :: ModifyHandler
deleteUsersFromCourse = ModifyHandler deleteUsersFromCourseHandler

deleteUsersFromGroup :: ModifyHandler
deleteUsersFromGroup = ModifyHandler deleteUsersFromGroupHandler

administratedCourseMap = stcAdminCourses . submissionTableCtx
administratedGroupMap  = stcAdminGroups  . submissionTableCtx
courseTestScripts      = stcCourseTestScriptInfos . submissionTableCtx

homePage :: GETContentHandler
homePage = withUserState $ \s -> do
  converter <- userTimeZoneToLocalTimeConverter
  now <- liftIO getCurrentTime
  fmap homeContent $ do
    (userStory $ do
       ua <- S.userAssignments
       sbmTables <- (map sortUserLines <$> S.submissionTables)
       stc <- ST.submissionTableContext
       return $
         HomePageData
           s
           (not . Map.null $ stcAdminCourses stc)
           (not . Map.null $ stcAdminGroups stc)
           ua
           sbmTables
           converter
           stc
           now)

deleteUsersFromCourseHandler :: POSTContentHandler
deleteUsersFromCourseHandler =
  UA.DeleteUsersFromCourse
    <$> (getParameter delUserFromCourseKeyPrm)
    <*> (getParameterValues delUserFromCoursePrm)

deleteUsersFromGroupHandler :: POSTContentHandler
deleteUsersFromGroupHandler =
  UA.DeleteUsersFromGroup
    <$> (getParameter delUserFromGroupKeyPrm)
    <*> (getParameterValues delUserFromGroupPrm)

navigation :: [Pages.Page a b c d e] -> IHtml
navigation links = do
  msg <- getI18N
  return $ H.div ! A.id "menu" $ H.ul $ mapM_ (i18n msg . linkToPage) links

submissionTableInfoAssignments = submissionTableInfoCata course group where
  course _n _us as _uls _ans _ck = as
  group _n _us cgas _uls _ans _ck _gk = map (cgInfoCata id id) cgas


-- * Evaluation

-- Produces the result of the submissions. The selected evaluation method depends
-- on the given configuration.
calculateSubmissionResult :: I18N -> [SubmissionInfo] -> EvConfig -> Either String Result
calculateSubmissionResult msg si e =
  case results of
    [] -> (Left (msg $ msg_Home_HasNoSummary "N/A"))
    rs -> evaluationDataMap
            (const (sumBinaryResult msg rs))
            (flip (sumPercentageResult msg) rs)
            (evaluationDataMap
               BinEval
               (PctEval . PctConfig) $ evConfig e)
  where
    results = filter evaluated si

    evaluated = submissionInfoCata
                  False -- not found
                  False -- unevaulated
                  (const False) -- tested
                  (\_ _ -> True) -- result

-- Produces the result of a user's submission list for a binary evaluation.
-- Returns (Right result) when there is no error in the submission set, otherwise (Left "Reason")
sumBinaryResult :: I18N -> [SubmissionInfo] -> Either String Result
sumBinaryResult msg = calcEvaluationResult binary calcBinaryResult
  where
    -- Checks if the result is a binary result
    -- Produces (Left "error") if the result is not a binary result
    -- otherwise (Right result)
    binary :: EvResult -> Either String Binary
    binary = evaluationDataMap Right (const . Left $ (msg $ msg_Home_NonBinaryEvaluation "Not a binary evaluation")) . evResult

    calcBinaryResult :: [Binary] -> Result
    calcBinaryResult bs = calculateEvaluation bs ()

-- Produces the result of a user's submission list for a percentage evaluation using
-- the given config.
-- Returns (Right result) when there is no error in the submission set, otherwise (Left "Reason")
sumPercentageResult :: I18N -> PctConfig -> [SubmissionInfo] -> Either String Result
sumPercentageResult msg config = calcEvaluationResult percentage calcPercentageResult
  where
    percentage :: EvResult -> Either String Percentage
    percentage = evaluationDataMap
                   (const . Left $ (msg $ msg_Home_NonPercentageEvaluation "Not a percentage evaluation"))
                   Right
                   . evResult

    calcPercentageResult :: [Percentage] -> Result
    calcPercentageResult ps = calculateEvaluation ps config

-- Produces the result of a user's submission list using the selectResult
-- projection and the calculateResult function
-- Returns (Right result) if the calculation is correct, otherwise (Left "reason")
calcEvaluationResult
  :: (EvResult -> Either String result) -- Selects the correct result or produces an error msg
  -> ([result] -> Result) -- Aggregates the results calculating into the final result
  -> [SubmissionInfo]
  -> Either String Result
calcEvaluationResult selectResult calculateResult
  = right calculateResult . checkErrors . map selectResult . filterEvaluation
  where
    result = const Just

    right :: (a -> b) -> Either c a -> Either c b
    right f (Right x) = Right (f x)
    right _ (Left x)  = (Left x)

    -- Filters only the evaluation results
    filterEvaluation :: [SubmissionInfo] -> [EvResult]
    filterEvaluation = catMaybes . map (submissionInfoCata Nothing Nothing (const Nothing) result)

    -- Checks if no error is found.
    -- Produces (Left "error") when at least one element has an error,
    -- otherwise the list
    checkErrors :: [Either String a] -> Either String [a]
    checkErrors [] = Right []
    checkErrors ((Left msg):_) = Left msg
    checkErrors ((Right b):bs) = fmap (b:) (checkErrors bs)

-- * Tests

#ifdef TEST
binPassed = Submission_Result undefined (binaryResult Passed)
binFailed = Submission_Result undefined (binaryResult Failed)
pctResult = Submission_Result undefined (percentageResult 0.1)

sumBinaryResultTests = eqPartitions sumBinaryResult'
  [ Partition "Empty list" (trans, []) (Right Failed) ""
  , Partition "Homogenous passed list" (trans, [binPassed, binPassed]) (Right Passed) ""
  , Partition "Homogenous failed list" (trans, [binPassed, binFailed]) (Right Failed) ""
  , Partition "Inhomogenous list" (trans, [binPassed, binFailed, pctResult, binPassed])
              (Left "Not a binary evaluation") ""
  ] where sumBinaryResult' = uncurry sumBinaryResult

cfg30 = PctConfig 0.3 -- At least 30% is needed to pass
cfg40 = PctConfig 0.4 -- At least 40% is needed to pass
pct x = Submission_Result undefined (percentageResult x)

sumPercentageResultTests = eqPartitions sumPercentageResult'
  [ Partition "Empty list"     (trans, cfg30, []) (Right Failed) ""
  , Partition "30% and passed" (trans, cfg30, [pct 0.3]) (Right Passed) ""
  , Partition "40% and failed" (trans, cfg40, [pct 0.3]) (Right Failed) ""
  , Partition "60/200 and passed" (trans, cfg30, [pct 0.1, pct 0.5]) (Right Passed) ""
  , Partition "50/200 and failed" (trans, cfg30, [pct 0, pct 0.5]) (Right Failed) ""
  , Partition "Inhomogenous list" (trans, cfg30, [pct 0, binPassed])
                                  (Left "Not a percentage evaluation") ""
  ] where sumPercentageResult' (trans, cfg, lst) = sumPercentageResult trans cfg lst

binConfig = BinEval ()
pctConfig = PctEval cfg30
#endif
