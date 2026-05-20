-- | Fake/pure harness tests for the manifest reload supervisor.
--
-- Exercises the state machine pinned in
-- notes/2026-05-14-k-host-reload-supervisor.md without touching
-- PortAudio, listeners, or the real fan-in host. The 'SupervisorOps'
-- record is filled with IORef-backed fakes that record every call;
-- assertions check the call sequence, the plan used for rebuild, and
-- the outcome variants.

module MetaSonic.Spec.AppManifestReloadSupervisor where

import           Control.Exception                (ErrorCall (..), evaluate,
                                                   throwIO, try)
import           Data.IORef                       (IORef, modifyIORef',
                                                   newIORef, readIORef)

import           Test.Tasty
import           Test.Tasty.HUnit

import           MetaSonic.App.ManifestReloadSupervisor


-- | A test-only failure type. Keeps the assertions readable and
-- avoids dragging session-layer issue types into the pure harness.
data FakeFailure
  = FakeOwnerSetupFailed
  | FakeAudioRestartFailed
  | FakeListenerRestartFailed
  | FakeRebuildFailed
  deriving (Eq, Show)


-- | A trace of supervisor calls, used to assert the call sequence.
data FakeCall plan
  = InWindowReloadCalled !plan
  | CloseStackCalled
  | OpenStackCalled !plan
  deriving (Eq, Show)


