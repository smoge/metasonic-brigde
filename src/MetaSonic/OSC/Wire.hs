{-# LANGUAGE BangPatterns       #-}
{-# LANGUAGE DeriveAnyClass     #-}
{-# LANGUAGE DeriveGeneric      #-}
{-# LANGUAGE DerivingStrategies #-}

-- |
-- Module      : MetaSonic.OSC.Wire
-- Description : Phase 6.B.2a — pure OSC 1.0 single-message parser.
--
-- A minimal OSC parser sized for the v1 grammar: single messages
-- (no bundles, no timetags) with @,f@ (32-bit big-endian float)
-- and @,i@ (32-bit big-endian signed int) arguments only.
-- Anything outside that envelope is rejected with a diagnostic
-- string.
--
-- See [Phase 6.B OSC design](../../../notes/2026-05-10-phase-6b-osc-design.md)
-- for the in-scope / out-of-scope cut.

module MetaSonic.OSC.Wire
  ( -- * Message ADT
    OscMessage (..)
  , OscArg (..)
    -- * Pure parser
  , parseMessage
  ) where

import           Control.DeepSeq        (NFData)
import           Data.Bits              (shiftL, (.|.))
import           Data.ByteString        (ByteString)
import qualified Data.ByteString        as BS
import           Data.Int               (Int32)
import           Data.Word              (Word32, Word8)
import           GHC.Float              (castWord32ToFloat)
import           GHC.Generics           (Generic)

-- | A single typed OSC argument. The v1 surface covers only the
-- two atomic types the project actually needs; @b@ (blob), @s@
-- (string), @t@ (timetag), and so on are explicitly out of
-- scope.
data OscArg
  = OscArgInt   !Int32
  | OscArgFloat !Float
  deriving stock    (Eq, Show, Generic)
  deriving anyclass (NFData)

-- | A parsed single OSC message: the address pattern plus the
-- typed argument list. The address keeps its leading @/@; the
-- 'oscArgs' list preserves wire order.
data OscMessage = OscMessage
  { oscAddr :: !ByteString
  , oscArgs :: ![OscArg]
  } deriving stock    (Eq, Show, Generic)
    deriving anyclass (NFData)

-- | Parse a single OSC message from a 'ByteString'. Returns
-- @Left "<diagnostic>"@ on any structural failure (truncation,
-- missing NUL, unsupported tag, etc.). Bundles (`#bundle`
-- prefix) are explicitly rejected — this is the v1 single-
-- message surface.
parseMessage :: ByteString -> Either String OscMessage
parseMessage bs0 = do
  rejectIfBundle bs0
  (addr, after1) <- parseOscString bs0
  (tags, after2) <- parseOscString after1
  case BS.uncons tags of
    Just (0x2C, rest) -> do                       -- 0x2C == ','
      (args, remaining) <- parseArgs (BS.unpack rest) after2
      if BS.null remaining
        then Right OscMessage { oscAddr = addr, oscArgs = args }
        else Left $ "OSC message: " <> show (BS.length remaining)
                 <> " trailing byte(s) after declared arguments"
    Just _  -> Left "OSC type tag does not start with ','"
    Nothing -> Left "OSC type tag string is empty"

-- An OSC bundle starts with the string "#bundle".
rejectIfBundle :: ByteString -> Either String ()
rejectIfBundle bs
  | BS.take 7 bs == bundlePrefix =
      Left "OSC bundles are out of scope for the v1 wire surface"
  | otherwise = Right ()
  where
    bundlePrefix = BS.pack [0x23, 0x62, 0x75, 0x6E, 0x64, 0x6C, 0x65]  -- "#bundle"

-- An OSC-string is null-terminated and padded to a multiple of
-- 4 bytes with zero bytes. The returned ByteString does NOT
-- include the NUL or the padding. The remainder advances past
-- both. Non-zero padding bytes are rejected — a conforming
-- producer always pads with zeros, and accepting non-zero
-- padding lets malformed packets aliasing later fields slip
-- past the wire layer.
parseOscString :: ByteString -> Either String (ByteString, ByteString)
parseOscString bs =
  case BS.elemIndex 0 bs of
    Nothing -> Left "OSC string: no terminating NUL byte"
    Just n  ->
      let !str         = BS.take n bs
          afterNul     = BS.drop (n + 1) bs
          !consumedRaw = n + 1
          !padding     = (4 - consumedRaw `mod` 4) `mod` 4
          padBytes     = BS.take padding afterNul
      in if BS.length afterNul < padding
           then Left "OSC string: insufficient padding bytes"
           else if BS.any (/= 0) padBytes
             then Left "OSC string: non-zero byte in 4-byte alignment padding"
             else Right (str, BS.drop padding afterNul)

-- v1: only 'f' and 'i' are recognised. Any other tag byte
-- terminates parsing with an explicit message. The remaining
-- bytes are returned alongside the argument list so the caller
-- can reject trailing bytes after the declared arguments.
parseArgs :: [Word8] -> ByteString -> Either String ([OscArg], ByteString)
parseArgs []           bs = Right ([], bs)
parseArgs (tag : rest) bs = do
  (arg, bs')   <- parseArg tag bs
  (args, bs'') <- parseArgs rest bs'
  Right (arg : args, bs'')

parseArg :: Word8 -> ByteString -> Either String (OscArg, ByteString)
parseArg 0x66 bs = do                              -- 'f'
  (w, rest) <- readWord32be bs
  Right (OscArgFloat (castWord32ToFloat w), rest)
parseArg 0x69 bs = do                              -- 'i'
  (w, rest) <- readWord32be bs
  Right (OscArgInt (fromIntegral (fromIntegral w :: Int32)), rest)
parseArg t _ =
  Left $ "OSC type tag '" <> [toEnum (fromIntegral t)]
      <> "' is not in the v1 supported set (,f / ,i)"

readWord32be :: ByteString -> Either String (Word32, ByteString)
readWord32be bs
  | BS.length bs < 4 = Left "OSC argument: 4 bytes expected, got fewer"
  | otherwise =
      let !b0 = fromIntegral (BS.index bs 0) :: Word32
          !b1 = fromIntegral (BS.index bs 1) :: Word32
          !b2 = fromIntegral (BS.index bs 2) :: Word32
          !b3 = fromIntegral (BS.index bs 3) :: Word32
          !w  = (b0 `shiftL` 24) .|. (b1 `shiftL` 16)
            .|. (b2 `shiftL` 8)  .|. b3
      in Right (w, BS.drop 4 bs)
