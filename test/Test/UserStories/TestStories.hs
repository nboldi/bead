module Test.UserStories.TestStories (
    tests
  ) where

import           Control.Monad (when)
import           Prelude hiding (log)

import           Data.Time.Clock
import           System.Directory (removeDirectoryRecursive)

import           Bead.Controller.Logging
import qualified Bead.Controller.Pages as P
import           Bead.Controller.ServiceContext
import           Bead.Controller.UserStories as U
import           Bead.Domain.Entities as E
import           Bead.Domain.Entity.Assignment hiding (name)
import           Bead.Domain.Relationships (TCCreation(..))
import           Bead.Domain.Shared.Evaluation
import           Bead.Domain.TimeZone (utcZoneInfo)
import qualified Bead.Persistence.Initialization as PersistInit
import           Bead.Persistence.Persist
import           Bead.View.Snap.Translation (trans)

import           Test.HUnit hiding (Test(..))
import           Test.Framework (testGroup)
import           Test.Framework.Providers.HUnit

errorLogger = Logger {
    log = \e msg -> case e of
      ERROR -> error msg
      _     -> return ()
  }

context :: IO ServiceContext
context = do
  container <- ioUserContainer
  interp <- createPersistInterpreter defaultConfig
  serviceContext container errorLogger interp

adminUserState = UserState {
    user = Username "admin"
  , page = P.home ()
  , name = "Admin"
  , role = E.Admin
  , token = "token"
  , timezone = utcZoneInfo
  , status = Nothing
  }

student = User {
    u_role = E.Student
  , u_username = (Username "student")
  , u_email = Email "student@university.com"
  , u_name = "Stu Dent"
  , u_timezone = utcZoneInfo
  , u_language = Language "hu"
  }

student2 = User {
    u_role = E.Student
  , u_username = (Username "student2")
  , u_email = Email "student@university.com"
  , u_name = "Stu Dent"
  , u_timezone = utcZoneInfo
  , u_language = Language "hu"
  }


adminUser = User {
    u_role = E.Admin
  , u_username = (Username "admin")
  , u_email = Email "admin@university.com"
  , u_name = "Admin"
  , u_timezone = utcZoneInfo
  , u_language = Language "hu"
  }

groupAdminUser = User {
    u_role = E.GroupAdmin
  , u_username = Username "groupadmin"
  , u_email = Email "groupadmin@university.com"
  , u_name = "Group Admin"
  , u_timezone = utcZoneInfo
  , u_language = Language "hu"
  }

-- * Test Tooles

runStory c u s = do
  e <- runUserStory c trans u s
  case e of
    Left ue -> error $ show ue
    Right a -> return a

assertUserState :: UserState -> User -> IO ()
assertUserState UserNotLoggedIn _ = error "User is not logged in"
assertUserState state usr = do
  assertBool "Invalid user is logged in" $ (user state) == (u_username usr)
  assertBool "Invalid person name: "     $ (name state) == (u_name usr)
  assertBool "Invalid role was loaded"   $ (role state) == (u_role usr)

-- * Tests

tests = testGroup "User Stories" [
    initPersist
  , register
  , loginAndLogout
  , courseTest
  , courseAndGroupAssignmentTest
  , saveAndLoadUserReg
  , cleanUpPersist
  ]

initPersist = testCase "Initalizing persistence layer" $ do
  init <- createPersistInit defaultConfig
  setUp <- PersistInit.isSetUp init
  when setUp $ PersistInit.tearDown init
  PersistInit.initPersist init
  setUp <- PersistInit.isSetUp init
  assertBool "Setting up persistence was failed" setUp

