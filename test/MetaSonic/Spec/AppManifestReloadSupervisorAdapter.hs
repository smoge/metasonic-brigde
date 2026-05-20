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

import           Control.Concurrent      (forkIO)
import           Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, takeMVar)
import           Control.Exception       (ErrorCall (..), MaskingState (..),
                                          SomeException, fromException,
                                          getMaskingState, throwIO, throwTo,
                                          try)
import           Control.Monad           (void)
import           Data.IORef              (IORef, modifyIORef', newIORef,
                                          readIORef)

import           Test.Tasty
import           Test.Tasty.HUnit

import           MetaSonic.App.ManifestReloadSupervisor
                                   (InWindowReloadOutcome (..),
                                    SupervisedReloadOutcome (..),
                                    reloadSupervised)
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
  , ffsInWindow     :: !(plan -> IO (InWindowReloadOutcome AdapterFailure))
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
  , hsfInWindowReload = \stackId _fallback plan -> do
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
  -> (plan -> IO (InWindowReloadOutcome AdapterFailure))
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


inWindowOk :: plan -> IO (InWindowReloadOutcome AdapterFailure)
inWindowOk _ = pure InWindowReloadCommitted


-- | Producer signals a terminal in-window failure: the supervisor
-- closes the stack and rebuilds from the fallback plan.
inWindowFails :: String -> plan -> IO (InWindowReloadOutcome AdapterFailure)
inWindowFails msg _ = pure (InWindowReloadTerminal (InWindowFailure msg))


-- | Producer signals a request-rejected outcome: the stack is still
-- live serving the fallback plan. The supervisor returns
-- 'SupervisedReloadRequestRejected' and does NOT close/rebuild.
inWindowRejectsLiveFallback
  :: String -> plan -> IO (InWindowReloadOutcome AdapterFailure)
inWindowRejectsLiveFallback msg _ =
  pure (InWindowReloadRejectedLiveFallback (InWindowFailure msg))


