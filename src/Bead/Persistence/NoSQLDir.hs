module Bead.Persistence.NoSQLDir (
    noSqlDirPersist
  ) where

import Bead.Domain.Types
import Bead.Domain.Entities
import Bead.Domain.Relationships
import Bead.Persistence.Persist
import Bead.Persistence.NoSQL.Loader
import Control.Monad.Transaction.TIO

import Control.Monad (join, mapM, liftM)
import Control.Exception (IOException, throwIO)
import System.FilePath (joinPath, takeBaseName)
import System.Directory (doesDirectoryExist, createDirectory)

-- | Simple directory and file based NoSQL persistence implementation
noSqlDirPersist = Persist {
    saveUser      = nSaveUser      -- :: User -> Password -> IO (Erroneous ())
  , doesUserExist = nDoesUserExist -- :: Username -> Password -> IO (Erroneous Bool)
  , personalInfo  = nPersonalInfo  -- :: Username -> Password -> IO (Erroneous (Role, String))
  , updatePwd     = nUpdatePwd     -- :: Username -> Password -> Password -> IO (Erroneous ())

  , saveCourse    = nSaveCourse    -- :: Course -> IO (Erroneous ())

  , saveGroup     = nSaveGroup     -- :: CourseKey -> Group -> IO (Erroneous GroupKey)

  , saveExercise  = nSaveExercise  -- :: Exercise -> IO (Erroneous ExerciseKey)

  , isPersistenceSetUp = nIsPersistenceSetUp
  , initPersistence    = nInitPersistence
  }

nIsPersistenceSetUp :: IO Bool
nIsPersistenceSetUp = do
  dirsExist <- mapM doesDirectoryExist persistenceDirs
  return $ and dirsExist

nInitPersistence :: IO ()
nInitPersistence = mapM_ createDirectory persistenceDirs

nSaveUser :: User -> Password -> IO (Erroneous ())
nSaveUser usr pwd = runAtomically $ do
  userExist <- isThereAUser (u_username usr)
  case userExist of
    True -> throwEx $ userError $ "The user already exists: " ++ show (u_username usr)
    False -> do
      let ePwd = encodePwd pwd
          dirname = dirName usr
      createDir dirname
      save     dirname (u_username usr)
      save     dirname (u_role     usr)
      save     dirname (u_email    usr)
      saveName dirname (u_name     usr)
      savePwd  dirname (          ePwd)

isThereAUser :: Username -> TIO Bool
isThereAUser uname = hasNoRollback $ do
  let dirname = dirName uname
  exist <- doesDirectoryExist dirname
  case exist of
    False -> return False
    True  -> isCorrectStructure dirname usersStructure

nDoesUserExist :: Username -> Password -> IO (Erroneous Bool)
nDoesUserExist u p = runAtomically $ tDoesUserExist u p

tDoesUserExist :: Username -> Password -> TIO Bool
tDoesUserExist uname pwd = do
  let dirname = dirName uname
      ePwd = encodePwd pwd
  exists <- hasNoRollback . doesDirectoryExist $ dirname
  case exists of
    False -> return False
    True  -> do
      ePwd' <- loadPwd dirname
      return (ePwd == ePwd')

nPersonalInfo :: Username -> Password -> IO (Erroneous (Role, String))
nPersonalInfo uname pwd = runAtomically $ do
  userExist <- isThereAUser uname
  case userExist of
    False -> throwEx . userError $ "User doesn't already exist: " ++ show uname
    True -> do
      let ePwd = encodePwd pwd
          dirname = dirName uname
      role       <- load dirname
      familyName <- loadName dirname
      return (role, familyName)

nUpdatePwd :: Username -> Password -> Password -> IO (Erroneous ())
nUpdatePwd uname oldPwd newPwd = runAtomically $ do
  userExist <- tDoesUserExist uname oldPwd
  case userExist of
    False -> throwEx $ userError $ "Invalid user and/or password combination: " ++ show uname
    True -> do
      let ePwd = encodePwd oldPwd
          dirname = dirName uname
      oldEPwd <- loadPwd dirname
      case ePwd == oldEPwd of
        False -> throwEx . userError $ "Invalid password"
        True  -> savePwd dirname $ encodePwd newPwd

nSaveCourse :: Course -> IO (Erroneous CourseKey)
nSaveCourse c = runAtomically $ do
  let courseDir = dirName c
      courseKey = keyString c
  -- TODO: Check if file exists with a same name
  exist <- hasNoRollback $ doesDirectoryExist courseDir
  case exist of
    -- ERROR: Course already exists on the disk
    True -> throwEx $ userError $ join [
                "Course already exist: "
              , courseName c
              , " (", show $ courseCode c, ")"
              ]
    -- New course
    False -> do
      -- TODO: Check errors creating dirs and files
      -- No space left, etc...
      createDir courseDir
      createDir $ joinPath [courseDir, "groups"]
      createDir $ joinPath [courseDir, "exams"]
      createDir $ joinPath [courseDir, "exams", "groups"]
      saveCourseDesc courseDir
      return . CourseKey $ courseKey
  where
    saveCourseDesc :: FilePath -> TIO ()
    saveCourseDesc courseDir = do
      save     courseDir (courseCode c)
      saveDesc courseDir (courseDesc c)
      saveName courseDir (courseName c)

registerInGroup :: Username -> GroupKey -> TIO ()
registerInGroup uname gk = do
  let userDir = dirName uname
  exist <- hasNoRollback $ doesDirectoryExist userDir
  case exist of
    False -> throwEx $ userError $ join [show uname, " does not exist."]
    True  -> saveString userDir (fileName gk) "Registered"

nSaveGroup :: CourseKey -> Group -> IO (Erroneous GroupKey)
nSaveGroup ck g = runAtomically $ do
  let courseDir   = dirName ck
      groupKeyStr = keyString g
      groupDir    = joinPath [courseDir, "groups", groupKeyStr]
      groupKey    = GroupKey ck groupKeyStr
  exist <- hasNoRollback $ doesDirectoryExist groupDir
  case exist of
    True -> throwEx $ userError $ join ["Group ",groupName g," is already stored"]
    False -> do
      createDir     groupDir
      saveGroupDesc groupDir groupKey
      return groupKey
  where
    saveGroupDesc :: FilePath -> GroupKey -> TIO ()
    saveGroupDesc groupDir gk = do
      saveName groupDir (groupName g)
      saveDesc groupDir (groupDesc g)
      saveString groupDir "users" $ unlines $ map str $ groupUsers g
      mapM_ (flip registerInGroup gk) $ groupUsers g

--  We define locally the transactional file creation steps, in further version
-- this will be refactored to a common module

nSaveExercise :: Exercise -> IO (Erroneous ExerciseKey)
nSaveExercise exercise = runAtomically $ do
  dirName <- createTmpDir (joinPath [dataDir, exerciseDir]) "ex"
  let exerciseKey = takeBaseName dirName
  save dirName exercise
  return . ExerciseKey $ exerciseKey

-- * Tools

nError :: String -> Erroneous a
nError = Left

encodePwd :: String -> String
encodePwd = ordEncode

saveName dirName = saveString dirName "name"
loadName dirName = loadString dirName "name"

saveDesc dirName = saveString dirName "description"
loadDesc dirName = loadString dirName "description"

savePwd dirName = saveString dirName "password"
loadPwd dirName = loadString dirName "password"

reason :: Either IOException a -> Either String a
reason (Left e)  = Left $ show e
reason (Right x) = Right x

-- | Run a TIO transaction and convert the exception to a String message
runAtomically :: TIO a -> IO (Erroneous a)
runAtomically = liftM reason . atomically
