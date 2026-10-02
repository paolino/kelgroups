-- | The HTTP transport of the client: `GET /groups/<gid>`,
-- | `GET /kel/<prefix>[?after=<sn>]` and `POST /actions` against a server
-- | base URL (empty for the page's own origin).
module KelGroups.Client.Api
  ( httpTransport
  ) where

import Prelude

import Data.Maybe (Maybe(..))
import FFI.Fetch as Fetch
import KelGroups.Client.Sync (Transport)

-- | The transport over `fetch` to a server at `base`.
httpTransport :: String -> Transport
httpTransport base =
  { getIndex: \g -> get ("/groups/" <> g)
  , getKel: \prefix after -> get ("/kel/" <> prefix <> query after)
  , postAction: \body -> Fetch.fetch (base <> "/actions") { method: "POST", body }
  }
  where
  get path = Fetch.fetch (base <> path) { method: "GET", body: "" }
  query = case _ of
    Just sn -> "?after=" <> show sn
    Nothing -> ""
