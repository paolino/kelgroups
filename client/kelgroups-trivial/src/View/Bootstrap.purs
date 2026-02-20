module View.Bootstrap
  ( bootstrapComponent
  , Output(..)
  ) where

import Prelude

import Effect.Aff.Class (class MonadAff)
import Halogen as H
import Halogen.HTML as HH
import Halogen.HTML.Events as HE
import Halogen.HTML.Properties as HP

data Output = Submit String String

type State =
  { passphrase :: String
  , adminKey :: String
  }

data Action
  = SetPassphrase String
  | SetAdminKey String
  | DoSubmit

bootstrapComponent
  :: forall q m. MonadAff m => H.Component q Unit Output m
bootstrapComponent = H.mkComponent
  { initialState: const { passphrase: "", adminKey: "" }
  , render
  , eval: H.mkEval H.defaultEval
      { handleAction = handleAction }
  }

render :: forall m. State -> H.ComponentHTML Action () m
render st = HH.div [ HP.class_ (HH.ClassName "bootstrap") ]
  [ HH.h2_ [ HH.text "Bootstrap Mode" ]
  , HH.p_
      [ HH.text
          "No admins yet. Enter the bootstrap passphrase \
          \and your public key to become the first admin."
      ]
  , HH.div [ HP.class_ (HH.ClassName "form") ]
      [ HH.label_ [ HH.text "Passphrase" ]
      , HH.input
          [ HP.type_ HP.InputPassword
          , HP.value st.passphrase
          , HP.placeholder "Bootstrap passphrase"
          , HE.onValueInput SetPassphrase
          ]
      , HH.label_ [ HH.text "Admin public key (CESR)" ]
      , HH.input
          [ HP.value st.adminKey
          , HP.placeholder "Your CESR public key"
          , HE.onValueInput SetAdminKey
          ]
      , HH.button
          [ HE.onClick (const DoSubmit)
          , HP.class_ (HH.ClassName "btn-primary")
          ]
          [ HH.text "Introduce First Admin" ]
      ]
  ]

handleAction
  :: forall m
   . MonadAff m
  => Action
  -> H.HalogenM State Action () Output m Unit
handleAction = case _ of
  SetPassphrase s -> H.modify_ _ { passphrase = s }
  SetAdminKey s -> H.modify_ _ { adminKey = s }
  DoSubmit -> do
    st <- H.get
    when (st.passphrase /= "" && st.adminKey /= "") do
      H.raise (Submit st.passphrase st.adminKey)
