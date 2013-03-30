{-# LANGUAGE OverloadedStrings #-}
module Bead.View.Snap.Content.Administration (
    administration
  , assignCourseAdmin
  ) where

import Control.Monad (liftM)

import Bead.Domain.Entities (User(..), Role(..))
import Bead.Controller.Pages as P (Page(CreateCourse, UserDetails, AssignCourseAdmin))
import Bead.Controller.ServiceContext (UserState(..))
import Bead.Controller.UserStories (selectCourses, selectUsers)
import Bead.View.Snap.Pagelets
import Bead.View.Snap.Content
import qualified Bead.View.UserActions as UA (UserAction(..))

import Text.Blaze.Html5 (Html)
import qualified Text.Blaze.Html5 as H

administration :: Content
administration = getContentHandler administrationPage

data PageInfo = PageInfo {
    courses      :: [(CourseKey, Course)]
  , admins       :: [User]
  , courseAdmins :: [User]
  }

administrationPage :: GETContentHandler
administrationPage = withUserStateE $ \s -> do
  cs <- runStoryE (selectCourses each)
  ausers <- runStoryE (selectUsers adminOrCourseAdmin)
  let info = PageInfo {
      courses = cs
    , admins = filter admin ausers
    , courseAdmins = filter courseAdmin ausers
    }
  blaze $ withUserFrame s (administrationContent info) Nothing
  where
    each _ _ = True

    adminOrCourseAdmin u =
      case u_role u of
        Admin -> True
        CourseAdmin -> True
        _ -> False

    admin = (Admin ==) . u_role
    courseAdmin = (CourseAdmin ==) . u_role

administrationContent :: PageInfo -> Html
administrationContent info = do
  H.p $ "New Course"
  H.p $ postForm (routeOf P.CreateCourse) $ do
          inputPagelet emptyCourse
          submitButton "Create Course"
  H.p $ "Add course admin to the course"
  H.p $ postForm (routeOf P.AssignCourseAdmin) $ do
          valueTextSelection (fieldName selectedCourse) (courses info)
          valueTextSelection (fieldName selectedCourseAdmin) (courseAdmins info)
          submitButton "Assign"
  H.p $ valueTextSelection "course-selection" (courses info)
  H.p $ "Modify user's account"
  H.p $ getForm (routeOf P.UserDetails) $ do
          inputPagelet emptyUsername
          submitButton "Select"
  H.p $ "Admin list / Add new admin"
  H.p $ valueTextSelection "admin-selection" (admins info)
  H.p $ "Change password for a given user"

-- Add Course Admin

assignCourseAdmin :: Content
assignCourseAdmin = postContentHandler submitCourse

submitCourse :: POSTContentHandler
submitCourse = do
  username  <- getParamE (fieldName selectedCourseAdmin) Username "Selected course admin parameter was not found"
  courseKey <- getParamE (fieldName selectedCourse) CourseKey "Selected course was not found"
  return $ UA.CreateCourseAdmin username courseKey