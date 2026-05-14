-- | Shared helpers for session-oriented spec modules.
module MetaSonic.Spec.SessionShared
  ( testProducer
  ) where

import qualified Data.Text                 as T

import           MetaSonic.Session.Queue   (ProducerId(..), ProducerKind)

testProducer :: ProducerKind -> String -> ProducerId
testProducer kind name =
  ProducerId kind (T.pack name)
