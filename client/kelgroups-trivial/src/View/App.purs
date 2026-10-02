-- | A read-only group viewer: a group id is synced against the server
-- | the page came from (`KelGroups.Client.Sync`); the view shows the head,
-- | the roster and the chain, or the refusal (a gap names the missing
-- | digest). It holds no key and signs nothing.
module View.App (appComponent) where

import Prelude

import Data.Array as Array
import Data.Either (Either(..))
import Data.Maybe (Maybe(..))
import Data.String as String
import Effect.Aff.Class (class MonadAff, liftAff)
import Halogen as H
import Halogen.HTML as HH
import Halogen.HTML.Events as HE
import Halogen.HTML.Properties as HP
import KelGroups.Client.Api (httpTransport)
import KelGroups.Client.Group (GroupView, viewRecord, Payload(..), Roster(..))
import KelGroups.Client.Kel (SyncRefusal(..))
import KelGroups.Client.Sync (sync)

data Status
  = Idle
  | Syncing
  | Synced GroupView
  | Refused SyncRefusal

type State = { group :: String, status :: Status }

data Action
  = SetGroup String
  | Sync

appComponent :: forall q i o m. MonadAff m => H.Component q i o m
appComponent = H.mkComponent
  { initialState: const { group: "", status: Idle }
  , render
  , eval: H.mkEval H.defaultEval { handleAction = handleAction }
  }

handleAction :: forall o m. MonadAff m => Action -> H.HalogenM State Action () o m Unit
handleAction = case _ of
  SetGroup g -> H.modify_ _ { group = String.trim g }
  Sync -> do
    st <- H.get
    previous <- pure case st.status of
      Synced v | sameGroup st.group v -> Just v
      _ -> Nothing
    H.modify_ _ { status = Syncing }
    r <- liftAff (sync (httpTransport "") st.group previous)
    H.modify_ _ { status = either' Refused Synced r }
  where
  sameGroup g v = (viewRecord v).group == g
  either' f s = case _ of
    Left e -> f e
    Right v -> s v

render :: forall m. State -> H.ComponentHTML Action () m
render st = HH.div [ HP.class_ (HH.ClassName "app") ]
  [ HH.div [ HP.class_ (HH.ClassName "header") ] [ HH.h1_ [ HH.text "kelgroups" ] ]
  , HH.div [ HP.class_ (HH.ClassName "form") ]
      [ HH.input
          [ HP.placeholder "group id"
          , HP.value st.group
          , HE.onValueInput SetGroup
          ]
      , HH.button
          [ HE.onClick (const Sync), HP.disabled (st.group == "") ]
          [ HH.text "Sync" ]
      ]
  , case st.status of
      Idle -> HH.text ""
      Syncing -> HH.p_ [ HH.text "Syncing…" ]
      Refused r -> HH.div [ HP.class_ (HH.ClassName "error-bar") ] [ HH.text (refusal r) ]
      Synced v -> view v
  ]

view :: forall w i. GroupView -> HH.HTML w i
view gv =
  let
    v = viewRecord gv
    Roster r = v.roster
    role m = if Array.elem m r.admins then " (admin)" else ""
  in
    HH.div [ HP.class_ (HH.ClassName "members") ]
      [ HH.p_ [ HH.text ("Head: " <> v.head) ]
      , HH.h2_ [ HH.text "Members" ]
      , HH.ul_ (map (\m -> HH.li_ [ HH.text (m <> role m) ]) r.members)
      , HH.h2_ [ HH.text ("Chain (" <> show (Array.length v.chain) <> " actions)") ]
      , HH.ol_ (map (\a -> HH.li_ [ HH.text (a.signer <> ": " <> payload a.payload) ]) v.chain)
      ]

payload :: Payload -> String
payload = case _ of
  Genesis -> "genesis"
  Add x -> "add " <> x
  Remove x -> "remove " <> x
  Grant x -> "grant " <> x
  Revoke x -> "revoke " <> x
  Leave -> "leave"
  App _ -> "app"

refusal :: SyncRefusal -> String
refusal = case _ of
  KelInvalid k -> "Invalid KEL " <> k.prefix <> " at s " <> show k.s <> ": " <> k.reason
  Gap g -> "Gap: missing " <> g.missing
  NotOnLine n -> "Not on the line: " <> n.digest
  RuleViolation r -> "Rule violation at " <> r.digest <> ": " <> r.class
  HistoryRewritten h -> "History rewritten: " <> h.prefix <> " at s " <> show h.s
  NotSigner n -> "Not a signer: " <> n.prefix
  Transport t -> "Server answered " <> show t.status <> ": " <> t.detail
