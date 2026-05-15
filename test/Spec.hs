{-# LANGUAGE LambdaCase #-}

-- |
-- Module      : Spec
-- Description : Test-suite entrypoint for the MetaSonic compiler/runtime pipeline

module Main (main) where

import           Test.Tasty

import           MetaSonic.Spec.AppDemos
import           MetaSonic.Spec.AppManifestReloadBinding
import           MetaSonic.Spec.AppManifestReloadCli
import           MetaSonic.Spec.AppManifestReloadHost
import           MetaSonic.Spec.AppManifestReloadIngress
import           MetaSonic.Spec.AppManifestReloadMIDIBinding
import           MetaSonic.Spec.AppManifestReloadMIDIIngress
import           MetaSonic.Spec.AppManifestReloadOrchestration
import           MetaSonic.Spec.AppManifestReloadOSCBinding
import           MetaSonic.Spec.AppManifestReloadOSCIngress
import           MetaSonic.Spec.AppManifestReloadSupervisor
import           MetaSonic.Spec.AppManifestReloadUIIngress
import           MetaSonic.Spec.Core
import           MetaSonic.Spec.FFI
import           MetaSonic.Spec.Feature
import           MetaSonic.Spec.PatternOSCBuffer
import           MetaSonic.Spec.Session
import           MetaSonic.Spec.SessionManifestReload
import           MetaSonic.Spec.SessionMIDI

main :: IO ()
main = defaultMain $ testGroup "MetaSonic"
  [ appDemoCatalogTests
  , appManifestReloadBindingTests
  , appManifestReloadCliTests
  , appManifestReloadHostTests
  , appManifestReloadIngressTests
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
  , sessionRTGraphAdapterTests
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
