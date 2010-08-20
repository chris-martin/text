{-# LANGUAGE BangPatterns, CPP, Rank2Types #-}

-----------------------------------------------------------------------------
-- |
-- Module      : Data.Text.Lazy.Builder
-- Copyright   : (c) 2010 Johan Tibell
-- License     : BSD3-style (see LICENSE)
-- 
-- Maintainer  : Johan Tibell <johan.tibell@gmail.com>
-- Stability   : experimental
-- Portability : portable to Hugs and GHC
--
-- Efficient construction of lazy texts.
--
-----------------------------------------------------------------------------

module Data.Text.Lazy.Builder
   ( -- * The Builder type
     Builder
   , toLazyText
   , toLazyTextWith

     -- * Constructing Builders
   , singleton
   , fromText
   , fromLazyText

     -- * Flushing the buffer state
   , flush
   ) where

#if defined(ASSERTS)
import Control.Exception (assert)
#endif
import Control.Monad.ST (ST, runST)
import Data.Bits ((.&.))
import Data.Monoid (Monoid(..))
import Data.Text.Internal (Text(..))
import Data.Text.Lazy.Internal (smallChunkSize)
import Data.Text.Unsafe (inlineInterleaveST)
import Data.Text.UnsafeChar (ord, unsafeWrite)
import Data.Text.UnsafeShift (shiftR)
import Prelude hiding (map, putChar)

import qualified Data.String as String
import qualified Data.Text as S
import qualified Data.Text.Array as A
import qualified Data.Text.Lazy as L

------------------------------------------------------------------------

-- | A 'Builder' is an efficient way to build lazy 'L.Text's.  There
-- are several functions for constructing 'Builder's, but only one to
-- inspect them: to extract any data, you have to turn them into lazy
-- 'L.Text's using 'toLazyText'.
--
-- Internally, a 'Builder' constructs a lazy 'L.Text' by filling byte
-- arrays piece by piece.  As each buffer is filled, it is \'popped\'
-- off, to become a new chunk of the resulting lazy 'L.Text'.  All
-- this is hidden from the user of the 'Builder'.
newtype Builder = Builder {
     -- Invariant (from Data.Text.Lazy):
     --      The lists include no null Texts.
     runBuilder :: forall s. (Buffer s -> ST s [S.Text])
                -> Buffer s
                -> ST s [S.Text]
   }

instance Monoid Builder where
   mempty  = empty
   {-# INLINE mempty #-}
   mappend = append
   {-# INLINE mappend #-}

instance String.IsString Builder where
    fromString = fromString
    {-# INLINE fromString #-}

instance Show Builder where
    show = L.unpack . toLazyText

------------------------------------------------------------------------

-- | /O(1)./ The empty Builder, satisfying
--
--  * @'toLazyText' 'empty' = 'L.empty'@
--
empty :: Builder
empty = Builder id
{-# INLINE empty #-}

-- | /O(1)./ A Builder taking a single character, satisfying
--
--  * @'toLazyText' ('singleton' c) = 'L.singleton' c@
--
singleton :: Char -> Builder
singleton c = putChar c
{-# INLINE singleton #-}

------------------------------------------------------------------------

-- | /O(1)./ The concatenation of two Builders, an associative
-- operation with identity 'empty', satisfying
--
--  * @'toLazyText' ('append' x y) = 'L.append' ('toLazyText' x) ('toLazyText' y)@
--
append :: Builder -> Builder -> Builder
append (Builder f) (Builder g) = Builder (f . g)
{-# INLINE [0] append #-}

-- TODO: Experiment to find the right threshold.
copyLimit :: Int
copyLimit =  128                                 

-- This function attempts to merge small Texts instead of treating the
-- text as its own chunk.  We may not always want this.

-- | /O(1)./ A Builder taking a 'S.Text', satisfying
--
--  * @'toLazyText' ('fromText' t) = 'L.fromChunks' [t]@
--
fromText :: S.Text -> Builder
fromText t@(Text arr off l)
    | S.null t       = empty
    | l <= copyLimit = writeN l $ \marr o -> A.partialCopyI marr o arr off (l+o)
    | otherwise      = flush `append` mapBuilder (t :)
{-# INLINE [1] fromText #-}

{-# RULES
"fromText/pack" forall s .
        fromText (S.pack s) = fromString s
 #-}

-- | /O(1)./ A Builder taking a 'String', satisfying
--
--  * @'toLazyText' ('fromString' s) = 'L.fromChunks' [S.pack s]@
--
fromString :: String -> Builder
fromString str = Builder $ \k (Buffer p0 o0 u0 l0) ->
    let loop !marr !o !u !l [] = k (Buffer marr o u l)
        loop marr o u l s@(c:cs)
            | l <= 1 = do
                arr <- A.unsafeFreeze marr
                let !t = Text arr o u
                marr' <- A.unsafeNew chunkSize
                ts <- inlineInterleaveST (loop marr' 0 0 chunkSize s)
                return $ t : ts
            | otherwise = do
                n <- unsafeWrite marr (o+u) c
                loop marr o (u+n) (l-n) cs
    in loop p0 o0 u0 l0 str
  where
    chunkSize = smallChunkSize
{-# INLINE fromString #-}

-- | /O(1)./ A Builder taking a lazy 'L.Text', satisfying
--
--  * @'toLazyText' ('fromLazyText' t) = t@
--
fromLazyText :: L.Text -> Builder
fromLazyText ts = flush `append` mapBuilder (L.toChunks ts ++)
{-# INLINE fromLazyText #-}

------------------------------------------------------------------------

-- Our internal buffer type
data Buffer s = Buffer {-# UNPACK #-} !(A.MArray s)
                       {-# UNPACK #-} !Int  -- offset
                       {-# UNPACK #-} !Int  -- used units
                       {-# UNPACK #-} !Int  -- length left

------------------------------------------------------------------------

-- | /O(n)./ Extract a lazy 'L.Text' from a 'Builder' with a default
-- buffer size.  The construction work takes place if and when the
-- relevant part of the lazy 'L.Text' is demanded.
toLazyText :: Builder -> L.Text
toLazyText = toLazyTextWith smallChunkSize

-- | /O(n)./ Extract a lazy 'L.Text' from a 'Builder', using the given
-- size for the initial buffer.  The construction work takes place if
-- and when the relevant part of the lazy 'L.Text' is demanded.
--
-- If the initial buffer is too small to hold all data, subsequent
-- buffers will be the default buffer size.
toLazyTextWith :: Int -> Builder -> L.Text
toLazyTextWith chunkSize m = L.fromChunks . runST $
  newBuffer chunkSize >>= runBuilder (m `append` flush) (const (return []))

-- | /O(1)./ Pop the 'S.Text' we have constructed so far, if any,
-- yielding a new chunk in the result lazy 'L.Text'.
flush :: Builder
flush = Builder $ \ k buf@(Buffer p o u l) ->
    if u == 0
    then k buf
    else do arr <- A.unsafeFreeze p
            let !b = Buffer p (o+u) 0 l
                !t = Text arr o u
            ts <- inlineInterleaveST (k b)
            return $! t : ts

------------------------------------------------------------------------

-- | Sequence an ST operation on the buffer
withBuffer :: (forall s. Buffer s -> ST s (Buffer s)) -> Builder
withBuffer f = Builder $ \k buf -> f buf >>= k
{-# INLINE withBuffer #-}

-- | Get the size of the buffer
withSize :: (Int -> Builder) -> Builder
withSize f = Builder $ \ k buf@(Buffer _ _ _ l) ->
    runBuilder (f l) k buf
{-# INLINE withSize #-}

-- | Map the resulting list of texts.
mapBuilder :: ([S.Text] -> [S.Text]) -> Builder
mapBuilder f = Builder (fmap f .)

------------------------------------------------------------------------

putChar :: Char -> Builder
putChar c
    | n < 0x10000 = writeN 1 $ \marr o -> A.unsafeWrite marr o (fromIntegral n)
    | otherwise   = writeN 2 $ \marr o -> do
          A.unsafeWrite marr o lo
          A.unsafeWrite marr (o+1) hi
  where n = ord c
        m = n - 0x10000
        lo = fromIntegral $ (m `shiftR` 10) + 0xD800
        hi = fromIntegral $ (m .&. 0x3FF) + 0xDC00
{-# INLINE putChar #-}

------------------------------------------------------------------------

-- | Ensure that there are at least @n@ many elements available.
ensureFree :: Int -> Builder
ensureFree !n = withSize $ \ l ->
    if n <= l
    then empty
    else flush `append'` withBuffer (const (newBuffer (max n smallChunkSize)))
{-# INLINE [0] ensureFree #-}

-- | Ensure that @n@ many elements are available, and then use @f@ to
-- write some elements into the memory.
writeN :: Int -> (forall s. A.MArray s -> Int -> ST s ()) -> Builder
writeN n f = ensureFree n `append'` withBuffer (writeNBuffer n f)
{-# INLINE [0] writeN #-}

writeNBuffer :: Int -> (A.MArray s -> Int -> ST s ()) -> (Buffer s)
             -> ST s (Buffer s)
writeNBuffer n f (Buffer p o u l) = do
    f p (o+u)
    return $! Buffer p o (u+n) (l-n)
{-# INLINE writeNBuffer #-}

newBuffer :: Int -> ST s (Buffer s)
newBuffer size = do
    arr <- A.unsafeNew size
    return $! Buffer arr 0 0 size
{-# INLINE newBuffer #-}

------------------------------------------------------------------------
-- Some nice rules for Builder

-- This function makes GHC understand that 'writeN' and 'ensureFree'
-- are *not* recursive in the precense of the rewrite rules below.
-- This is not needed with GHC 6.14+.
append' :: Builder -> Builder -> Builder
append' (Builder f) (Builder g) = Builder (f . g)
{-# INLINE append' #-}

{-# RULES

"append/writeN" forall a b (f::forall s. A.MArray s -> Int -> ST s ())
                           (g::forall s. A.MArray s -> Int -> ST s ()) ws.
        append (writeN a f) (append (writeN b g) ws) =
            append (writeN (a+b) (\marr o -> f marr o >> g marr (o+a))) ws

"writeN/writeN" forall a b (f::forall s. A.MArray s -> Int -> ST s ())
                           (g::forall s. A.MArray s -> Int -> ST s ()).
        append (writeN a f) (writeN b g) =
            writeN (a+b) (\marr o -> f marr o >> g marr (o+a))

"ensureFree/ensureFree" forall a b .
        append (ensureFree a) (ensureFree b) = ensureFree (max a b)

"flush/flush"
        append flush flush = flush

 #-}
