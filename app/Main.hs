{- |
Module      : Main
Description : kelgroups-server executable
Copyright   : (c) 2026 Paolo Veronelli
License     : Apache-2.0

Serves the member KEL endpoints and group action admission of
"KelGroups.Server" over the member KEL store of one database
file, with the static files of the client as the fallback.
-}
module Main (main) where

import Control.Exception (bracket)
import KelGroups.Kel.Store (closeMemberKels, openMemberKels)
import KelGroups.Server (kelApp)
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
        , "  kelgroups-server <port> <db>"
        ]

main :: IO ()
main = do
    args <- getArgs
    case args of
        [portStr, dbPath]
            | Just port <- readMaybe portStr ->
                runServer port dbPath
        _ -> putStr usage

runServer :: Int -> FilePath -> IO ()
runServer port dbPath =
    bracket (openMemberKels dbPath) closeMemberKels $ \kels -> do
        let fallback =
                staticApp $
                    defaultFileServerSettings "client/kelgroups-trivial/dist"
        putStrLn $ "Listening on port " <> show port
        Warp.run port (kelApp kels (Just fallback))
