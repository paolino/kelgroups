{- |
Module      : ServerIdentitySpec
Description : The server holds no key; the old group path runs without one
Copyright   : (c) 2026 Paolo Veronelli
License     : Apache-2.0

The server has no identity of its own: a fresh database holds
no key table and no row, @/info@ names no server key, and the
executable has no key commands. The old group path's first
stored event is the first member submission.
-}
module ServerIdentitySpec (spec) where

import Control.Exception (bracket)
import Data.Aeson (Value (..), decode)
import Data.Aeson.Key qualified as K
import Data.Aeson.KeyMap qualified as KM
import Data.ByteArray.Encoding (Base (..), convertToBase)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Char (toLower)
import Data.List (isInfixOf)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Database.SQLite.Simple qualified as SQL
import KelGroups.Kel.Store (openMemberKels)
import KelGroups.Store (KELStore (..), closeKEL, openKEL)
import KelGroups.Trivial (trivialFold, trivialInitial)
import Keri.Crypto.Ed25519 qualified as Ed25519
import MemberKelStoreSpec (dumpTables, tableNames, withDb)
import Network.HTTP.Client qualified as HC
import Network.HTTP.Types (status200)
import System.Exit (ExitCode)
import System.IO (hClose)
import System.IO.Temp (withSystemTempFile)
import System.Process (readProcessWithExitCode)
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)
import TestHelpers
    ( TestId (..)
    , bootstrap
    , httpGet
    , newTestId
    , postEvent
    , withTestEnv
    )

-- | Tables whose name speaks of a key or an identity.
keyish :: T.Text -> Bool
keyish n =
    let l = T.toLower n
    in  any (`T.isInfixOf` l) ["key", "identity", "secret"]

-- | An Ed25519 private-key JWK (RFC 8037), unpadded base64url.
jwkOf :: Ed25519.KeyPair -> ByteString
jwkOf kp =
    "{\"kty\":\"OKP\",\"crv\":\"Ed25519\",\"x\":\""
        <> b64 (Ed25519.publicKeyBytes (Ed25519.publicKey kp))
        <> "\",\"d\":\""
        <> b64 (Ed25519.secretKeyBytes (Ed25519.secretKey kp))
        <> "\"}"
  where
    b64 :: ByteString -> ByteString
    b64 = convertToBase Base64URLUnpadded

server :: [String] -> IO (ExitCode, String)
server args = do
    (code, out, err) <- readProcessWithExitCode "kelgroups-server" args ""
    pure (code, out <> err)

spec :: Spec
spec = describe "no server identity" $ do
    it
        "INV-38-NO-SERVER-KEY/store: a freshly opened database has no \
        \key table and no row"
        $ withDb
        $ \path ->
            bracket (openKEL trivialFold trivialInitial path) closeKEL $
                \store -> do
                    let conn = storeConn store
                        noKeyNoRow = do
                            names <- tableNames conn
                            rows <- dumpTables conn
                            names `shouldSatisfy` (not . null)
                            filter keyish names `shouldBe` []
                            [(n, length rs) | (n, rs) <- rows, not (null rs)]
                                `shouldBe` []
                    noKeyNoRow
                    _ <- openMemberKels conn
                    noKeyNoRow

    it "INV-38-NO-SERVER-KEY/http: /info names no server key" $
        withTestEnv $ \te -> do
            resp <- httpGet te "/info?key=anyone"
            HC.responseStatus resp `shouldBe` status200
            case decode (HC.responseBody resp) of
                Just (Object o) -> do
                    KM.member "publicAdminEmails" o `shouldBe` True
                    filter keyish (map K.toText (KM.keys o)) `shouldBe` []
                other -> fail ("not a JSON object: " <> show other)

    it
        "INV-38-NO-SERVER-KEY/cli: the executable has no key export or \
        \import command and writes no key"
        $ withDb
        $ \path -> withSystemTempFile "server.jwk" $ \jwk h -> do
            kp <- Ed25519.generateKeyPair
            BS.hPut h (jwkOf kp)
            hClose h
            (_, exported) <- server ["export-key", path]
            (_, imported) <- server ["import-key", path, jwk]
            exported `shouldSatisfy` (not . ("kty" `isInfixOf`))
            map toLower exported `shouldSatisfy` ("usage" `isInfixOf`)
            map toLower imported `shouldSatisfy` ("usage" `isInfixOf`)
            names <-
                bracket (SQL.open path) SQL.close tableNames
            filter keyish names `shouldBe` []

    it
        "INV-38-OLD-PATH: the first member submission is the group \
        \KEL's first event"
        $ withTestEnv
        $ \te -> do
            admin <- newTestId
            sn <- postEvent te (bootstrap admin)
            sn `shouldBe` 1
            resp <-
                httpGet te $
                    "/events?after=0&key=" <> T.unpack (tidKey admin)
            HC.responseStatus resp `shouldBe` status200
            case decode (HC.responseBody resp) of
                Just (Object o) -> do
                    KM.lookup "signer" o `shouldBe` Just (String (tidKey admin))
                    case KM.lookup "event" o of
                        Just (String evtText) ->
                            case decode (LBS.fromStrict (TE.encodeUtf8 evtText)) of
                                Just (Object e) -> do
                                    KM.lookup "t" e `shouldBe` Just (String "icp")
                                    KM.lookup "k" e
                                        `shouldBe` Just (Array (pure (String (tidKey admin))))
                                other -> fail ("event not an object: " <> show other)
                        other -> fail ("no event text: " <> show other)
                other -> fail ("not a JSON object: " <> show other)
