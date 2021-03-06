{-# LANGUAGE MagicHash #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE Trustworthy #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UnboxedTuples #-}
{-# LANGUAGE RoleAnnotations #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ParallelListComp #-}
{-# LANGUAGE UnliftedFFITypes #-}
{-# LANGUAGE DefaultSignatures #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE GHCForeignImportPrim #-}
{-# LANGUAGE ForeignFunctionInterface #-}
{-# OPTIONS_GHC -rtsopts -threaded -fno-cse -fno-full-laziness #-}
module Data.Discrimination.Type
  ( Disc(..)
  , descending
  , discNat
  , discShort
  , discSTRef
  , discIORef
  , sdiscNat
  ) where

import Control.Arrow
import Control.Monad
import Data.Coerce
import Data.Functor
import Data.Functor.Contravariant
import Data.Functor.Contravariant.Divisible
import Data.Int
import Data.IORef (newIORef, atomicModifyIORef)
import Data.Monoid hiding (Any)
import Data.Primitive.Types (Addr(..))
import Data.Primitive.ByteArray (MutableByteArray(MutableByteArray))
import Data.Typeable
import Data.Void
import qualified Data.Vector.Mutable as UM
import qualified Data.Vector.Primitive as P
import qualified Data.Vector.Primitive.Mutable as PM
import GHC.IO (IO(IO))
import GHC.IORef (IORef(IORef))
import GHC.Prim (Any, State#, RealWorld, MutableByteArray#, Int#)
import GHC.STRef (STRef(STRef))
import Prelude hiding (read)
import System.IO.Unsafe
import Unsafe.Coerce

-- | Discriminator
--
-- TODO: use [(a,b)] -> [NonEmpty b] to better indicate safety?
newtype Disc a = Disc { (%) :: forall b. [(a,b)] -> [[b]] }
  deriving Typeable

type role Disc representational

infixr 9 %

instance Contravariant Disc where
  contramap f (Disc g) = Disc $ g . map (first f)

instance Divisible Disc where
  conquer = Disc $ return . fmap snd
  divide k (Disc l) (Disc r) = Disc $ \xs ->
    l [ (b, (c, d)) | (a,d) <- xs, let (b, c) = k a] >>= r 

instance Decidable Disc where
  lose k = Disc $ fmap (absurd.k.fst) 
  choose f (Disc l) (Disc r) = Disc $ \xs -> let ys = fmap (first f) xs
    in l [ (k,v) | (Left k, v) <- ys]
    ++ r [ (k,v) | (Right k, v) <- ys]

instance Monoid (Disc a) where
  mempty = conquer
  mappend (Disc l) (Disc r) = Disc $ \xs -> l [ (fst x, x) | x <- xs ] >>= r

descending :: Disc a -> Disc a
descending (Disc l) = Disc (reverse . l)

--------------------------------------------------------------------------------
-- Primitives
--------------------------------------------------------------------------------

-- | unordered discrimination by bucket, not inherently thread-safe
-- but it only has to restore the elements that were used
-- unlike the more obvious ST implementation, so it wins by
-- a huge margin in a race, especially when we have a large
-- keyspace, sparsely used, with low contention.
-- This will leak a number of arrays equal to the maximum concurrent
-- contention for this resource. If this becomes a bottleneck we can
-- make multiple stacks of working pads and index the stack with the
-- hash of the current thread id to reduce contention at the expense
-- of taking more memory.
discNat :: Int -> Disc Int
discNat n = unsafePerformIO $ do
    ts <- newIORef ([] :: [UM.MVector RealWorld [Any]])
    return $ Disc $ go ts
  where
    step1 t keys (k, v) = UM.read t k >>= \vs -> case vs of
      [] -> (k:keys) <$ UM.write t k [v]
      _  -> keys     <$ UM.write t k (v:vs)
    step2 t vss k = do
      elems <- UM.read t k
      (reverse elems : vss) <$ UM.write t k []
    go ts xs = unsafePerformIO $ do
      mt <- atomicModifyIORef ts $ \case
        (y:ys) -> (ys, Just y)
        []     -> ([], Nothing)
      t <- maybe (UM.replicate n []) (return . unsafeCoerce) mt
      ys <- foldM (step1 t) [] xs
      zs <- foldM (step2 t) [] ys
      atomicModifyIORef ts $ \ws -> (unsafeCoerce t:ws, ())
      return zs
    {-# NOINLINE go #-}
{-# NOINLINE discNat #-}

sdiscNat :: Int -> Disc Int
sdiscNat = undefined

-- | Shared bucket set for small integers
discShort :: Disc Int
discShort = discNat 65536
{-# NOINLINE discShort #-}

foreign import prim "walk" walk :: Any -> MutableByteArray# s -> State# s -> (# State# s, Int# #)

discSTRef :: Disc Addr -> Disc (STRef s a)
discSTRef (Disc f) = Disc $ \xs -> 
  let force !n !(!(STRef !_,_):ys) = force (n + 1) ys
      force !n [] = n
  in case force 0 xs of
   !n -> unsafePerformIO $ do
     mv@(PM.MVector _ _ (MutableByteArray mba)) <- PM.new n :: IO (PM.MVector RealWorld Addr)
     IO $ \s -> case walk (unsafeCoerce xs) mba s of (# s', _ #) -> (# s', () #)
     ys <- P.freeze mv
     return $ f [ (a,snd kv) | kv <- xs | a <- P.toList ys ]
{-# NOINLINE discSTRef #-}

discIORef :: forall a. Disc Addr -> Disc (IORef a)
discIORef = coerce (discSTRef :: Disc Addr -> Disc (STRef RealWorld a))

