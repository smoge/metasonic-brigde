{-# LANGUAGE DerivingStrategies #-}

-- | Fake-IO tests for the manifest reload supervisor adapter.
--
-- Exercises 'withHostStackSupervisorAdapter' against an
-- 'IORef'-backed fake 'HostStackFactory' that records every open /
-- close / in-window call plus the produced stack values. The
-- adapter is the production seam between the supervisor primitive
-- ('reloadSupervised') and the future real stopped-audio host
-- reload path; these tests pin the four invariants the design note
-- and the slice scope name explicitly:
--
-- - close-before-open on the rebuild path;
-- - the rebuild target is the captured fallback plan, never the
--   failed requested plan;
-- - rebuild escalation surfaces both causes through
--   'SupervisedReloadEscalated';
-- - an exception during in-window reload closes the live stack
--   before propagating (§238 #9 cleanup invariant).
--
-- No real audio, listeners, or PortAudio; the adapter is the only
-- production code under test.
module MetaSonic.Spec.AppManifestReloadSupervisorAdapter
  ( appManifestReloadSupervisorAdapterTests
  ) where

import           Control.Exception (ErrorCall (..), throwIO, try)
import           Data.IORef        (IORef, modifyIORef', newIORef, readIORef)

import           Test.Tasty
import           Test.Tasty.HUnit

import           MetaSonic.App.ManifestReloadSupervisor
                                   (SupervisedReloadOutcome (..),
                                    SupervisorOps (..), reloadSupervised)
import           MetaSonic.App.ManifestReloadSupervisorAdapter
                                   (HostStackFactory (..),
                                    withHostStackSupervisorAdapter)


-- | Test-only error type. Keeps the assertions readable and avoids
-- dragging session-layer issue types into the adapter harness.
data AdapterFailure
  = InWindowFailure !String
  | OpenFailure     !String
  deriving stock (Eq, Show)


-- | A single trace entry the fake factory records. Stack values are
-- 'Int's: each open call mints a fresh id from a monotonic counter.
data AdapterCall plan
  = OpenCalled     !plan !Int      -- ^ plan and the minted stack id
  | CloseCalled    !Int            -- ^ stack id passed to close
  | InWindowCalled !Int !plan      -- ^ stack id and requested plan
  deriving stock (Eq, Show)


-- | Per-test mutable state: monotonic stack-id counter + recorded
-- trace, plus the canned reply behavior for open and in-window.
data FakeFactoryState plan = FakeFactoryState
  { ffsTrace        :: !(IORef [AdapterCall plan])
  , ffsNextStackId  :: !(IORef Int)
  , ffsOpenBehavior :: !(plan -> IO (Either AdapterFailure ()))
  , ffsInWindow     :: !(plan -> IO (Either AdapterFailure ()))
  }


-- | Build a 'HostStackFactory' from a 'FakeFactoryState'. The stack
-- type is @Int@: every open mints a new id, every close records the
-- disposed id. Tests assert against the recorded trace.
mkFakeFactory
  :: FakeFactoryState plan
  -> HostStackFactory plan Int AdapterFailure
mkFakeFactory state = HostStackFactory
  { hsfOpenStack = \plan -> do
      result <- ffsOpenBehavior state plan
      case result of
        Left e ->
          pure (Left e)
        Right () -> do
          newId <- mintStackId state
          record state (OpenCalled plan newId)
          pure (Right newId)
  , hsfCloseStack = record state . CloseCalled
  , hsfInWindowReload = \stackId plan -> do
      record state (InWindowCalled stackId plan)
      ffsInWindow state plan
  }


mintStackId :: FakeFactoryState plan -> IO Int
mintStackId state =
  modifyIORef' (ffsNextStackId state) (+ 1)
    >> readIORef (ffsNextStackId state)


record :: FakeFactoryState plan -> AdapterCall plan -> IO ()
record state c = modifyIORef' (ffsTrace state) (++ [c])


-- | Build the per-test fake state with caller-supplied open and
-- in-window behavior. The initial stack id (the one already open at
-- adapter entry) is always 1; the next 'hsfOpenStack' mints id 2,
-- and so on. Tests assert on those ids to verify the active-stack
-- ref tracks transitions correctly.
newFakeFactoryState
  :: (plan -> IO (Either AdapterFailure ()))
  -> (plan -> IO (Either AdapterFailure ()))
  -> IO (FakeFactoryState plan)
newFakeFactoryState openBehavior inWindowBehavior = do
  traceRef   <- newIORef []
  counterRef <- newIORef 1   -- initial stack id is 1
  pure FakeFactoryState
    { ffsTrace        = traceRef
    , ffsNextStackId  = counterRef
    , ffsOpenBehavior = openBehavior
    , ffsInWindow     = inWindowBehavior
    }


planA, planB :: String
planA = "fallback"
planB = "requested"


-- | Always returns 'Right' — the open succeeds and a new stack id
-- is minted by the factory wrapper.
openOk :: plan -> IO (Either AdapterFailure ())
openOk _ = pure (Right ())


openFails :: String -> plan -> IO (Either AdapterFailure ())
openFails msg _ = pure (Left (OpenFailure msg))


inWindowOk :: plan -> IO (Either AdapterFailure ())
inWindowOk _ = pure (Right ())


inWindowFails :: String -> plan -> IO (Either AdapterFailure ())
inWindowFails msg _ = pure (Left (InWindowFailure msg))


inWindowThrows :: String -> plan -> IO (Either AdapterFailure ())
inWindowThrows msg _ = throwIO (ErrorCall msg)


appManifestReloadSupervisorAdapterTests :: TestTree
appManifestReloadSupervisorAdapterTests =
  testGroup "App manifest reload supervisor adapter"
  [ testCase
      "in-window failure rebuilds from the fallback: close-before-open in trace"
      $ do
      -- The two invariants the slice opens with: the rebuild path
      -- closes the current stack before opening a new one, and the
      -- new stack is opened from the captured fallback plan (not
      -- the failed requested plan). Initial stack id = 1; the
      -- rebuild mints id 2.
      state <- newFakeFactoryState openOk
                                   (inWindowFails "owner-setup")
      outcome <-
        withHostStackSupervisorAdapter (mkFakeFactory state) 1 $ \ops ->
          reloadSupervised ops planA planB
      trace <- readIORef (ffsTrace state)

      outcome @?= SupervisedReloadRejectedRecovered
                    (InWindowFailure "owner-setup")
      trace @?=
        [ InWindowCalled 1 planB
        , CloseCalled 1
        , OpenCalled planA 2
        , CloseCalled 2  -- the bracket's finally closes the new stack
        ]

  , testCase
      "rebuild target is the captured fallback, never the failed requested plan"
      $ do
      -- Belt-and-suspenders against a future refactor that
      -- accidentally passes 'requested' to 'sopsOpenStack' on the
      -- rebuild path. The OpenCalled entries in the trace must
      -- name only the fallback plan, never the requested one.
      state <- newFakeFactoryState openOk
                                   (inWindowFails "audio-restart")
      _ <-
        withHostStackSupervisorAdapter (mkFakeFactory state) 1 $ \ops ->
          reloadSupervised ops planA planB
      trace <- readIORef (ffsTrace state)
      let openedPlans = [p | OpenCalled p _ <- trace]
      openedPlans @?= [planA]
      planB `notElem` openedPlans @?= True

  , testCase
      "rebuild escalation surfaces both causes through SupervisedReloadEscalated"
      $ do
      -- In-window fails AND the rebuild also fails. The adapter
      -- threads both errors through reloadSupervised's
      -- SupervisedReloadEscalated path unchanged. After
      -- escalation the active-stack ref is empty (the close ran,
      -- the open failed), so the bracket's finally is a no-op.
      state <- newFakeFactoryState (openFails "rebuild-broke")
                                   (inWindowFails "owner-setup")
      outcome <-
        withHostStackSupervisorAdapter (mkFakeFactory state) 1 $ \ops ->
          reloadSupervised ops planA planB
      trace <- readIORef (ffsTrace state)

      outcome @?=
        SupervisedReloadEscalated
          (InWindowFailure "owner-setup")
          (OpenFailure "rebuild-broke")
      -- Trace: in-window, then close of the original stack, then
      -- a failed open that minted no new stack. No second close
      -- because there's no live stack at exit.
      trace @?=
        [ InWindowCalled 1 planB
        , CloseCalled 1
        ]
      -- No OpenCalled entry: a failed open does not record a
      -- successful mint. (mkFakeFactory only records OpenCalled
      -- on the Right branch.)
      [p | OpenCalled p _ <- trace] @?= []

  , testCase
      "exception during in-window closes the live stack before propagating"
      $ do
      -- §238 #9 cleanup invariant. reloadSupervised wraps the
      -- in-window call in `onException sopsCloseStack`; the
      -- adapter's sopsCloseStack reads the active-stack ref and
      -- calls hsfCloseStack on whatever was live at the throw
      -- point. The exception surface back through withHostStack...
      -- past the 'finally', which is a no-op because the close
      -- already emptied the ref.
      state <- newFakeFactoryState openOk
                                   (inWindowThrows "synthetic-crash")
      result <-
        try $ withHostStackSupervisorAdapter (mkFakeFactory state) 1 $ \ops ->
          reloadSupervised ops planA planB
      trace <- readIORef (ffsTrace state)

      case result :: Either ErrorCall (SupervisedReloadOutcome AdapterFailure) of
        Left (ErrorCall msg) ->
          msg @?= "synthetic-crash"
        Right outcome ->
          assertFailure $
            "expected the in-window exception to propagate, got: "
            <> show outcome

      -- The trace must show CloseCalled on the live stack (id 1)
      -- before propagation; the rebuild open did NOT run because
      -- exceptions skip the supervisor's recovery branch (per
      -- the supervisor's own behavior pinned in
      -- AppManifestReloadSupervisor).
      trace @?=
        [ InWindowCalled 1 planB
        , CloseCalled 1
        ]
      -- And no second CloseCalled from the bracket's finally:
      -- closeActiveStack is idempotent on an emptied ref.
      length [() | CloseCalled _ <- trace] @?= 1

  , testCase
      "successful in-window keeps the same stack: no close, no reopen"
      $ do
      -- Coherence check on the active-stack ref. A successful
      -- in-window reload mutates the existing stack in place per
      -- the j-note's contract — the adapter must NOT close-then-
      -- open in that case. The trace contains exactly one entry:
      -- InWindowCalled against id 1.
      state <- newFakeFactoryState (openFails "should-not-be-called")
                                   inWindowOk
      outcome <-
        withHostStackSupervisorAdapter (mkFakeFactory state) 1 $ \ops ->
          reloadSupervised ops planA planB
      trace <- readIORef (ffsTrace state)

      outcome @?= SupervisedReloadCommitted
      -- One in-window call against id 1; one close on bracket exit;
      -- no open call (the same id 1 is still live).
      trace @?=
        [ InWindowCalled 1 planB
        , CloseCalled 1
        ]
      [() | OpenCalled _ _ <- trace] @?= []

  , testCase
      "active-stack ref tracks rebuild: in-window operates on the new stack"
      $ do
      -- Drive a recovery cycle, then a SECOND reload against the
      -- recovered stack, and verify the second in-window targets
      -- the new stack id (2), not the closed initial id (1).
      -- Catches a regression where the adapter's IORef would lose
      -- track of the rebuild result.
      let inWindowSecond plan
            | plan == "second-request" = pure (Right ())
            | otherwise                = pure (Left (InWindowFailure "first"))
      state <- newFakeFactoryState openOk inWindowSecond
      withHostStackSupervisorAdapter (mkFakeFactory state) 1 $ \ops -> do
        -- First reload: in-window fails on planB; rebuild from
        -- planA succeeds and mints stack id 2.
        first <- reloadSupervised ops planA planB
        first @?= SupervisedReloadRejectedRecovered (InWindowFailure "first")

        -- Second reload: in-window succeeds against stack id 2.
        second <- reloadSupervised ops planA "second-request"
        second @?= SupervisedReloadCommitted

      trace <- readIORef (ffsTrace state)
      trace @?=
        [ InWindowCalled 1 planB
        , CloseCalled 1
        , OpenCalled planA 2
        , InWindowCalled 2 "second-request"
        , CloseCalled 2     -- finally on bracket exit
        ]
  ]
