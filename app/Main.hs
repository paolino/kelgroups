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
import KelGroups.Server (ServerEnv (..), mkApp)
import KelGroups.Store (closeKEL, openKEL)
import KelGroups.Store.Serialise ()
import KelGroups.Trivial
    ( trivialConfig
    , trivialFold
    , trivialInitial
    )
import Network.Wai.Handler.Warp qualified as Warp
import System.Environment (getArgs)

main :: IO ()
main = do
    args <- getArgs
    case args of
        [portStr, dbPath, pass] ->
            let port = read portStr
            in  runServer port dbPath (pack pass)
        _ -> do
            putStrLn
                "Usage: kelgroups-server <port> <db> <pass>"

runServer :: Int -> FilePath -> Text -> IO ()
runServer port dbPath passphrase =
    bracket
        (openKEL trivialFold trivialInitial dbPath)
        closeKEL
        $ \store -> do
            ch <- newBroadcastTChanIO
            let env =
                    ServerEnv
                        { envStore = store
                        , envConfig = trivialConfig
                        , envAppFold = trivialFold
                        , envPassphrase = passphrase
                        , envBroadcast = ch
                        }
            putStrLn $
                "Listening on port " <> show port
            Warp.run port (mkApp env)
