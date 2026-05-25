{-# LANGUAGE LambdaCase #-}

-- |
-- Module      : Spec
-- Description : Test-suite entrypoint for the MetaSonic compiler/runtime pipeline

module Main (main) where

import           Test.Tasty

import           MetaSonic.Spec.AppDemos
import           MetaSonic.Spec.AppFusionCostLab     (appFusionCostLabTests)
import           MetaSonic.Spec.AppManifestMIDIIngressOps
import           MetaSonic.Spec.AppManifestMIDIListener
import           MetaSonic.Spec.AppManifestLiveCommonAddressableSurface
                                                  (appManifestLiveCommonAddressableSurfaceTests)
import           MetaSonic.Spec.AppManifestLiveCommonIngressPolicy
                                                  (appManifestLiveCommonIngressPolicyTests)
import           MetaSonic.Spec.AppManifestLiveCommonOSCControls
                                                  (appManifestLiveCommonOSCControlsTests)
import           MetaSonic.Spec.AppManifestLiveCommonMIDIRender
                                                  (appManifestLiveCommonMIDIRenderTests)
import           MetaSonic.Spec.AppManifestLiveCommonOSCRender
                                                  (appManifestLiveCommonOSCRenderTests)
import           MetaSonic.Spec.AppManifestLiveCommonRetiredBindings
                                                  (appManifestLiveCommonRetiredBindingsTests)
import           MetaSonic.Spec.AppManifestLiveCommonStaleByReload
                                                  (appManifestLiveCommonStaleByReloadTests)
import           MetaSonic.Spec.AppManifestLiveIngressOps
                                                  (appManifestLiveIngressOpsTests)
import           MetaSonic.Spec.AppManifestLivePolicy
                                                  (appManifestLivePolicyTests)
import           MetaSonic.Spec.AppManifestLiveReloadDemoRender
import           MetaSonic.Spec.AppManifestLiveSession
                                                  (appManifestLiveSessionTests)
import           MetaSonic.Spec.AppManifestLiveSessionOutputSink
                                                  (appManifestLiveSessionOutputSinkTests)
import           MetaSonic.Spec.AppManifestLiveSessionProjectors
                                                  (appManifestLiveSessionProjectorsTests)
import           MetaSonic.Spec.AppManifestLiveValueCache
                                                  (appManifestLiveValueCacheTests)
import           MetaSonic.Spec.AppManifestMIDIPortMIDI
import           MetaSonic.Spec.AppManifestMIDIReloadE2E
import           MetaSonic.Spec.AppManifestOSCIngressOps
import           MetaSonic.Spec.AppManifestOSCListener
import           MetaSonic.Spec.AppManifestOSCReloadE2E
import           MetaSonic.Spec.AppManifestPreservingFixture
                                                  (appManifestPreservingFixtureTests)
import           MetaSonic.Spec.AppManifestReloadHostStack
                                                  (appManifestReloadHostStackTests)
import           MetaSonic.Spec.AppManifestReloadPreservingHostStack
                                                  (appManifestReloadPreservingHostStackTests)
import           MetaSonic.Spec.AppManifestReloadTryPreservingHostStack
                                                  (appManifestReloadTryPreservingHostStackTests)
import           MetaSonic.Spec.AppManifestReloadBinding
import           MetaSonic.Spec.AppManifestReloadCli
import           MetaSonic.Spec.AppManifestReloadEvent
                                                  (appManifestReloadEventTests)
import           MetaSonic.Spec.AppManifestReloadHost
import           MetaSonic.Spec.AppManifestReloadIngress
import           MetaSonic.Spec.AppManifestReloadIngressTarget
import           MetaSonic.Spec.AppManifestReloadMIDIBinding
import           MetaSonic.Spec.AppManifestReloadMIDIIngress
import           MetaSonic.Spec.AppManifestReloadOrchestration
import           MetaSonic.Spec.AppManifestReloadOSCBinding
import           MetaSonic.Spec.AppManifestReloadOSCIngress
import           MetaSonic.Spec.AppManifestReloadSupervisor
import           MetaSonic.Spec.AppManifestReloadSupervisorAdapter
                                                  (appManifestReloadSupervisorAdapterTests)
import           MetaSonic.Spec.AppManifestReloadUIIngress
import           MetaSonic.Spec.Core
import           MetaSonic.Spec.Core.Properties (properties)
import           MetaSonic.Spec.FFI
import           MetaSonic.Spec.FFI.BusRouting (busRoutingTests)
import           MetaSonic.Spec.FFI.C0a   (c0aLoaderMetadataTests)
import           MetaSonic.Spec.FFI.C0b   (c0bGlobalScheduleTests)
import           MetaSonic.Spec.FFI.C0c   (c0cScheduleExecutorTests)
import           MetaSonic.Spec.FFI.C0d   (c0dGlobalScheduleBandTests)
import           MetaSonic.Spec.FFI.C1c   (c1cWorkerScheduleTests)
import           MetaSonic.Spec.FFI.FusedRender (fusedRenderTests)
import           MetaSonic.Spec.FFI.HotSwap (hotSwapTests)
import           MetaSonic.Spec.FFI.T9    (t9DirectEqualsReductionTests)
import           MetaSonic.Spec.FFI.TemplateLifecycle (templateLifecycleTests)
import           MetaSonic.Spec.Feature.AuthoringDSL (authoringDslTests)
import           MetaSonic.Spec.Feature.AuthoringManifest (authoringManifestTests)
import           MetaSonic.Spec.Feature.AuthoringReport (authoringReportTests)
import           MetaSonic.Spec.Feature.Capability (capabilityTableTests)
import           MetaSonic.Spec.Feature.FusionProgramBlockExecutor
                   (fusionProgramBlockExecutorTests)
import           MetaSonic.Spec.Feature.FusionProgramExecutor
                   (fusionProgramExecutorTests)
import           MetaSonic.Spec.Feature.FusionProgramScaffold
                   (fusionProgramScaffoldTests)
import           MetaSonic.Spec.Feature.FusionProgramSuperExecutor
                   (fusionProgramSuperExecutorTests)
import           MetaSonic.Spec.Feature.Planner (plannerTests)
import           MetaSonic.Spec.Feature.StaticPlugin (oneTapDelayPluginTests,
                                                      staticPluginSkeletonTests)
import           MetaSonic.Spec.PatternOSCBuffer
import           MetaSonic.Spec.Session.Arbitration (sessionArbitrationTests)
import           MetaSonic.Spec.Session.ArbitrationGateway
                   (sessionArbitrationGatewayTests)
import           MetaSonic.Spec.Session.Command (sessionCommandTests)
import           MetaSonic.Spec.Session.ControlTarget (controlTargetTests)
import           MetaSonic.Spec.Session.FanInHost (sessionFanInHostTests)
import           MetaSonic.Spec.Session.FanInService (sessionFanInServiceTests)
import           MetaSonic.Spec.Session.Host (sessionHostTests)
import           MetaSonic.Spec.Session.LiveHotSwap
                   (sessionLiveHotSwapOrchestrationTests)
import           MetaSonic.Spec.Session.OSCListener (sessionOSCListenerTests)
import           MetaSonic.Spec.Session.OSCProducer (sessionOSCProducerTests)
import           MetaSonic.Spec.Session.Owner (sessionOwnerTests)
import           MetaSonic.Spec.Session.PatternProducer
                   (sessionPatternProducerTests)
import           MetaSonic.Spec.Session.PreservingHotSwap
                   (sessionPreservingHotSwapSpecTests)
import           MetaSonic.Spec.Session.Queue (sessionQueueTests)
import           MetaSonic.Spec.Session.Runner (sessionRunnerTests)
import           MetaSonic.Spec.Session.UIProducer (sessionUIProducerTests)
import           MetaSonic.Spec.Session.Report (sessionReportTests)
import           MetaSonic.Spec.Session.Resolve (sessionResolveTests)
import           MetaSonic.Spec.Session.RTGraphAdapterHotSwap
                   (sessionRTGraphAdapterHotSwapTests)
import           MetaSonic.Spec.Session.RTGraphAdapterInstall
                   (sessionRTGraphAdapterInstallTests)
import           MetaSonic.Spec.Session.State (sessionStateTests)
import           MetaSonic.Spec.Session.Step (sessionStepTests)
import           MetaSonic.Spec.Session.SwapArtifact
                   (sessionSwapArtifactTests)
import           MetaSonic.Spec.SessionManifestReload
import           MetaSonic.Spec.SessionMIDI

main :: IO ()
main = defaultMain $ testGroup "MetaSonic"
  [ testGroup "Phase 7 and earlier"
      [ testGroup "core"
          [ unitTests
          , properties
          , crossCuttingTests
          ]
      , testGroup "ffi"
          [ hotSwapTests
          , busRoutingTests
          , templateLifecycleTests
          , fusedRenderTests
          , t9DirectEqualsReductionTests
          , c0aLoaderMetadataTests
          , c0bGlobalScheduleTests
          , c0cScheduleExecutorTests
          , c0dGlobalScheduleBandTests
          , c1cWorkerScheduleTests
          ]
      , testGroup "compiler"
          [ capabilityTableTests
          , plannerTests
          , fusionProgramScaffoldTests
          , fusionProgramExecutorTests
          , fusionProgramBlockExecutorTests
          , fusionProgramSuperExecutorTests
          ]
      , testGroup "authoring"
          [ authoringDslTests
          , authoringReportTests
          , authoringManifestTests
          ]
      , testGroup "osc"
          [ oscWireAndDispatchTests
          , oscListenerTests
          , oscEndToEndTests
          , oscPortParserTests
          ]
      , testGroup "runtime-skeletons"
          [ bufferPoolTests
          , playBufMonoTests
          , recordBufMonoSkeletonTests
          , spectralFreezeSkeletonTests
          , spectralLpfTests
          , staticPluginSkeletonTests
          , oneTapDelayPluginTests
          ]
      ]
  , testGroup "Phase 8"
      [ testGroup "app"
          [ appDemoCatalogTests
          , appFusionCostLabTests
          , appManifestLiveCommonAddressableSurfaceTests
          , appManifestLiveCommonIngressPolicyTests
          , appManifestLiveCommonMIDIRenderTests
          , appManifestLiveCommonOSCControlsTests
          , appManifestLiveCommonOSCRenderTests
          , appManifestLiveCommonRetiredBindingsTests
          , appManifestLiveCommonStaleByReloadTests
          , appManifestLiveIngressOpsTests
          , appManifestLivePolicyTests
          , appManifestLiveReloadDemoRenderTests
          , appManifestLiveSessionTests
          , appManifestLiveSessionOutputSinkTests
          , appManifestLiveSessionProjectorsTests
          , appManifestLiveValueCacheTests
          , appManifestMIDIIngressOpsTests
          , appManifestMIDIListenerTests
          , appManifestMIDIPortMIDITests
          , appManifestMIDIReloadE2ETests
          , appManifestOSCIngressOpsTests
          , appManifestOSCListenerTests
          , appManifestOSCReloadE2ETests
          , appManifestPreservingFixtureTests
          , appManifestReloadHostStackTests
          , appManifestReloadPreservingHostStackTests
          , appManifestReloadTryPreservingHostStackTests
          , appManifestReloadBindingTests
          , appManifestReloadCliTests
          , appManifestReloadEventTests
          , appManifestReloadHostTests
          , appManifestReloadIngressTests
          , appManifestReloadIngressTargetTests
          , appManifestReloadMIDIBindingTests
          , appManifestReloadMIDIIngressTests
          , appManifestReloadOrchestrationTests
          , appManifestReloadOSCBindingTests
          , appManifestReloadOSCIngressTests
          , appManifestReloadSupervisorTests
          , appManifestReloadSupervisorAdapterTests
          , appManifestReloadUIIngressTests
          ]
      , testGroup "session-substrate"
          [ controlTargetTests
          , patternCorpusTests
          , sessionArbitrationTests
          , sessionArbitrationGatewayTests
          , sessionCommandTests
          , sessionFanInHostTests
          , sessionFanInServiceTests
          , sessionHostTests
          , sessionLiveHotSwapOrchestrationTests
          , sessionManifestReloadTests
          , sessionMIDIListenerTests
          , sessionMIDIPortMIDISourceTests
          , sessionMIDIProducerTests
          , sessionOSCListenerTests
          , sessionOSCProducerTests
          , sessionOwnerTests
          , sessionPatternProducerTests
          , sessionPreservingHotSwapSpecTests
          , sessionQueueTests
          , sessionReportTests
          , sessionResolveTests
          , sessionRTGraphAdapterHotSwapTests
          , sessionRTGraphAdapterInstallTests
          , sessionRunnerTests
          , sessionStateTests
          , sessionStepTests
          , sessionSwapArtifactTests
          , sessionUIProducerTests
          ]
      ]
  ]