saveAndLoadUserReg = testCase "Save and load user reg data" $ do
  c <- context
  now <- getCurrentTime
  let u = UserRegistration "username" "e@e.com" "Family Name" "token" now
  (key,Registration) <- runStory c Registration $ U.createUserReg u
  (u', Registration)  <- runStory c Registration $ U.loadUserReg key
  assertBool "Saved and load user registration differs" (u' == u)

cleanUpPersist = testCase "Cleaning up persistence" $ do
  init <- createPersistInit defaultConfig
  PersistInit.tearDown init

register = testCase "User registration" $ do
  c <- context
  runStory c adminUserState $ createUser student
  return ()

loginAndLogout = testCase "Login And Logout" $ do
  c <- context
  (_,state) <- runStory c UserNotLoggedIn $ login (Username "student") "token"
  assertUserState state student
  (_,state) <- runStory c state $ logout
  case state of
    UserState {} -> error "User is remained logged in"
    UserNotLoggedIn -> return ()

courseTest = testCase "Create Course" $ do
  c <- context
  let r = E.Course {
      courseName = "Functional programming"
    , courseDesc = "Everything about FP"
    , courseTestScriptType = TestScriptSimple
    }
  (k,state) <- runStory c adminUserState $ createCourse r
  assertUserState state adminUser
  (ks,state) <- runStory c adminUserState $ selectCourses (\_ _ -> True)
  assertUserState state adminUser
  assertBool "Create course key is not found" (elem k $ map fst ks)
  ((r',_),state) <- runStory c adminUserState $ U.loadCourse k
  assertUserState state adminUser
  assertBool "Loaded course differs from the created one" (r' == r)
  return ()

courseAndGroupAssignmentTest = testCase "Course and group assignments" $ do
  c <- context
  str <- getCurrentTime
  end <- getCurrentTime
  let ca = Assignment "cname" "cexercise" emptyAspects str end binaryConfig
      ga = Assignment "gname" "gexercise" emptyAspects str end (percentageConfig 0.3)
      c1  = E.Course "FP" "FP-DESC" TestScriptSimple
      c2  = E.Course "MA" "MA-DESC" TestScriptZipped
      g1  = E.Group  "G1" "G1-DESC"
      g2  = E.Group  "G2" "G2-DESC"
      adminUsername = E.Username "admin"
      groupAdminUsr = E.Username "groupadmin"
  runStory c adminUserState $ createUser adminUser
  runStory c adminUserState $ createUser groupAdminUser
  runStory c adminUserState $ createUser student2
  (_,l) <- runStory c UserNotLoggedIn $ login adminUsername "token"
  ((ck1,ck2,gk1,gk2,a2),_) <- runStory c l $ do
    ck1 <- createCourse c1
    ck2 <- createCourse c2
    U.createCourseAdmin adminUsername ck1
    U.createCourseAdmin adminUsername ck2
    gk1 <- createGroup ck1 g1
    gk2 <- createGroup ck2 g2
    U.createGroupAdmin groupAdminUsr gk1
    U.createGroupAdmin groupAdminUsr gk2
    a2 <- createCourseAssignment ck2 ca NoCreation
    return (ck1,ck2,gk1,gk2,a2)
  (_,l) <- runStory c UserNotLoggedIn $ login groupAdminUsr "token"
  ((a1,as),_) <- runStory c l $ do
    a1 <- createGroupAssignment gk1 ga NoCreation
    subscribeToGroup gk1
    subscribeToGroup gk2
    as <- fmap (maybe [] id) userAssignments
    return (a1,as)
  let as' = map fst3 as
  assertBool "Assignment does not found in the assignment list" ([a1,a2] == as' || [a2,a1] == as')
  (_,ul) <- runStory c UserNotLoggedIn $ login (E.Username "student2") "token"
  ((uc,ug),_) <- runStory c ul $ do
    subscribeToGroup  gk2
    uc <- U.isUserInCourse ck2
    ug <- attendedGroups
    return (uc,ug)
  assertBool "User is not registered in course" (uc == True)
  assertBool "User is not registered in group" (elem gk2 (map fst3 ug))
  where
    fst3 (f,_,_) = f

-- * Helpers

fst3 :: (a,b,c) -> a
fst3 (a,_,_) = a
