-- | Fake-IO tests for fresh-bracket manifest reload ingress management.

module MetaSonic.Spec.AppManifestReloadIngress where

import           Data.IORef                         (IORef, modifyIORef',
                                                     newIORef, readIORef)

import           Test.Tasty
import           Test.Tasty.HUnit

import           MetaSonic.App.ManifestReloadIngress


data TestTarget
  = OldTarget
  | NewTarget
  deriving (Eq, Show)

data TestHandle = TestHandle
  { thId     :: !Int
  , thTarget :: !TestTarget
  } deriving (Eq, Show)

data TestIssue
  = TestOpenFailed !TestTarget
  | TestCloseFailed !TestHandle
  deriving (Eq, Show)

data TestEvent
  = Opened !TestHandle
  | OpenFailed !TestTarget
  | Closed !TestHandle
  | CloseFailed !TestHandle
  deriving (Eq, Show)

data TestState = TestState
  { tsNextHandle :: !Int
  , tsFailOpen   :: !(Maybe TestTarget)
  , tsFailClose  :: !(Maybe Int)
  , tsEvents     :: ![TestEvent]
  } deriving (Eq, Show)


appManifestReloadIngressTests :: TestTree
appManifestReloadIngressTests =
  testGroup "App manifest reload ingress"
  [ testCase "close marks ingress closed after finalizer succeeds" $ do
      (manager, ref) <- mkManager initialHandle initialTestState
      result <- closeManifestReloadIngress manager
      snapshot <- readManifestReloadIngressManager manager
      events <- tsEvents <$> readIORef ref
      result @?= Right ()
      snapshot @?= MrisClosed
      events @?= [Closed initialHandle]

  , testCase "resume after close opens a fresh old ingress generation" $ do
      (manager, ref) <- mkManager initialHandle initialTestState
      closed <- closeManifestReloadIngress manager
      closed @?= Right ()
      result <- resumeManifestReloadIngress manager OldTarget
      snapshot <- readManifestReloadIngressManager manager
      events <- tsEvents <$> readIORef ref
      result @?= Right ()
      snapshot @?= MrisOpen OldTarget (TestHandle 1 OldTarget)
      events @?=
        [ Closed initialHandle
        , Opened (TestHandle 1 OldTarget)
        ]

  , testCase "resume while already open is a no-op" $ do
      (manager, ref) <- mkManager initialHandle initialTestState
      result <- resumeManifestReloadIngress manager OldTarget
      snapshot <- readManifestReloadIngressManager manager
      events <- tsEvents <$> readIORef ref
      result @?= Right ()
      snapshot @?= MrisOpen OldTarget initialHandle
      events @?= []

  , testCase "fresh reopen closes old ingress before opening new target" $ do
      (manager, ref) <- mkManager initialHandle initialTestState
      result <- openFreshManifestReloadIngress manager NewTarget
      snapshot <- readManifestReloadIngressManager manager
      events <- tsEvents <$> readIORef ref
      result @?= Right ()
      snapshot @?= MrisOpen NewTarget (TestHandle 1 NewTarget)
      events @?=
        [ Closed initialHandle
        , Opened (TestHandle 1 NewTarget)
        ]

  , testCase "fresh reopen after quiesce opens new target from closed state" $ do
      (manager, ref) <- mkManager initialHandle initialTestState
      closed <- closeManifestReloadIngress manager
      closed @?= Right ()
      result <- openFreshManifestReloadIngress manager NewTarget
      snapshot <- readManifestReloadIngressManager manager
      events <- tsEvents <$> readIORef ref
      result @?= Right ()
      snapshot @?= MrisOpen NewTarget (TestHandle 1 NewTarget)
      events @?=
        [ Closed initialHandle
        , Opened (TestHandle 1 NewTarget)
        ]

  , testCase "close failure keeps existing ingress installed" $ do
      (manager, ref) <- mkManager initialHandle initialTestState
        { tsFailClose = Just (thId initialHandle)
        }
      result <- closeManifestReloadIngress manager
      snapshot <- readManifestReloadIngressManager manager
      events <- tsEvents <$> readIORef ref
      result @?= Left (TestCloseFailed initialHandle)
      snapshot @?= MrisOpen OldTarget initialHandle
      events @?= [CloseFailed initialHandle]

  , testCase "fresh reopen close failure does not open duplicate ingress" $ do
      (manager, ref) <- mkManager initialHandle initialTestState
        { tsFailClose = Just (thId initialHandle)
        }
      result <- openFreshManifestReloadIngress manager NewTarget
      snapshot <- readManifestReloadIngressManager manager
      events <- tsEvents <$> readIORef ref
      result @?= Left (TestCloseFailed initialHandle)
      snapshot @?= MrisOpen OldTarget initialHandle
      events @?= [CloseFailed initialHandle]

  , testCase "fresh reopen open failure leaves ingress closed after teardown" $ do
      (manager, ref) <- mkManager initialHandle initialTestState
        { tsFailOpen = Just NewTarget
        }
      result <- openFreshManifestReloadIngress manager NewTarget
      snapshot <- readManifestReloadIngressManager manager
      events <- tsEvents <$> readIORef ref
      result @?= Left (TestOpenFailed NewTarget)
      snapshot @?= MrisClosed
      events @?=
        [ Closed initialHandle
        , OpenFailed NewTarget
        ]

  , testCase "resume open failure leaves ingress closed" $ do
      (manager, ref) <- mkManager initialHandle initialTestState
        { tsFailOpen = Just OldTarget
        }
      closed <- closeManifestReloadIngress manager
      closed @?= Right ()
      result <- resumeManifestReloadIngress manager OldTarget
      snapshot <- readManifestReloadIngressManager manager
      events <- tsEvents <$> readIORef ref
      result @?= Left (TestOpenFailed OldTarget)
      snapshot @?= MrisClosed
      events @?=
        [ Closed initialHandle
        , OpenFailed OldTarget
        ]
  ]


