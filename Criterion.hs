-- |
-- Module      : Criterion
-- Copyright   : (c) Bryan O'Sullivan 2009
--
-- License     : BSD-style
-- Maintainer  : bos@serpentine.com
-- Stability   : experimental
-- Portability : GHC
--
-- Core benchmarking code.

module Criterion
    (
      Benchmarkable(..)
    , Benchmark
    , Pure
    , nf
    , whnf
    , nfIO
    , whnfIO
    , bench
    , bgroup
    , runBenchmark
    , runAndAnalyse
    ) where

import Control.Monad ((<=<), forM_, replicateM_, when)
import Control.Monad.Trans (liftIO)
import Criterion.Analysis (OutlierVariance(..), classifyOutliers,
                           outlierVariance, noteOutliers)
import Criterion.Config (Config(..), Plot(..), fromLJ)
import Criterion.Environment (Environment(..))
import Criterion.IO (note, prolix, summary)
import Criterion.Measurement (getTime, runForAtLeast, secs, time_)
import Criterion.Monad (Criterion, getConfig, getConfigItem)
import Criterion.Plot (plotWith, plotKDE, plotTiming)
import Criterion.Types (Benchmarkable(..), Benchmark(..), Pure,
                        bench, bgroup, nf, nfIO, whnf)
import Data.Array.Vector ((:*:)(..), concatU, lengthU, mapU)
import Statistics.Function (createIO, minMax)
import Statistics.KernelDensity (epanechnikovPDF)
import Statistics.RandomVariate (withSystemRandom)
import Statistics.Resampling (resample)
import Statistics.Resampling.Bootstrap (Estimate(..), bootstrapBCA)
import Statistics.Sample (mean, stdDev)
import Statistics.Types (Sample)
import System.Mem (performGC)
import Text.Printf (printf)

-- | Run a single benchmark, and return timings measured when
-- executing it.
runBenchmark :: Benchmarkable b => Environment -> b -> Criterion Sample
runBenchmark env b = do
  liftIO $ runForAtLeast 0.1 10000 (`replicateM_` getTime)
  let minTime = envClockResolution env * 1000
  (testTime :*: testIters :*: _) <-
      liftIO $ runForAtLeast (min minTime 0.1) 1 (run b)
  prolix "ran %d iterations in %s\n" testIters (secs testTime)
  cfg <- getConfig
  let newIters    = ceiling $ minTime * testItersD / testTime
      sampleCount = fromLJ cfgSamples cfg
      newItersD   = fromIntegral newIters
      testItersD  = fromIntegral testIters
  note "collecting %d samples, %d iterations each, in estimated %s\n"
       sampleCount newIters (secs (fromIntegral sampleCount * newItersD *
                                   testTime / testItersD))
  times <- liftIO . fmap (mapU ((/ newItersD) . subtract (envClockCost env))) .
           createIO sampleCount . const $ do
             when (fromLJ cfgPerformGC cfg) $ performGC
             time_ (run b newIters)
  return times

-- | Run a single benchmark and analyse its performance.
runAndAnalyseOne :: Benchmarkable b => Environment -> String -> b
                 -> Criterion Sample
runAndAnalyseOne env _desc b = do
  times <- runBenchmark env b
  let numSamples = lengthU times
  let ests = [mean,stdDev]
  numResamples <- getConfigItem $ fromLJ cfgResamples
  note "bootstrapping with %d resamples\n" numResamples
  res <- liftIO $ withSystemRandom (\gen -> resample gen ests numResamples times)
  ci <- getConfigItem $ fromLJ cfgConfInterval
  let [em,es] = bootstrapBCA ci times ests res
      (effect, v) = outlierVariance em es (fromIntegral $ numSamples)
      wibble = case effect of
                 Unaffected -> "unaffected" :: String
                 Slight -> "slightly inflated"
                 Moderate -> "moderately inflated"
                 Severe -> "severely inflated"
  bs "mean" em
  summary ","
  bs "std dev" es
  summary "\n"
  noteOutliers (classifyOutliers times)
  note "variance introduced by outliers: %.3f%%\n" (v * 100)
  note "variance is %s by outliers\n" wibble
  return times
  where bs :: String -> Estimate -> Criterion ()
        bs d e = do note "%s: %s, lb %s, ub %s, ci %.3f\n" d
                      (secs $ estPoint e)
                      (secs $ estLowerBound e) (secs $ estUpperBound e)
                      (estConfidenceLevel e)
                    summary $ printf "%g,%g,%g" 
                      (estPoint e)
                      (estLowerBound e) (estUpperBound e)

plotAll :: [(String, Sample)] -> Criterion ()
plotAll descTimes = forM_ descTimes $ \(desc,times) -> do
  plotWith Timing $ \o -> plotTiming o desc times
  plotWith KernelDensity $ \o -> uncurry (plotKDE o desc extremes)
                                     (epanechnikovPDF 100 times)
  where
    extremes = case descTimes of
                 (_:_:_) -> toJust . minMax . concatU . map snd $ descTimes
                 _       -> Nothing
    toJust r@(lo :*: hi)
        | lo == infinity || hi == -infinity = Nothing
        | otherwise                         = Just r
        where infinity                      = 1/0

-- | Run, and analyse, one or more benchmarks.
runAndAnalyse :: (String -> Bool) -- ^ A predicate that chooses
                                  -- whether to run a benchmark by its
                                  -- name.
              -> Environment
              -> Benchmark
              -> Criterion ()
runAndAnalyse p env = plotAll <=< go ""
  where go pfx (Benchmark desc b)
            | p desc'   = do note "\nbenchmarking %s\n" desc'
                             summary (show desc' ++ ",") -- String will be quoted
                             x <- runAndAnalyseOne env desc' b
                             sameAxis <- getConfigItem $ fromLJ cfgPlotSameAxis
                             if sameAxis
                               then return  [(desc',x)]
                               else plotAll [(desc',x)] >> return []
            | otherwise = return []
            where desc' = prefix pfx desc
        go pfx (BenchGroup desc bs) =
            concat `fmap` mapM (go (prefix pfx desc)) bs
        prefix ""  desc = desc
        prefix pfx desc = pfx ++ '/' : desc
