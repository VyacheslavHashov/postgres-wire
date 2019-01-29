module Database.PostgreSQL.Protocol.Codecs.Time 
    ( dayToPgj
    , utcToMicros
    , localTimeToMicros
    , timeOfDayToMcs
    , pgjToDay
    , microsToUTC
    , microsToLocalTime
    , mcsToTimeOfDay
    , intervalToDiffTime
    , diffTimeToInterval
    ) where

import Data.Int  (Int64, Int32, Int64)
import Data.Time (Day(..), UTCTime(..), LocalTime(..), DiffTime, TimeOfDay,
                  picosecondsToDiffTime, timeToTimeOfDay,
                  diffTimeToPicoseconds, timeOfDayToTime)

{-# INLINE dayToPgj #-}
dayToPgj :: Integral a => Day -> a
dayToPgj = fromIntegral 
    .(+ (modifiedJulianEpoch - postgresEpoch)) . toModifiedJulianDay

{-# INLINE utcToMicros #-}
utcToMicros :: UTCTime -> Int64
utcToMicros (UTCTime day diffTime) = dayToMcs day + diffTimeToMcs diffTime

{-# INLINE localTimeToMicros #-}
localTimeToMicros :: LocalTime -> Int64
localTimeToMicros (LocalTime day time) = dayToMcs day + timeOfDayToMcs time

{-# INLINE pgjToDay #-}
pgjToDay :: Integral a => a -> Day
pgjToDay = ModifiedJulianDay . fromIntegral 
                        . subtract (modifiedJulianEpoch - postgresEpoch)

{-# INLINE microsToUTC #-}
microsToUTC :: Int64 -> UTCTime
microsToUTC mcs =
    let (d, r) = mcs `divMod` microsInDay
    in UTCTime (pgjToDay d) (mcsToDiffTime r)

{-# INLINE microsToLocalTime #-}
microsToLocalTime :: Int64 -> LocalTime
microsToLocalTime mcs =
    let (d, r) = mcs `divMod` microsInDay
    in LocalTime (pgjToDay d) (mcsToTimeOfDay r)

{-# INLINE intervalToDiffTime #-}
intervalToDiffTime :: Int64 -> Int32 -> Int32 -> DiffTime
intervalToDiffTime mcs days months = picosecondsToDiffTime . mcsToPcs $ 
    microsInDay * (fromIntegral months * daysInMonth + fromIntegral days) 
    + fromIntegral mcs

{-# INLINE diffTimeToInterval #-}
diffTimeToInterval :: DiffTime -> (Int64, Int32, Int32)
diffTimeToInterval dt = (fromIntegral $ diffTimeToMcs dt, 0, 0)

--
-- Utils
--
{-# INLINE dayToMcs #-}
dayToMcs :: Integral a => Day -> a
dayToMcs = (microsInDay *) . dayToPgj 

{-# INLINE diffTimeToMcs #-}
diffTimeToMcs :: Integral a => DiffTime -> a
diffTimeToMcs = fromIntegral . pcsToMcs . diffTimeToPicoseconds 

{-# INLINE timeOfDayToMcs #-}
timeOfDayToMcs :: Integral a => TimeOfDay -> a
timeOfDayToMcs = diffTimeToMcs . timeOfDayToTime 

{-# INLINE mcsToDiffTime #-}
mcsToDiffTime :: Integral a => a -> DiffTime
mcsToDiffTime = picosecondsToDiffTime . fromIntegral . mcsToPcs 

{-# INLINE mcsToTimeOfDay #-}
mcsToTimeOfDay :: Integral a => a -> TimeOfDay
mcsToTimeOfDay = timeToTimeOfDay . mcsToDiffTime

{-# INLINE pcsToMcs #-}
pcsToMcs :: Integral a => a -> a
pcsToMcs = (`div` 10 ^ 6)

{-# INLINE mcsToPcs #-}
mcsToPcs :: Integral a => a -> a
mcsToPcs = (* 10 ^ 6)

{-# INLINE modifiedJulianEpoch #-}
modifiedJulianEpoch :: Num a => a 
modifiedJulianEpoch = 2400001

{-# INLINE postgresEpoch #-}
postgresEpoch :: Num a => a
postgresEpoch = 2451545

{-# INLINE microsInDay #-}
microsInDay :: Num a => a
microsInDay = 24 * 60 * 60 * 10 ^ 6

{-# INLINE daysInMonth #-}
daysInMonth :: Num a => a
daysInMonth = 30
