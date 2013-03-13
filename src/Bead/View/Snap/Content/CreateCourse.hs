{-# LANGUAGE OverloadedStrings #-}
module Bead.View.Snap.Content.CreateCourse (
    createCourse
  ) where

import Bead.View.Snap.Content
import qualified Bead.View.UserActions as UA
import qualified Bead.Controller.Pages as P (Page(CreateCourse))


import Text.Blaze.Html5 ((!))
import qualified Text.Blaze.Html5 as H
import qualified Text.Blaze.Html5.Attributes as A

createCourse :: Content
createCourse = getPostContentHandler createPage submitCourse

createPage :: GETContentHandler
createPage = withUserStateAndFrame . const $ do
  H.form ! A.method "post" ! A.action (routeOf P.CreateCourse) $ do
    "Create a new course"
    H.table ! A.id "create-course" $ do
      mapM_ field [
          ("Course Code", fieldName courseCodeField)
        , ("Course Name", fieldName courseNameField)
        , ("Course Desc", fieldName courseDescField)
        ]
    H.input ! A.type_ "submit"
  where
    field (text, name) = do
      H.tr $ do
        H.td text
        H.td $ H.textarea ! A.name name ! A.cols "10" ! A.rows "1" $ empty


submitCourse :: POSTContentHandler
submitCourse = do
  courseCodeText <- getParamE (fieldName courseCodeField) CourseCode "Course code is not found"
  courseNameText <- getParamE (fieldName courseNameField) id "Course name is not found"
  courseDescText <- getParamE (fieldName courseDescField) id "Course description is not found"
  return . UA.CreateCourse $ Course {
      courseCode = courseCodeText
    , courseName = courseNameText
    , courseDesc = courseDescText
    }