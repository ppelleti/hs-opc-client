{-# LANGUAGE MultiWayIf #-}

import Control.Applicative
import Control.Monad
import Data.Binary
import Data.Binary.Put
import Data.Binary.Get
import qualified Data.ByteString.Lazy as L
import Data.Fixed (mod')
import Data.Word
import Network.Socket
import Network.Socket.ByteString
import System.Environment
import System.Exit
import System.Random

data Frame = SetColors
             { fChannel :: !Word8
             , fPixels  :: [Pixel]
             }
           | UnknownCommand
             { fChannel :: !Word8
             , fCommand :: !Word8
             , fData    :: [Word8]
             }

data Pixel =
  Pixel
  { pRed   :: !Word8
  , pGreen :: !Word8
  , pBlue  :: !Word8
  }

cmdSetColors :: Word8
cmdSetColors = 0

instance Binary Frame where
  put f@(SetColors {}) = do
    putWord8 (fChannel f)
    putWord8 cmdSetColors
    let pix = fPixels f
    putWord16be $ fromIntegral (3 * length pix)
    forM_ pix put

  put f@(UnknownCommand {}) = do
    putWord8 (fChannel f)
    putWord8 (fCommand f)
    let d = fData f
    putWord16be $ fromIntegral (length d)
    forM_ d putWord8

  get = do
    ch <- getWord8
    cmd <- getWord8
    len <- getWord16be
    case cmd of
      0 {- cmdSetColors -} -> do
        let (nPix, extra) = len `divMod` 3
        pix <- replicateM (fromIntegral nPix) get
        skip (fromIntegral extra)
        return $ SetColors ch pix
      _ -> do
        d <- replicateM (fromIntegral len) getWord8
        return $ UnknownCommand ch cmd d

instance Binary Pixel where
  put p = do
    putWord8 (pRed p)
    putWord8 (pGreen p)
    putWord8 (pBlue p)

  get = Pixel <$> getWord8 <*> getWord8 <*> getWord8

nLights = 512                   -- max number of lights on a FadeCandy

mkFrame :: [Pixel] -> Frame
mkFrame c = SetColors 0 $ take nLights c

black = Pixel 0 0 0
blue = Pixel 0 0 255
cyan = Pixel 0 255 255
green = Pixel 0 255 0
magenta = Pixel 255 0 255
orange = Pixel 255 128 0
purple = Pixel 192 0 255
red = Pixel 255 0 0
white = Pixel 255 255 255
yellow = Pixel 255 255 0

sendFrame :: Socket -> Frame -> IO ()
sendFrame s f = sendMany s $ L.toChunks $ encode f

-- https://en.wikipedia.org/wiki/HSL_and_HSV#From_HSV
fromHSB :: Double -> Double -> Double -> Pixel
fromHSB h s v =
  let c = v * s
      h' = h / 60
      x = c * (1 - abs (h' `mod'` 2 - 1))
      (r1, g1, b1) = if | h' < 1 -> (c, x, 0)
                        | h' < 2 -> (x, c, 0)
                        | h' < 3 -> (0, c, x)
                        | h' < 4 -> (0, x, c)
                        | h' < 5 -> (x, 0, c)
                        | otherwise -> (c, 0, x)
      m = v - c
      (r, g, b) = (r1 + m, g1 + m, b1 + m)
      mk255 n = round $ n * 255
  in Pixel (mk255 r) (mk255 g) (mk255 b)

fromHue :: Double -> Pixel
fromHue h = fromHSB h 1.0 1.0

randomLites :: StdGen -> [Pixel]
randomLites g = map fromHue $ randomRs (0, 360) g

main = do
  args <- getArgs
  color <- case args of
             []          -> return $ repeat white
             ["black"]   -> return $ repeat black
             ["blue"]    -> return $ repeat blue
             ["cyan"]    -> return $ repeat cyan
             ["green"]   -> return $ repeat green
             ["magenta"] -> return $ repeat magenta
             ["orange"]  -> return $ repeat orange
             ["purple"]  -> return $ repeat purple
             ["red"]     -> return $ repeat red
             ["white"]   -> return $ repeat white
             ["yellow"]  -> return $ repeat yellow
             ["random"]  -> randomLites <$> newStdGen
             [r, g, b]   -> return $ repeat $ Pixel (read r) (read g) (read b)
             _ -> do
               putStrLn "Argument must be one of:"
               putStrLn "    black, blue, cyan, green, magenta, orange, purple, red, white, yellow,"
               putStrLn "    or random"
               putStrLn "Or three integer arguments between 0-255"
               exitFailure
  ai <- getAddrInfo Nothing (Just "127.0.0.1" {- "localhost" -}) (Just "7890")
  let addr = addrAddress $ head ai
      fam (SockAddrInet {}) = AF_INET
      fam (SockAddrInet6 {}) = AF_INET6
      fam sa = error $ "Unexpected socket family: " ++ show sa
  s <- socket (fam addr) Stream defaultProtocol
  connect s addr
  let f = mkFrame color
  sendFrame s f
  -- send frame twice to defeat FadeCandy's fade logic; we want immediate results!
  sendFrame s f
