-- | Tests for 'MigrationKey' lifecycle: tagged builders carry a key
-- through 'lowerGraph' and 'compileRuntimeGraph', the validator
-- rejects duplicates and overlong keys (both ASCII and UTF-8 byte
-- counts), and the C runtime accepts the UTF-8 bytes verbatim via
-- 'loadRuntimeGraph'.
module MetaSonic.Spec.Core.MigrationKeys
  ( migrationKeyTests
  ) where

import           Data.List               (isInfixOf)

import           Test.Tasty
import           Test.Tasty.HUnit

import           MetaSonic.Bridge.Compile
import           MetaSonic.Bridge.FFI    (loadRuntimeGraph, withRTGraph)
import           MetaSonic.Bridge.IR
import           MetaSonic.Bridge.Source
import           MetaSonic.Bridge.Validate
import           MetaSonic.Types

migrationKeyTests :: TestTree
migrationKeyTests =
  testGroup "migration keys"
    [ testCase "tagged builder survives lowering and runtime compile" $
        let sg = runSynth $ do
              osc <- tagged "voice-osc" (sinOsc 440 0)
              _   <- out 0 osc
              pure ()
        in case lowerGraph sg >>= compileRuntimeGraph of
             Left err -> assertFailure err
             Right rt -> do
               let taggedNodes =
                     [ n
                     | n <- rgNodes rt
                     , rnMigrationKey n == Just (MigrationKey "voice-osc")
                     ]
               case taggedNodes of
                 [n] -> rnKind n @?= KSinOsc
                 _   -> assertFailure $
                          "expected exactly one tagged node, got "
                       <> show (length taggedNodes)

    , testCase "validateAndSort rejects duplicate migration keys" $
        let sg = runSynth $ do
              a <- tagged "dup" (sinOsc 440 0)
              b <- tagged "dup" (sawOsc 220 0)
              _ <- out 0 a
              _ <- out 1 b
              pure ()
        in case validateAndSort sg of
             Right _  ->
               assertFailure "expected duplicate migration key rejection"
             Left err ->
               assertBool
                 ("expected duplicate-key diagnostic, got: " <> err)
                 ("Duplicate migration key" `isInfixOf` err)

    , testCase "validateAndSort rejects overlong migration keys" $
        let sg = runSynth $ do
              osc <- tagged "0123456789abcdefX" (sinOsc 440 0)
              _   <- out 0 osc
              pure ()
        in case validateAndSort sg of
             Right _  ->
               assertFailure "expected overlong migration key rejection"
             Left err ->
               assertBool
                 ("expected too-long diagnostic, got: " <> err)
                 ("too long" `isInfixOf` err)

    , testCase "migration keys accept UTF-8 bytes through the FFI" $ do
        let key = "voice-" <> [toEnum 0xe9 :: Char]
            sg = runSynth $ do
              osc <- tagged key (sinOsc 440 0)
              _   <- out 0 osc
              pure ()
        case lowerGraph sg >>= compileRuntimeGraph of
          Left err -> assertFailure err
          Right rt -> do
            assertBool
              "expected compiled runtime node to preserve UTF-8 key"
              (any ((== Just (MigrationKey key)) . rnMigrationKey)
                   (rgNodes rt))
            withRTGraph (length (rgNodes rt)) 64 $ \handle ->
              loadRuntimeGraph handle rt

    , testCase "validateAndSort rejects keys over 16 UTF-8 bytes" $
        let key = replicate 9 (toEnum 0xe9 :: Char)
            sg = runSynth $ do
              osc <- tagged key (sinOsc 440 0)
              _   <- out 0 osc
              pure ()
        in case validateAndSort sg of
             Right _  ->
               assertFailure "expected overlong UTF-8 migration key rejection"
             Left err ->
               assertBool
                 ("expected UTF-8 byte-length diagnostic, got: " <> err)
                 ("too long" `isInfixOf` err)
    ]