inWindowThrows :: String -> plan -> IO (InWindowReloadOutcome AdapterFailure)
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
      "in-window rejected-live-fallback keeps the same stack: no close, no reopen"
      $ do
      -- Adapter-level pinning of the classified contract: when the
      -- producer signals 'InWindowReloadRejectedLiveFallback', the
      -- adapter must NOT close/open the stack — the ref keeps
      -- pointing at the original stack id (1) and the same stack
      -- is closed exactly once on bracket exit. This is the
      -- adapter mirror of the supervisor-level test in
      -- 'AppManifestReloadSupervisor'; the two together pin both
      -- the supervisor's branching and the adapter's ref handling.
      state <- newFakeFactoryState (openFails "should-not-be-called")
                                   (inWindowRejectsLiveFallback "preserving-reload-rejected")
      outcome <-
        withHostStackSupervisorAdapter (mkFakeFactory state) 1 $ \ops ->
          reloadSupervised ops planA planB
      trace <- readIORef (ffsTrace state)

      outcome @?=
        SupervisedReloadRequestRejected (InWindowFailure "preserving-reload-rejected")
      trace @?=
        [ InWindowCalled 1 planB
        , CloseCalled 1     -- only the bracket's-finally close
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
            | plan == "second-request" = pure InWindowReloadCommitted
            | otherwise                = pure (InWindowReloadTerminal (InWindowFailure "first"))
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

  , testCase
      "openOps runs hsfOpenStack unmasked (restore works)"
      $ do
      -- Direct, deterministic proof that openOps wraps the producer
      -- call in `mask $ \\restore -> ... restore (hsfOpenStack ...)`.
      -- Inside hsfOpenStack the masking state must be 'Unmasked' so
      -- the producer's own internal exception handling (its
      -- @bracket@s, its allocation cleanup) keeps working. Without
      -- 'restore', the producer would inherit the outer mask and
      -- silently lose interruptibility for things like @takeMVar@.
      observedRef <- newIORef Nothing
      let factory = HostStackFactory
            { hsfOpenStack = \_plan -> do
                ms <- getMaskingState
                modifyIORef' observedRef (const (Just ms))
                pure (Right (42 :: Int))
            , hsfCloseStack     = \_ -> pure ()
            , hsfInWindowReload = \_ _ _ ->
                pure (InWindowReloadTerminal (InWindowFailure "force-recovery"))
            }
      _ <-
        withHostStackSupervisorAdapter factory 1 $ \ops ->
          reloadSupervised ops planA planB
      observed <- readIORef observedRef
      observed @?= Just Unmasked

  , testCase
      "closeActiveStack runs hsfCloseStack under MaskedInterruptible"
      $ do
      -- Direct proof that closeActiveStack wraps the take-from-ref
      -- + hsfCloseStack call in `mask_`. The masking state inside
      -- hsfCloseStack must be 'MaskedInterruptible'. Without the
      -- mask, an async exception landing between the
      -- atomicModifyIORef' and the close call would leak the only
      -- handle to the just-emptied stack (the ref now reads
      -- Nothing, the close never ran, the bracket's finally
      -- no-ops). Asserts the recovery path's CloseCalled and the
      -- bracket's-finally CloseCalled BOTH ran masked.
      observedRef <- newIORef []
      let factory = HostStackFactory
            { hsfOpenStack = \_plan -> pure (Right (99 :: Int))
            , hsfCloseStack = \_ -> do
                ms <- getMaskingState
                modifyIORef' observedRef (++ [ms])
            , hsfInWindowReload = \_ _ _ ->
                pure (InWindowReloadTerminal (InWindowFailure "trigger-close"))
            }
      _ <-
        withHostStackSupervisorAdapter factory 1 $ \ops ->
          reloadSupervised ops planA planB
      observed <- readIORef observedRef
      -- Two closes are expected here: the recovery close of the
      -- initial stack (1), and the bracket's-finally close of the
      -- rebuilt stack (2). Both must run masked.
      length observed @?= 2
      all (== MaskedInterruptible) observed @?= True

  , testCase
      "async throwTo during a recovery cycle does not leak the active stack"
      $ do
      -- Live-racing version of the §238 #9 cleanup invariant. A
      -- worker thread drives a supervised reload while the fake's
      -- hsfInWindowReload blocks on an MVar; the main thread
      -- throws an async exception at the worker while it is
      -- inside that producer call. With the mask machinery on
      -- both halves of the adapter, the exception propagates out
      -- but the initial stack (id 1) MUST still be closed before
      -- the worker exits — either by the supervisor's
      -- onException cleanup or by the bracket's finally.
      --
      -- The deterministic proof of \"writeIORef runs under mask\"
      -- and \"hsfCloseStack runs under mask_\" is in the two
      -- getMaskingState tests immediately above; this test pins
      -- the *behavioral* contract under live throwTo timing — no
      -- minted stack is left without a matching close, regardless
      -- of where the throwTo lands.
      inWindowReached <- newEmptyMVar :: IO (MVar ())
      mayReturn       <- newEmptyMVar :: IO (MVar ())
      workerDone      <- newEmptyMVar :: IO (MVar (Either SomeException ()))
      traceRef        <- newIORef []
      idRef           <- newIORef 1

      let mintId = do
            prev <- readIORef idRef
            let nextId = prev + 1
            modifyIORef' idRef (const nextId)
            pure nextId
          recordCall c = modifyIORef' traceRef (++ [c])
          factory :: HostStackFactory String Int AdapterFailure
          factory = HostStackFactory
            { hsfOpenStack = \plan -> do
                newId <- mintId
                recordCall (OpenCalled plan newId)
                pure (Right newId)
            , hsfCloseStack = recordCall . CloseCalled
            , hsfInWindowReload = \stackId _fallback plan -> do
                recordCall (InWindowCalled stackId plan)
                putMVar inWindowReached ()
                takeMVar mayReturn
                pure InWindowReloadCommitted
            }

      workerTid <- forkIO $ do
        result <-
          try
            (withHostStackSupervisorAdapter factory 1 $ \ops ->
                void (reloadSupervised ops planA planB))
        putMVar workerDone result

      -- Wait for the worker to reach the in-window block. The
      -- supervisor's onException wrapper has already registered
      -- its cleanup (sopsCloseStack), so a throwTo here forces
      -- the closeActiveStack/mask_ path to run on the live stack.
      takeMVar inWindowReached
      throwTo workerTid (ErrorCall "recovery-window-interrupt")

      -- Unblock the producer in case the throwTo races with our
      -- putMVar (fork so we don't deadlock if the worker is
      -- already gone).
      _ <- forkIO (putMVar mayReturn ())

      result <- takeMVar workerDone
      trace  <- readIORef traceRef

      case result of
        Left e ->
          case fromException e of
            Just (ErrorCall msg) ->
              msg @?= "recovery-window-interrupt"
            Nothing ->
              assertFailure ("unexpected exception type: " <> show e)
        Right () ->
          assertFailure "expected the async exception to propagate"

      -- Invariant §4: every minted stack must have a matching
      -- close. With the mask_ on closeActiveStack, the supervisor's
      -- onException-driven close of the initial stack (id 1) runs
      -- atomically with the ref-take; with the mask on openOps,
      -- any published rebuild stack also gets a matching close
      -- through the bracket's finally. The trace must satisfy
      -- close-count >= open-count, and every opened id must
      -- appear in the close list.
      let closes  = [i | CloseCalled i <- trace]
          opens   = [i | OpenCalled _ i <- trace]
      (1 `elem` closes) @?= True
      all (`elem` closes) opens @?= True

  , testCase
      "continuation runs at the caller's masking state via outer restore"
      $ do
      -- Pins the outer-mask + restore shape of
      -- withHostStackSupervisorAdapter. The adapter wraps its
      -- setup (newIORef of the initial-stack slot + 'finally'
      -- installation) in 'mask', then restores ONLY the
      -- continuation @k supOps@ so the producer code inside @k@
      -- runs at the caller's original masking state.
      --
      -- Test setup: caller is the default Unmasked state. With
      -- the outer mask + restore correctly applied, the
      -- continuation observes Unmasked (restore lifts the
      -- adapter's MaskedInterruptible back to caller state).
      -- Failure modes this catches:
      --
      --   * outer mask present, restore missing: continuation
      --     would observe MaskedInterruptible and fail this
      --     assertion. This is the most subtle regression — a
      --     drive-by refactor could plausibly drop the restore.
      --
      -- Failure modes this does NOT catch (limit of direct
      -- observation):
      --
      --   * outer mask entirely missing (the user-named §103
      --     bug). With no outer mask, the continuation also
      --     observes Unmasked and the test passes vacuously.
      --     The behavioral guarantee for that case — that
      --     async exceptions cannot land between newIORef and
      --     the 'finally' installation — is enforced by the
      --     code review of the @mask $ \\restore -> ...@
      --     opening of the adapter and is not deterministically
      --     observable from outside.
      observedRef <- newIORef Nothing
      let factory :: HostStackFactory String Int AdapterFailure
          factory = HostStackFactory
            { hsfOpenStack = \_ -> pure (Right 42)
            , hsfCloseStack = \_ -> pure ()
            , hsfInWindowReload = \_ _ _ -> pure InWindowReloadCommitted
            }
      withHostStackSupervisorAdapter factory 1 $ \_ops -> do
        ms <- getMaskingState
        modifyIORef' observedRef (const (Just ms))
      observed <- readIORef observedRef
      observed @?= Just Unmasked
  ]
