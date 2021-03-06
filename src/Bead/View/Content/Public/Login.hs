{-# LANGUAGE CPP #-}
{-# LANGUAGE OverloadedStrings  #-}
module Bead.View.Content.Public.Login (
    login
  ) where

import           Data.String (fromString)
import           Control.Monad

import           Snap.Snaplet.Auth
import           Text.Blaze.Html5
import           Text.Blaze.Html5.Attributes

import qualified Bead.Controller.Pages as Pages
import           Bead.View.Dictionary
import           Bead.View.Content hiding (BlazeTemplate, template)
import qualified Bead.View.Content.Bootstrap as Bootstrap
import           Bead.View.RouteOf


login :: Maybe AuthFailure -> DictionaryInfos -> IHtml
login err langInfos = do
  msg <- getI18N
  return $ do
    Bootstrap.rowCol4Offset4 $ postForm (routeOf login) $ do
      Bootstrap.textInput     (fieldName loginUsername) (msg $ msg_Login_Username "Username:") ""
      Bootstrap.passwordInput (fieldName loginPassword) (msg $ msg_Login_Password "Password:")
      Bootstrap.submitButton  (fieldName loginSubmitBtn) (msg $ msg_Login_Submit "Login")
    maybe mempty (Bootstrap.rowCol4Offset4 . (p ! class_ "text-center bg-danger") . fromString . show) err
#ifndef LDAPEnabled
    -- Registration and password reset is not available for LDAP as LDAP handles these functionality
    Bootstrap.rowCol4Offset4 $ Bootstrap.buttonGroupJustified $ do
      Bootstrap.buttonLink "/reg_request" (msg $ msg_Login_Registration "Registration")
      Bootstrap.buttonLink "/reset_pwd"   (msg $ msg_Login_Forgotten_Password "Forgotten password")
#endif
    when (length langInfos > 1) $ do
      Bootstrap.rowCol4Offset4 $ Bootstrap.buttonGroupJustified $
        Bootstrap.dropdown (msg $ msg_Login_SelectLanguage "Select a language") $
        for langInfos $ \(language,info) -> do
          link (queryString changeLanguagePath [requestParam language])
               (dictionaryInfoCata (\_icon -> fromString) info)
#ifdef LDAPEnabled
    Bootstrap.rowCol4Offset4 $ do
      hr
      p $ fromString $
        msg $ msg_Login_UsernameHint "The web site can only be used with an Active Directory account."
#endif
  where
    login = Pages.login ()
    for = flip Prelude.map
    link ref text = a ! href ref $ text
