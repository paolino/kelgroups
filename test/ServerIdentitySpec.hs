{- |
Module      : ServerIdentitySpec
Description : The server holds no key
Copyright   : (c) 2026 Paolo Veronelli
License     : Apache-2.0

The server has no identity of its own: a fresh database holds
no key table and no row, and the executable has no key commands.
-}
module ServerIdentitySpec (spec) where

import Control.Exception (bracket)
import Data.ByteArray.Encoding (Base (..), convertToBase)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Char (toLower)
import Data.List (isInfixOf)
import Data.Text qualified as T
import Database.SQLite.Simple qualified as SQL
import Keri.Crypto.Ed25519 qualified as Ed25519
import MemberKelStoreSpec (dumpTables, tableNames, withDb, withKels)
import System.Exit (ExitCode)
import System.IO (hClose)
import System.IO.Temp (withSystemTempFile)
import System.Process (readProcessWithExitCode)
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)

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
        $ \path -> withKels path $ \_ -> SQL.withConnection path $ \conn -> do
            names <- tableNames conn
            rows <- dumpTables conn
            names `shouldSatisfy` (not . null)
            filter keyish names `shouldBe` []
            [(n, length rs) | (n, rs) <- rows, not (null rs)] `shouldBe` []

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
