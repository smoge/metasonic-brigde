{-# LANGUAGE LambdaCase #-}

-- |
-- Module      : Spec
-- Description : Test-suite entrypoint for the MetaSonic compiler/runtime pipeline

module Main (main) where

import           Test.Tasty

import           MetaSonic.Spec.AppDemos
import           MetaSonic.Spec.AppManifestMIDIIngressOps
import           MetaSonic.Spec.AppManifestMIDIListener
import           MetaSonic.Spec.AppManifestLiveReloadDemoRender
import           MetaSonic.Spec.AppManifestMIDIPortMIDI
import           MetaSonic.Spec.AppManifestMIDIReloadE2E
import           MetaSonic.Spec.AppManifestOSCIngressOps
import           MetaSonic.Spec.AppManifestOSCListener
import           MetaSonic.Spec.AppManifestOSCReloadE2E
import           MetaSonic.Spec.AppManifestReloadBinding
import           MetaSonic.Spec.AppManifestReloadCli
import           MetaSonic.Spec.AppManifestReloadHost
import           MetaSonic.Spec.AppManifestReloadIngress
import           MetaSonic.Spec.AppManifestReloadIngressTarget
import           MetaSonic.Spec.AppManifestReloadMIDIBinding
import           MetaSonic.Spec.AppManifestReloadMIDIIngress
import           MetaSonic.Spec.AppManifestReloadOrchestration
import           MetaSonic.Spec.AppManifestReloadOSCBinding
import           MetaSonic.Spec.AppManifestReloadOSCIngress
import           MetaSonic.Spec.AppManifestReloadSupervisor
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
import           MetaSonic.Spec.Feature.StaticPlugin (staticPluginSkeletonTests)
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
import           MetaSonic.Spec.SessionManifestReload
import           MetaSonic.Spec.SessionMIDI

main :: IO ()
main = defaultMain $ testGroup "MetaSonic"
  [ appDemoCatalogTests
  , appManifestLiveReloadDemoRenderTests
  , appManifestMIDIIngressOpsTests
  , appManifestMIDIListenerTests
  , appManifestMIDIPortMIDITests
  , appManifestMIDIReloadE2ETests
  , appManifestOSCIngressOpsTests
  , appManifestOSCListenerTests
  , appManifestOSCReloadE2ETests
  , appManifestReloadBindingTests
  , appManifestReloadCliTests
  , appManifestReloadHostTests
  , appManifestReloadIngressTests
  , appManifestReloadIngressTargetTests
  , appManifestReloadMIDIBindingTests
  , appManifestReloadMIDIIngressTests
  , appManifestReloadOrchestrationTests
  , appManifestReloadOSCBindingTests
  , appManifestReloadOSCIngressTests
  , appManifestReloadSupervisorTests
  , appManifestReloadUIIngressTests
  , unitTests
  , properties
  , crossCuttingTests
  , hotSwapTests
  , busRoutingTests
  , templateLifecycleTests
  , fusedRenderTests
  , t9DirectEqualsReductionTests
  , c0aLoaderMetadataTests
  , c0bGlobalScheduleTests
  , c0cScheduleExecutorTests
  , c0dGlobalScheduleBandTests
  , c1cWorkerScheduleTests
  , sessionCommandTests
  , sessionResolveTests
  , sessionReportTests
  , sessionStateTests
  , sessionStepTests
  , controlTargetTests
  , sessionRTGraphAdapterInstallTests
  , sessionRTGraphAdapterHotSwapTests
  , sessionOwnerTests
  , sessionQueueTests
  , sessionArbitrationTests
  , sessionArbitrationGatewayTests
  , sessionPatternProducerTests
  , sessionRunnerTests
  , sessionHostTests
  , sessionPreservingHotSwapSpecTests
  , sessionLiveHotSwapOrchestrationTests
  , sessionFanInHostTests
  , sessionFanInServiceTests
  , sessionManifestReloadTests
  , sessionMIDIProducerTests
  , sessionMIDIListenerTests
  , sessionMIDIPortMIDISourceTests
  , sessionUIProducerTests
  , sessionOSCProducerTests
  , sessionOSCListenerTests
  , patternCorpusTests
  , oscWireAndDispatchTests
  , oscListenerTests
  , oscEndToEndTests
  , oscPortParserTests
  , bufferPoolTests
  , playBufMonoTests
  , recordBufMonoSkeletonTests
  , spectralFreezeSkeletonTests
  , staticPluginSkeletonTests
  , authoringDslTests
  , authoringReportTests
  , authoringManifestTests
  , capabilityTableTests
  , plannerTests
  , fusionProgramScaffoldTests
  , fusionProgramExecutorTests
  , fusionProgramBlockExecutorTests
  , fusionProgramSuperExecutorTests
  ]
