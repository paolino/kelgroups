{- |
Module      : Main
Description : kelgroups-server executable
Copyright   : (c) 2026 Paolo Veronelli
License     : Apache-2.0
-}
module Main (main) where

import Control.Concurrent.STM (newBroadcastTChanIO)
import Control.Exception (bracket)
import Data.Text (Text, pack)
import KelGroups.Kel.Store (openMemberKels)
import KelGroups.Server (ServerEnv (..), kelApp, mkApp)
import KelGroups.Store
    ( closeKEL
    , openKEL
    , storeConn
    )
import KelGroups.Trivial
    ( trivialConfig
    , trivialFold
    , trivialInitial
    )
import Network.Wai.Application.Static
    ( defaultFileServerSettings
    , staticApp
    )
import Network.Wai.Handler.Warp qualified as Warp
import System.Environment (getArgs)
import Text.Read (readMaybe)

usage :: String
usage =
    unlines
        [ "Usage:"
        , "  kelgroups-server <port> <db> <pass>"
        ]

main :: IO ()
main = do
    args <- getArgs
    case args of
        [portStr, dbPath, pass]
            | Just port <- readMaybe portStr ->
                runServer port dbPath (pack pass)
        _ -> putStr usage

runServer :: Int -> FilePath -> Text -> IO ()
runServer port dbPath passphrase =
    bracket
        (openKEL trivialFold trivialInitial dbPath)
        closeKEL
        $ \store -> do
            kels <- openMemberKels (storeConn store)
            ch <- newBroadcastTChanIO
            let env =
                    ServerEnv
                        { envStore = store
                        , envConfig = trivialConfig
                        , envAppFold = trivialFold
                        , envPassphrase = passphrase
                        , envBroadcast = ch
                        }
                staticDir =
                    "client/kelgroups-trivial/dist"
                fallback =
                    staticApp
                        (defaultFileServerSettings staticDir)
                app = mkApp env (Just (kelApp kels (Just fallback)))
            putStrLn $
                "Listening on port " <> show port
            Warp.run port app
