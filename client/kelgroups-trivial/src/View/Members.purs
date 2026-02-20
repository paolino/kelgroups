module View.Members
  ( membersComponent
  , Output(..)
  , Input
  ) where

import Prelude

import Data.Array (fromFoldable)
import Data.Map as Map
import Data.Maybe (Maybe(..))
import Data.Set as Set
import Data.String as String
import Data.Tuple (Tuple(..))
import Effect.Aff.Class (class MonadAff)
import Halogen as H
import Halogen.HTML as HH
import Halogen.HTML.Events as HE
import Halogen.HTML.Properties as HP
import KelGroups.Client.Event (Proposal(..))
import KelGroups.Client.State (GroupState, isAdmin)
import KelGroups.Client.Types (Member, Role(..))

data Output = SubmitPropose Proposal

type Input =
  { groupState :: GroupState Unit
  , myKey :: Maybe String
  }

type State =
  { groupState :: GroupState Unit
  , myKey :: Maybe String
  , newMemberKey :: String
  , newMemberAdmin :: Boolean
  , changingRolesFor :: Maybe String
  }

data Action
  = Receive Input
  | SetNewMemberKey String
  | ToggleNewMemberAdmin
  | DoIntroduce
  | DoRemove String
  | StartChangeRoles String
  | DoChangeRoles String Boolean

membersComponent
  :: forall q m. MonadAff m => H.Component q Input Output m
membersComponent = H.mkComponent
  { initialState
  , render
  , eval: H.mkEval H.defaultEval
      { handleAction = handleAction
      , receive = Just <<< Receive
      }
  }

initialState :: Input -> State
initialState input =
  { groupState: input.groupState
  , myKey: input.myKey
  , newMemberKey: ""
  , newMemberAdmin: false
  , changingRolesFor: Nothing
  }

render :: forall m. State -> H.ComponentHTML Action () m
render st = HH.div [ HP.class_ (HH.ClassName "members") ]
  [ HH.h2_ [ HH.text "Members" ]
  , memberTable st
  , introduceForm st
  ]

memberTable :: forall m. State -> H.ComponentHTML Action () m
memberTable st =
  let
    entries = fromFoldable (Map.toUnfoldable st.groupState.members :: Array (Tuple String Member))
    amIAdmin = case st.myKey of
      Nothing -> false
      Just k -> isAdmin k st.groupState
  in
    HH.table [ HP.class_ (HH.ClassName "member-table") ]
      [ HH.thead_
          [ HH.tr_
              [ HH.th_ [ HH.text "Key" ]
              , HH.th_ [ HH.text "Roles" ]
              , if amIAdmin then HH.th_ [ HH.text "Actions" ]
                else HH.text ""
              ]
          ]
      , HH.tbody_ (map (memberRow amIAdmin) entries)
      ]

memberRow :: forall m. Boolean -> Tuple String Member -> H.ComponentHTML Action () m
memberRow amIAdmin (Tuple key member) =
  HH.tr_
    [ HH.td [ HP.class_ (HH.ClassName "key") ]
        [ HH.text (truncateKey key) ]
    , HH.td_
        [ HH.text (showRoles member.roles) ]
    , if amIAdmin then HH.td_
        [ HH.button
            [ HE.onClick (const (DoRemove key))
            , HP.class_ (HH.ClassName "btn-danger")
            ]
            [ HH.text "Remove" ]
        ]
      else HH.text ""
    ]

introduceForm :: forall m. State -> H.ComponentHTML Action () m
introduceForm st =
  HH.div [ HP.class_ (HH.ClassName "form introduce-form") ]
    [ HH.h3_ [ HH.text "Introduce Member" ]
    , HH.input
        [ HP.placeholder "CESR public key"
        , HP.value st.newMemberKey
        , HE.onValueInput SetNewMemberKey
        ]
    , HH.label_
        [ HH.input
            [ HP.type_ HP.InputCheckbox
            , HP.checked st.newMemberAdmin
            , HE.onChecked (const ToggleNewMemberAdmin)
            ]
        , HH.text " Admin"
        ]
    , HH.button
        [ HE.onClick (const DoIntroduce)
        , HP.class_ (HH.ClassName "btn-primary")
        ]
        [ HH.text "Propose Introduction" ]
    ]

handleAction
  :: forall m
   . MonadAff m
  => Action
  -> H.HalogenM State Action () Output m Unit
handleAction = case _ of
  Receive input ->
    H.modify_ _
      { groupState = input.groupState
      , myKey = input.myKey
      }

  SetNewMemberKey s ->
    H.modify_ _ { newMemberKey = s }

  ToggleNewMemberAdmin ->
    H.modify_ \s -> s { newMemberAdmin = not s.newMemberAdmin }

  DoIntroduce -> do
    st <- H.get
    when (st.newMemberKey /= "") do
      let
        roles =
          if st.newMemberAdmin then Set.singleton Admin
          else Set.empty
      H.raise (SubmitPropose (IntroduceMember st.newMemberKey roles))
      H.modify_ _ { newMemberKey = "", newMemberAdmin = false }

  DoRemove key ->
    H.raise (SubmitPropose (RemoveMember key))

  StartChangeRoles key ->
    H.modify_ _ { changingRolesFor = Just key }

  DoChangeRoles key makeAdmin -> do
    let
      roles =
        if makeAdmin then Set.singleton Admin
        else Set.empty
    H.raise (SubmitPropose (ChangeRoles key roles))
    H.modify_ _ { changingRolesFor = Nothing }

-- Helpers

truncateKey :: String -> String
truncateKey s =
  if String.length s > 12 then String.take 12 s <> "..."
  else s

showRoles :: Set.Set Role -> String
showRoles roles =
  let
    arr = fromFoldable roles
  in
    String.joinWith ", " (map showRole arr)
  where
  showRole Admin = "Admin"
  showRole (AppRole name) = name