appManifestReloadSupervisorTests :: TestTree
appManifestReloadSupervisorTests =
  testGroup "App manifest reload supervisor"
  [ testCase "in-window success commits requested plan and skips rebuild" $ do
      (ops, log_) <- mkRecordingOps inWindowOk openStackUnused
      outcome <- reloadSupervised ops planA planB
      calls <- readIORef log_
      outcome @?= SupervisedReloadCommitted
      calls @?= [InWindowReloadCalled planB]

  , testCase "in-window failure closes stack and rebuilds from fallback" $ do
      (ops, log_) <-
        mkRecordingOps
          (inWindowFailsWith FakeOwnerSetupFailed)
          openStackOk
      outcome <- reloadSupervised ops planA planB
      calls <- readIORef log_
      outcome @?= SupervisedReloadRejectedRecovered FakeOwnerSetupFailed
      calls @?=
        [ InWindowReloadCalled planB
        , CloseStackCalled
        , OpenStackCalled planA
        ]

  , testCase "rebuild targets fallback plan, never the failed requested plan" $ do
      (ops, log_) <-
        mkRecordingOps
          (inWindowFailsWith FakeAudioRestartFailed)
          openStackOk
      _ <- reloadSupervised ops planA planB
      calls <- readIORef log_
      let openCalls = [p | OpenStackCalled p <- calls]
      openCalls @?= [planA]

  , testCase "audio-restart failure recovers through the same path as owner-setup failure" $ do
      (ops, log_) <-
        mkRecordingOps
          (inWindowFailsWith FakeAudioRestartFailed)
          openStackOk
      outcome <- reloadSupervised ops planA planB
      calls <- readIORef log_
      outcome @?= SupervisedReloadRejectedRecovered FakeAudioRestartFailed
      calls @?=
        [ InWindowReloadCalled planB
        , CloseStackCalled
        , OpenStackCalled planA
        ]

  , testCase "listener-restart failure recovers through the same path" $ do
      (ops, log_) <-
        mkRecordingOps
          (inWindowFailsWith FakeListenerRestartFailed)
          openStackOk
      outcome <- reloadSupervised ops planA planB
      calls <- readIORef log_
      outcome @?= SupervisedReloadRejectedRecovered FakeListenerRestartFailed
      calls @?=
        [ InWindowReloadCalled planB
        , CloseStackCalled
        , OpenStackCalled planA
        ]

  , testCase "rebuild failure escalates with both causes preserved" $ do
      (ops, log_) <-
        mkRecordingOps
          (inWindowFailsWith FakeAudioRestartFailed)
          (openStackFailsWith FakeRebuildFailed)
      outcome <- reloadSupervised ops planA planB
      calls <- readIORef log_
      outcome @?=
        SupervisedReloadEscalated FakeAudioRestartFailed FakeRebuildFailed
      calls @?=
        [ InWindowReloadCalled planB
        , CloseStackCalled
        , OpenStackCalled planA
        ]

  , testCase "escalation does not retry: exactly one rebuild attempt" $ do
      (ops, log_) <-
        mkRecordingOps
          (inWindowFailsWith FakeOwnerSetupFailed)
          (openStackFailsWith FakeRebuildFailed)
      _ <- reloadSupervised ops planA planB
      calls <- readIORef log_
      let opens  = length [() | OpenStackCalled _ <- calls]
          closes = length [() | CloseStackCalled  <- calls]
      opens  @?= 1
      closes @?= 1

  , testCase "close stack is called exactly once between failure and rebuild" $ do
      (ops, log_) <-
        mkRecordingOps
          (inWindowFailsWith FakeOwnerSetupFailed)
          openStackOk
      _ <- reloadSupervised ops planA planB
      calls <- readIORef log_
      -- CloseStackCalled appears between InWindowReloadCalled and OpenStackCalled.
      let positions =
            [ i | (i, c) <- zip [0 :: Int ..] calls, c == CloseStackCalled ]
      positions @?= [1]

  , testCase "in-window success keeps fallback unused: no close, no open" $ do
      (ops, log_) <-
        mkRecordingOps
          inWindowOk
          (openStackFailsWith FakeRebuildFailed)
      outcome <- reloadSupervised ops planA planB
      calls <- readIORef log_
      outcome @?= SupervisedReloadCommitted
      CloseStackCalled `elem` calls @?= False
      any isOpenCall calls @?= False

  , testCase
      "A->B->C: failure from C falls back to C, never to B or A (no remembered history)"
      $ do
      -- §238 test-checklist regression for the "previousGood lags"
      -- bug the design note explicitly calls out: "two consecutive
      -- successful reloads (A -> B -> C) leave the supervisor
      -- running C with no remembered A; a later failed reload from
      -- C falls back to C, not to A or B." The supervisor holds no
      -- stable `previouslyGood` field; `fallback` is a per-reload
      -- local, passed in at each call. If a future refactor adds
      -- accumulated state, the supervisor would lag a step behind
      -- and rebuild from B (or earlier) instead of C — exactly the
      -- regression this test guards against.
      let planC = "third"  :: String
          planD = "fourth" :: String
      (ops, log_) <- mkRecordingOps
        (\p -> if p == planD
                 then pure (Left FakeAudioRestartFailed)
                 else pure (Right ()))
        openStackOk

      -- A -> B commits.
      outcomeAB <- reloadSupervised ops planA planB
      outcomeAB @?= SupervisedReloadCommitted

      -- B -> C commits. Caller threads currentPlan forward — the
      -- supervisor never accumulates history.
      outcomeBC <- reloadSupervised ops planB planC
      outcomeBC @?= SupervisedReloadCommitted

      -- C -> D fails. Fallback at reload entry is planC (the plan
      -- currently running per the caller's bookkeeping). Rebuild
      -- must target planC — not planB (one step back), not planA
      -- (two steps back), not planD (the failed requested plan).
      outcomeCD <- reloadSupervised ops planC planD
      outcomeCD @?= SupervisedReloadRejectedRecovered FakeAudioRestartFailed

      calls <- readIORef log_
      let openCalls = [p | OpenStackCalled p <- calls]
      openCalls @?= [planC]

      -- Belt-and-suspenders: assert planA / planB never appear in
      -- any rebuild target across the whole A->B->C->D! sequence.
      -- A future "previousGood" history field would silently reach
      -- for one of them here.
      planA `notElem` openCalls @?= True
      planB `notElem` openCalls @?= True

  , testCase
      "exception during in-window reload closes the previous stack before propagating"
      $ do
      -- §238 test-checklist line: "async exception during recovery
      -- closes any partial stack before surfacing." The supervisor
      -- wraps sopsInWindowReload in onException sopsCloseStack so
      -- the previous (still-live) stack is closed before the
      -- exception escapes. Without that wrap, an in-window throw
      -- would leak the previous stack and violate invariant §4
      -- ("exactly one active stack at a time").
      log_ <- newIORef []
      let record c = modifyIORef' log_ (++ [c])
          ops :: SupervisorOps String FakeFailure
          ops = SupervisorOps
            { sopsInWindowReload = \_fallback p -> do
                record (InWindowReloadCalled p)
                throwIO (ErrorCall "synthetic in-window crash")
            , sopsCloseStack = record CloseStackCalled
            , sopsOpenStack = \p -> do
                record (OpenStackCalled p)
                pure (Right ())
            }
      result <- try (reloadSupervised ops planA planB)
      calls <- readIORef log_
      case result :: Either ErrorCall (SupervisedReloadOutcome FakeFailure) of
        Left (ErrorCall msg) ->
          msg @?= "synthetic in-window crash"
        Right outcome ->
          assertFailure $
            "expected the in-window exception to propagate, got: "
            <> show outcome

      -- The trace must show CloseStackCalled *after* the in-window
      -- attempt and *before* the exception propagated out. The
      -- recovery rebuild (OpenStackCalled) must NOT have run — an
      -- exception during in-window is not the same as a Left e
      -- recovery, so we propagate without attempting rebuild.
      calls @?=
        [ InWindowReloadCalled planB
        , CloseStackCalled
        ]
      any isOpenCall calls @?= False

  , testCase
      "no exception path: onException wrapper does not fire on Left e"
      $ do
      -- Companion to the test above: confirm that a normal Left e
      -- return from sopsInWindowReload does NOT trigger the
      -- onException cleanup. The supervisor must call sopsCloseStack
      -- exactly once (on the recovery path), not twice (once from
      -- onException, once explicitly). Counts the trace by calling
      -- sopsCloseStack only once and asserting the recovery
      -- sequence is unchanged.
      (ops, log_) <-
        mkRecordingOps
          (inWindowFailsWith FakeOwnerSetupFailed)
          openStackOk
      _ <- evaluate =<< reloadSupervised ops planA planB
      calls <- readIORef log_
      length [() | CloseStackCalled <- calls] @?= 1
      calls @?=
        [ InWindowReloadCalled planB
        , CloseStackCalled
        , OpenStackCalled planA
        ]
  ]


-- | Helper: distinguish the open-stack call without case-matching by hand.
isOpenCall :: FakeCall a -> Bool
isOpenCall (OpenStackCalled _) = True
isOpenCall _                   = False


-- | Build an IORef-backed 'SupervisorOps' that records every call.
mkRecordingOps
  :: (plan -> IO (Either FakeFailure ()))
     -- ^ Behavior for 'sopsInWindowReload'.
  -> (plan -> IO (Either FakeFailure ()))
     -- ^ Behavior for 'sopsOpenStack'.
  -> IO ( SupervisorOps plan FakeFailure
        , IORef [FakeCall plan]
        )
mkRecordingOps inWindow openStack = do
  log_ <- newIORef []
  let record c = modifyIORef' log_ (++ [c])
      ops = SupervisorOps
        { sopsInWindowReload = \_fallback p -> do
            record (InWindowReloadCalled p)
            inWindow p
        , sopsCloseStack = record CloseStackCalled
        , sopsOpenStack = \p -> do
            record (OpenStackCalled p)
            openStack p
        }
  pure (ops, log_)


inWindowOk :: plan -> IO (Either FakeFailure ())
inWindowOk _ = pure (Right ())

inWindowFailsWith :: FakeFailure -> plan -> IO (Either FakeFailure ())
inWindowFailsWith err _ = pure (Left err)

openStackOk :: plan -> IO (Either FakeFailure ())
openStackOk _ = pure (Right ())

openStackFailsWith :: FakeFailure -> plan -> IO (Either FakeFailure ())
openStackFailsWith err _ = pure (Left err)

openStackUnused :: plan -> IO (Either FakeFailure ())
openStackUnused _ =
  assertFailure "sopsOpenStack should not be called on the happy path"
    >> pure (Right ())


-- | Two distinct plan-like values for the harness. The supervisor is
-- generic over the plan type, so the test only needs two values it can
-- compare with '(==)'.
planA, planB :: String
planA = "fallback"
planB = "requested"
