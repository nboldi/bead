{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE CPP #-}
module Bead.View.EmailTemplate
  ( EmailTemplate
  , emailTemplate
  , runEmailTemplate
  , RegTemplate(..)
  , ForgottenPassword(..)
  , Template
  , registration
  , forgottenPassword
#ifdef TEST
  , runEmailTemplateTests
#endif
  ) where

import Data.Data
import qualified Data.Text.Lazy as DTL
import Text.Hastache
import Text.Hastache.Context

#ifdef TEST
import Test.Tasty.TestSet
import Test.Tasty.HUnit as HUnit
#endif


-- Email template is a function to an IO String computation
-- Interpretation: The email template is applied to a value
-- and produces a string value with the field filled up
-- the values from the given type.
newtype EmailTemplate a = EmailTemplate (a -> IO String)

emailTemplateCata :: ((a -> IO String) -> b) -> EmailTemplate a -> b
emailTemplateCata f (EmailTemplate g) = f g

emailTemplateAna :: (b -> (a -> IO String)) -> b -> EmailTemplate a
emailTemplateAna f x = EmailTemplate (f x)

-- | Produces a IO String computation, that represents the
-- evaluated template substituting the given value into the
-- template
runEmailTemplate :: EmailTemplate a -> a -> IO String
runEmailTemplate template v = emailTemplateCata id template v

-- Creates a simple email template using the given string
emailTemplate :: (Data a, Typeable a) => String -> EmailTemplate a
emailTemplate = emailTemplateAna
  (\t x -> fmap DTL.unpack $ hastacheStr defaultConfig (encodeStr t) (mkGenericContext x))

-- * Templates

data RegTemplate = RegTemplate {
    regUsername :: String
  , regUrl      :: String
  } deriving (Data, Typeable)

data ForgottenPassword = ForgottenPassword {
    fpUsername    :: String
  , fpNewPassword :: String
  } deriving (Data, Typeable)

class (Data t, Typeable t) => Template t

instance Template RegTemplate
instance Template ForgottenPassword

fileTemplate :: (Data a, Typeable a) => FilePath -> IO (EmailTemplate a)
fileTemplate fp = do
  content <- readFile fp
  return $ emailTemplate content

registration :: FilePath -> IO (EmailTemplate RegTemplate)
registration = fileTemplate

forgottenPassword :: FilePath -> IO (EmailTemplate ForgottenPassword)
forgottenPassword = fileTemplate

#ifdef TEST

runEmailTemplateTests = group "runEmailTemplate" $ do
  add $ HUnit.testCase "Registration template" $ do
    found <- runEmailTemplate (emailTemplate "n {{regUsername}} u {{regUrl}}") (RegTemplate "n" "u")
    HUnit.assertEqual "Registration template" "n n u u" found
  add $ HUnit.testCase "Forgotten password" $ do
    found <- runEmailTemplate (emailTemplate "n {{fpUsername}} p {{fpNewPassword}}") (ForgottenPassword "n" "p")
    HUnit.assertEqual "Forgotten password template" "n n p p" found

#endif
