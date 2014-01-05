{-# LANGUAGE OverloadedStrings, CPP #-}
module Bead.View.Snap.Content.Home (
    home
#ifdef TEST
  , sumBinaryResultTests
  , sumPercentageResultTests
  , calculateSubmissionResultTests
#endif
  ) where

import Numeric (showHex)
import Data.Function (on)
import Data.Maybe (catMaybes)
import qualified Data.Map as Map (lookup)
import Data.List (intersperse, sortBy)
import Data.String (fromString)
import Data.Time
import Control.Monad (join, when, liftM)
import Control.Monad.Identity
import Control.Monad.Trans.Error

import Bead.Domain.Entities as E (Role(..))
import Bead.Domain.Evaluation
import Bead.Domain.Relationships (AssignmentDesc(..))
import Bead.Controller.ServiceContext (UserState(..))
import Bead.Controller.Pages as P (Page(..))
import Bead.View.Snap.Pagelets
import Bead.View.Snap.Content hiding (userState)
import Bead.Controller.UserStories (
    userAssignments
  , submissionTables
  , administratedCourses
  , administratedGroups
  )

import Text.Blaze.Html5 (Html, (!))
import qualified Text.Blaze.Html5 as H
import qualified Text.Blaze.Html5.Attributes as A (class_, style, id, colspan)

#ifdef TEST
import Bead.Invariants
#endif

home :: Content
home = getContentHandler homePage

data HomePageData = HomePageData {
    userState   :: UserState
  , hasCourses  :: Bool -- True if the user has administrated courses
  , hasGroups   :: Bool -- True if the user has administrated groups
    -- Nothing means that the user is not registrated in any
    -- courses
  , assignments :: Maybe [(AssignmentKey, AssignmentDesc, SubmissionInfo)]
  , sTables     :: [SubmissionTableInfo]
    -- The convertes function that convert a given utc time into the users local
    -- timezone
  , timeConverter :: UserTimeConverter
  }

homePage :: GETContentHandler
homePage = withUserState $ \s -> do
  converter <- usersTimeZoneConverter
  (renderPagelet . withUserFrame s . homeContent) =<<
    (userStory
       (HomePageData s
          <$> ((not . null) <$> administratedCourses)
          <*> ((not . null) <$> administratedGroups)
          <*> userAssignments
          <*> (map sortUserLines <$> submissionTables)
          <*> (return converter)))

navigation :: [P.Page] -> Html
navigation links = H.div ! A.id "menu" $ H.ul $ mapM_ linkToPage links

homeContent :: HomePageData -> Pagelet
homeContent d = onlyHtml $ mkI18NHtml $ \i18n -> H.div # textAlign "left" $ do
  let s = userState d
      r = role s
      hasCourse = hasCourses d
      hasGroup  = hasGroups d
  when (isAdmin s) $ H.p $ do
    H.h3 $ (translate i18n "Rendszergazdai feladatok")
    navigation [P.Administration]
    H.hr
  when (courseAdminUser r) $ H.p $ do
    H.h3 $ (translate i18n "Tárgyfelelősi feladatok")
    when (not hasCourse) $ do
      translate i18n "Még nincsenek tárgyak."
  when (groupAdminUser r) $ H.p $ do
    H.h3 $ (translate i18n "Oktatói feladatok")
    when (not hasGroup) $ do
      translate i18n "Még nincsenek csoportok."
  when ((courseAdminUser r) || (groupAdminUser r)) $ do
    when (hasCourse || hasGroup) $ H.p $ do
      htmlSubmissionTables i18n (sTables d)
  when (courseAdminUser r && hasCourse) $ H.p $ do
    navigation $ [ P.CourseAdmin, NewCourseAssignment] ++
                 (if hasGroup then [P.NewGroupAssignment] else []) ++
                 [ P.EvaluationTable, P.SetUserPassword ]
    H.hr
  when (groupAdminUser r && hasGroup) $ H.p $ do
    navigation [P.NewGroupAssignment, P.EvaluationTable, P.SetUserPassword]
    H.hr
  H.h3 $ (translate i18n "Hallgatói feladatok")
  H.p $ do
    availableAssignments (timeConverter d) i18n (assignments d)
    navigation [P.GroupRegistration]
  where
    courseAdminUser = (==E.CourseAdmin)
    groupAdminUser  = (==E.GroupAdmin)

availableAssignments :: UserTimeConverter -> I18N -> Maybe [(AssignmentKey, AssignmentDesc, SubmissionInfo)] -> Html
availableAssignments _ i18n Nothing = do
  translate i18n "Még nincsenek felvett tárgyaid, vegyél fel tárgyakat!"
availableAssignments _ i18n (Just []) = do
  translate i18n "Még nincsenek kiírva feladatok."
availableAssignments timeconverter i18n (Just as) = do
  table (fieldName availableAssignmentsTable) (className assignmentTable) # informationalTable $ do
    headerLine
    mapM_ assignmentLine as
  where
    dataCell = H.td # informationalCell
    dataCell' r = H.td # (informationalCell <> r)
    headerCell t = H.th # (informationalCell <> grayBackground) $ fromString $ i18n t
    headerLine = H.tr $ do
      headerCell ""
      headerCell "Tárgy"
      headerCell "Oktató"
      headerCell "Feladat"
      headerCell "Határidő"
      headerCell "Értékelés"
    assignmentLine (k,a,s) = H.tr $ do
      case aActive a of
        True -> dataCell $ link (routeWithParams P.Submission [requestParam k]) (i18n "Új megoldás")
        False -> dataCell "Lezárva"
      dataCell (fromString . aGroup $ a)
      dataCell (fromString . join . intersperse ", " . aTeachers $ a)
      dataCell $ link (routeWithParams P.SubmissionList [requestParam k]) (fromString (aTitle a))
      dataCell (fromString . showDate . timeconverter $ aEndDate a)
      (coloredSubmissionCell dataCell' (H.td) fromString "Nincs megoldás" "Nem értékelt" "Elfogadott" "Elutasított" s)

htmlSubmissionTables :: I18N -> [SubmissionTableInfo] -> Html
htmlSubmissionTables i18n xs = mapM_ (htmlSubmissionTable i18n) . zip [1..] $ xs

-- Produces the HTML table from the submission table information,
-- if there is no users registered and submission posted to the
-- group or course students, an informational text is shown.
htmlSubmissionTable :: I18N -> (Int,SubmissionTableInfo) -> Html

-- Empty table
htmlSubmissionTable i18n (i,s)
  | and [null . stAssignments $ s, null . stUsers $ s] = H.p $ do
      translate i18n "Nincsenek feladatok vagy hallgatók a csoporthoz:"
      H.br
      fromString . stCourse $ s
      H.br

-- Non empty table
htmlSubmissionTable i18n (i,s) = table tableId (className groupSubmissionTable) # informationalTable $ do
  headLine (stCourse s)
  assignmentLine (stAssignments s)
  mapM_ userLine (stUserLines s)
  where
    tableId = join ["st", show i]
    headLine = H.tr . (H.th # textAlign "left" ! A.colspan "4") . fromString
    headerCell = H.th # (informationalCell <> grayBackground)
    dataCell r = H.td # (informationalCell <> r)
    assignmentLine as = H.tr $ do
      headerCell $ (translate i18n "Név")
      headerCell $ (translate i18n "NEPTUN")
      mapM_ (headerCell . modifyAssignmentLink) . zip [1..] $ as
      headerCell $ (translate i18n "Összesítés")

    modifyAssignmentLink (i,ak) =
      linkWithTitle
        (routeWithParams P.ModifyAssignment [requestParam ak])
        (maybe "" id . Map.lookup ak $ stAssignmentNames s)
        (show i)

    userLine (u, p, as) = H.tr $ do
      let username = ud_username u
          submissionInfos = map snd as
      dataCell noStyle . fromString . ud_fullname $ u
      dataCell noStyle . fromString . show $ username
      mapM_ (submissionCell username) $ as
      case calculateSubmissionResult submissionInfos (stEvalConfig s) of
        Left  e      -> dataCell summaryErrorStyle  $ fromString e
        Right Passed -> dataCell summaryPassedStyle $ fromString (i18n "Elfogadott")
        Right Failed -> dataCell summaryFailedStyle $ fromString (i18n "Elutasított")

    submissionCell u (ak,s) =
      coloredSubmissionCell
        dataCell
        (H.td)
        (link (routeWithParams P.UserSubmissions [requestParam u, requestParam ak]))
        " "
        "."
        "1"
        "0"
        s

-- Create a table cell for the evaulation value, where
-- simpleCell is the combinator for the non RGB colored cells
-- rgbCell is a cell combinator where the rgb value will be set
-- content how the computed text value is wrapped
-- notFound text for the non evaulated submission
-- unevaluated text for the unevaluated submission
-- passed message for the passed binary evaulation
-- failed message for the failed binary evaulation
-- s the submission information itself
coloredSubmissionCell simpleCell rgbCell content notFound unevaluated passed failed s =
  coloredCell $ content (sc s)
  where
    sc Submission_Not_Found   = notFound
    sc Submission_Unevaluated = unevaluated
    sc (Submission_Result _ r) = val r

    val (BinEval (Binary Passed)) = passed
    val (BinEval (Binary Failed)) = failed
    val (PctEval (Percentage (Scores [p]))) = percent p

    coloredCell = color s

    color =
      submissionInfoCata
        (simpleCell noStyle)        -- Not Found
        (simpleCell unevaluatedStyle) -- Unevulated
        (const resultCell)        -- Result

    resultCell (BinEval (Binary Passed)) = simpleCell binaryPassedStyle
    resultCell (BinEval (Binary Failed)) = simpleCell binaryFailedStyle
    resultCell p@(PctEval {}) = withRGBClass (EvResult p) rgbCell

    percent x = join [show . round $ (100 * x), "%"]

    withRGBClass r = maybe id (\pct html -> html ! (A.style . fromString . colorStyle . pctCellColor $ pct)) (percentValue r)

-- * Evaluation

-- Produces the result of the submissions. The selected evaluation method depends
-- on the given configuration.
calculateSubmissionResult :: [SubmissionInfo] -> EvaluationConfig -> Either String Result
calculateSubmissionResult si e =
  case results of
    [] -> (Left "Nem összesíthető")
    rs -> evaluationDataMap
            (const (sumBinaryResult rs))
            (flip sumPercentageResult rs)
            e
  where
    results = filter evaluated si

    evaluated = submissionInfoCata
                  False -- not found
                  False -- unevaulated
                  (\_ _ -> True) -- result

-- Produces the result of a user's submission list for a binary evaluation.
-- Returns (Right result) when there is no error in the submission set, otherwise (Left "Reason")
sumBinaryResult :: [SubmissionInfo] -> Either String Result
sumBinaryResult = calcEvaluationResult binary calcBinaryResult
  where
    -- Checks if the result is a binary result
    -- Produces (Left "error") if the result is not a binary result
    -- otherwise (Right result)
    binary :: EvaluationResult -> Either String Binary
    binary = evaluationDataMap Right (const . Left $ "Nem kétértékű értékelés")

    calcBinaryResult :: [Binary] -> Result
    calcBinaryResult bs = calculateEvaluation bs ()

-- Produces the result of a user's submission list for a percentage evaluation using
-- the given config.
-- Returns (Right result) when there is no error in the submission set, otherwise (Left "Reason")
sumPercentageResult :: PctConfig -> [SubmissionInfo] -> Either String Result
sumPercentageResult config = calcEvaluationResult percentage calcPercentageResult
  where
    percentage :: EvaluationResult -> Either String Percentage
    percentage = evaluationDataMap
                   (const . Left $ "Nem százalékos értékelés")
                   Right

    calcPercentageResult :: [Percentage] -> Result
    calcPercentageResult ps = calculateEvaluation ps config

-- Produces the result of a user's submission list using the selectResult
-- projection and the calculateResult function
-- Returns (Right result) if the calculation is correct, otherwise (Left "reason")
calcEvaluationResult
  :: (EvaluationResult -> Either String result) -- Selects the correct result or produces an error msg
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
    filterEvaluation :: [SubmissionInfo] -> [EvaluationResult]
    filterEvaluation = catMaybes . map (submissionInfoCata Nothing Nothing result)

    -- Checks if no error is found.
    -- Produces (Left "error") when at least one element has an error,
    -- otherwise the list
    checkErrors :: [Either String a] -> Either String [a]
    checkErrors [] = Right []
    checkErrors ((Left msg):_) = Left msg
    checkErrors ((Right b):bs) = fmap (b:) (checkErrors bs)

-- * CSS Section

binaryPassedStyle = backgroundColor "lightgreen"
binaryFailedStyle = backgroundColor "red"
unevaluatedStyle  = backgroundColor "gray"
summaryPassedStyle = backgroundColor "lightgreen"
summaryFailedStyle = backgroundColor "red"
summaryErrorStyle  = backgroundColor "yellow"

-- * Colors

newtype RGB = RGB (Int, Int, Int)

pctCellColor :: Double -> RGB
pctCellColor x = RGB (round ((1 - x) * 255), round (x * 255), 0)

colorStyle :: RGB -> String
colorStyle (RGB (r,g,b)) = join ["background-color:#", hex r, hex g, hex b]
  where
    twoDigits [d] = ['0',d]
    twoDigits ds  = ds

    hex x = twoDigits (showHex x "")

-- * Tools

-- Sorts the userlines alphabetically ordered in submissionTableInfo
sortUserLines = submissionTableInfoCata
  id -- course
  id -- number
  id -- config
  id -- assignment
  id -- assignments
  id -- user
  id -- users
  id -- userline
  sort -- userlines
  id -- assignment names
  SubmissionTableInfo
  where
   sort = sortBy (compareHun `on` fst3)

fst3 :: (a,b,c) -> a
fst3 (x,_,_) = x

-- * Tests

#ifdef TEST
binPassed = Submission_Result undefined (BinEval (Binary Passed))
binFailed = Submission_Result undefined (BinEval (Binary Failed))
pctResult = Submission_Result undefined (PctEval (Percentage (Scores [0.1])))

sumBinaryResultTests = [
    Assertion "Empty list" (sumBinaryResult []) (Right Failed)
  , Assertion "Homogenous passed list" (sumBinaryResult [binPassed, binPassed]) (Right Passed)
  , Assertion "Homogenous failed list" (sumBinaryResult [binPassed, binFailed]) (Right Failed)
  , Assertion "Inhomogenous list" (sumBinaryResult [binPassed, binFailed, pctResult, binPassed])
              (Left "Not a binary evaluation")
  ]

cfg30 = PctConfig 0.3 -- At least 30% is needed to pass
cfg40 = PctConfig 0.4 -- At least 40% is needed to pass
pct x = Submission_Result undefined (PctEval (Percentage (Scores [x])))

sumPercentageResultTests = [
    Assertion "Empty list"     (sumPercentageResult cfg30 []) (Right Failed)
  , Assertion "30% and passed" (sumPercentageResult cfg30 [pct 0.3]) (Right Passed)
  , Assertion "40% and failed" (sumPercentageResult cfg40 [pct 0.3]) (Right Failed)
  , Assertion "60/200 and passed" (sumPercentageResult cfg30 [pct 0.1, pct 0.5]) (Right Passed)
  , Assertion "50/200 and failed" (sumPercentageResult cfg30 [pct 0, pct 0.5]) (Right Failed)
  , Assertion "Inhomogenous list" (sumPercentageResult cfg30 [pct 0, binPassed])
                                  (Left "Not a percentage evaluation")
  ]

binConfig = BinEval ()
pctConfig = PctEval cfg30

calculateSubmissionResultTests = [
    Assertion "Binary config, failed"
              (calculateSubmissionResult [binPassed, binFailed] binConfig) (Right Failed)
  , Assertion "Percentage config, failed"
              (calculateSubmissionResult [pct 0.3, pct 0.1] pctConfig) (Right Failed)
  , Assertion "Binary config, wrong list"
              (calculateSubmissionResult [binPassed, binFailed] pctConfig)
              (Left "Not a percentage evaluation")
  , Assertion "Percentage config, wrong list"
              (calculateSubmissionResult [pct 0.3, pct 0.1] binConfig)
              (Left "Not a binary evaluation")
  ]
#endif
