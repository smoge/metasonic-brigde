-- | Fake/pure harness tests for the manifest reload supervisor.
--
-- Exercises the state machine pinned in
-- notes/2026-05-14-k-host-reload-supervisor.md without touching
-- PortAudio, listeners, or the real fan-in host. The 'SupervisorOps'
-- record is filled with IORef-backed fakes that record every call;
-- assertions check the call sequence, the plan used for rebuild, and
-- the outcome variants.

module MetaSonic.Spec.AppManifestReloadSupervisor where

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
      -- bug the design note explicitly calls out. The supervisor
      -- holds no stable `previouslyGood` field; `fallback` is a
      -- per-reload local, passed in at each call. Walks two
      -- successful reloads (A->B then B->C), then drives a failed
      -- reload from C with C itself as the captured fallback. The
      -- rebuild must target C — not B (one step back), not A (two
      -- steps back). If a future refactor adds a stable history
      -- field, this test fails when the supervisor reaches for the
      -- wrong fallback.
      let planC = "third" :: String
      (ops, log_) <- mkRecordingOps
        (\p -> if p == planC
                 then pure (Left FakeAudioRestartFailed)
                 else pure (Right ()))
        openStackOk

      -- A -> B (success). Caller passes A as the running plan,
      -- B as the requested. On success, B becomes the new
      -- currentPlan from the caller's perspective.
      outcomeAB <- reloadSupervised ops planA planB
      outcomeAB @?= SupervisedReloadCommitted

      -- B -> C (success). Caller passes B (the just-committed
      -- plan), not A. This is the contract: the caller tracks
      -- currentPlan; the supervisor never accumulates it.
      outcomeBC <- reloadSupervised ops planB planC
      -- planC fails per the in-window fake above.
      outcomeBC @?= SupervisedReloadRejectedRecovered FakeAudioRestartFailed

      -- Rebuild target must be planB (the plan running at this
      -- reload's entry), NOT planA (older history) and NOT planC
      -- (the failed requested plan).
      calls <- readIORef log_
      let openCalls = [p | OpenStackCalled p <- calls]
      openCalls @?= [planB]

      -- Belt-and-suspenders: ensure planA never appears in any
      -- open-stack call across this whole sequence. If a future
      -- supervisor mistakenly carried planA as a stable history
      -- field, it would surface here.
      planA `notElem` openCalls @?= True
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
        { sopsInWindowReload = \p -> do
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