mkManager
  :: TestHandle
  -> TestState
  -> IO ( ManifestReloadIngressManager TestTarget TestIssue TestHandle
        , IORef TestState
        )
mkManager initial state0 = do
  ref <- newIORef state0
  manager <-
    newManifestReloadIngressManager
      ManifestReloadIngressOps
        { mrioOpenIngress =
            openIngress ref
        , mrioCloseIngress =
            closeIngress ref
        }
      (thTarget initial)
      initial
  pure (manager, ref)

initialHandle :: TestHandle
initialHandle =
  TestHandle 0 OldTarget

initialTestState :: TestState
initialTestState = TestState
  { tsNextHandle = 1
  , tsFailOpen = Nothing
  , tsFailClose = Nothing
  , tsEvents = []
  }

openIngress
  :: IORef TestState
  -> TestTarget
  -> IO (Either TestIssue TestHandle)
openIngress ref target = do
  state <- readIORef ref
  if tsFailOpen state == Just target
    then do
      appendEvent ref (OpenFailed target)
      pure (Left (TestOpenFailed target))
    else do
      let handle = TestHandle (tsNextHandle state) target
      modifyIORef' ref $ \state' ->
        state'
          { tsNextHandle =
              tsNextHandle state' + 1
          , tsEvents =
              tsEvents state' <> [Opened handle]
          }
      pure (Right handle)

closeIngress
  :: IORef TestState
  -> TestHandle
  -> IO (Either TestIssue ())
closeIngress ref handle = do
  state <- readIORef ref
  if tsFailClose state == Just (thId handle)
    then do
      appendEvent ref (CloseFailed handle)
      pure (Left (TestCloseFailed handle))
    else do
      appendEvent ref (Closed handle)
      pure (Right ())

appendEvent :: IORef TestState -> TestEvent -> IO ()
appendEvent ref event =
  modifyIORef' ref $ \state ->
    state { tsEvents = tsEvents state <> [event] }
