{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MagicHash #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TupleSections #-}

module Fusion
    (
    -- * Step
    Step(..)
    -- * StepList
    , StepList(..)
    -- * Stream
    , Stream(..), map, filter, drop, concat, lines
    , fromList, fromListM
    , runStream, runStream', bindStream, applyStream, stepStream
    , foldlStream, foldlStreamM
    , foldrStream, foldrStreamM, lazyFoldrStreamIO
    , toListM, lazyToListIO
    , emptyStream, next
    , bracket, streamFile
    -- * StreamList
    , ListT(..), concatL
    -- * Pipes
    , Producer, Pipe, Consumer
    , each
    , (>->)
    )
    where

import           Control.Applicative
import           Control.Monad
import           Control.Monad.IO.Class
import           Control.Monad.Trans.Class
import           Data.ByteString (ByteString)
import qualified Data.ByteString as B
import qualified Data.Foldable as F
import           Data.Functor.Identity
import           Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import           Data.Void
import           GHC.Exts hiding (fromList, toList)
import           Pipes.Safe (SafeT, MonadSafe(..), MonadMask(..))
import           Prelude hiding (map, concat, filter, drop, lines)
import           System.IO
import           System.IO.Unsafe

#define PHASE_FUSED [1]
#define PHASE_INNER [0]

#define INLINE_FUSED INLINE PHASE_FUSED
#define INLINE_INNER INLINE PHASE_INNER

-- Step

-- | A simple stepper, as suggested by Duncan Coutts in his Thesis paper,
-- "Stream Fusion: Practical shortcut fusion for coinductive sequence types".
-- This version adds a result type.
data Step s a r = Done r | Skip s | Yield s a deriving Functor

-- StepList

newtype StepList s r a = StepList { getStepList :: Step s a r }

instance Functor (StepList s r) where
    fmap _ (StepList (Done r))    = StepList $ Done r
    fmap _ (StepList (Skip s))    = StepList $ Skip s
    fmap f (StepList (Yield s a)) = StepList $ Yield s (f a)
    {-# INLINE fmap #-}

-- Stream

data Stream a m r = forall s. Stream (s -> m (Step s a r)) s

instance Show a => Show (Stream a Identity r) where
    show xs = "Stream " ++ show (runIdentity (toListM xs))

instance Functor m => Functor (Stream a m) where
    {-# SPECIALIZE instance Functor (Stream a IO) #-}
    fmap f (Stream k m) = Stream (fmap (fmap f) . k) m
    {-# INLINE_FUSED fmap #-}

instance (Monad m, Applicative m) => Applicative (Stream a m) where
    {-# SPECIALIZE instance Applicative (Stream a IO) #-}
    pure = Stream (pure . Done)
    {-# INLINE_FUSED pure #-}
    sf <*> sx = Stream (\() -> Done <$> (runStream sf <*> runStream sx)) ()
    {-# INLINE_FUSED (<*>) #-}

instance MonadTrans (Stream a) where
    lift = Stream (Done `liftM`)
    {-# INLINE_FUSED lift #-}

(<&>) :: Functor f => f a -> (a -> b) -> f b
x <&> f = fmap f x
{-# INLINE (<&>) #-}

-- | Helper function for more easily writing step functions. Be aware that
-- this can degrade performance over writing the step function directly as an
-- inlined, inner function. The same applies for 'applyStream', 'stepStream',
-- 'foldlStream', etc.
bindStream :: Monad m => (forall s. Step s a r -> m r) -> Stream a m r -> m r
bindStream f (Stream step i) = step i >>= f
{-# INLINE_INNER bindStream #-}

applyStream :: Functor m => (forall s. Step s a r -> r) -> Stream a m r -> m r
applyStream f (Stream step i) = f <$> step i
{-# INLINE_INNER applyStream #-}

stepStream :: Functor m
           => (forall s. Step s a r -> Step s b r) -> Stream a m r
           -> Stream b m r
stepStream f (Stream step i) = Stream (fmap f . step) i
{-# INLINE_INNER stepStream #-}

-- | Map over the values produced by a stream.
--
-- >>> map (+1) (fromList [1..3]) :: Stream Int Identity ()
-- Stream [2,3,4]
map :: Functor m => (a -> b) -> Stream a m r -> Stream b m r
map f (Stream step i) = Stream step' i
  where
    {-# INLINE_INNER step' #-}
    step' s = step s <&> \case
        Done r     -> Done r
        Skip s'    -> Skip s'
        Yield s' a -> Yield s' (f a)
{-# INLINE_FUSED map #-}

filter :: Functor m => (a -> Bool) -> Stream a m r -> Stream a m r
filter p (Stream step i) = Stream step' i
  where
    {-# INLINE_INNER step' #-}
    step' s = step s <&> \case
        Done r     -> Done r
        Skip s'    -> Skip s'
        Yield s' a | p a -> Yield s' a
                   | otherwise -> Skip s'
{-# INLINE_FUSED filter #-}

data Split = Pass !Int# | Keep

drop :: Applicative m => Int -> Stream a m r -> Stream a m r
drop (I# n) (Stream step i) = Stream step' (i, Pass n)
  where
    {-# INLINE_INNER step' #-}
    step' (s, Pass 0#) = pure $ Skip (s, Keep)
    step' (s, Pass n') = step s <&> \case
        Yield s' _ -> Skip (s', Pass (n' -# 1#))
        Skip  s'   -> Skip (s', Pass n')
        Done  r    -> Done r

    step' (s, Keep) = step s <&> \case
        Yield s' x -> Yield (s', Keep) x
        Skip  s'   -> Skip  (s', Keep)
        Done r     -> Done r
{-# INLINE_FUSED drop #-}

concat :: Monad m => Stream (Stream a m r) m r -> Stream a m r
concat (Stream step i) = Stream step' (Left i)
  where
    {-# INLINE_INNER step' #-}
    step' (Left s) = step s >>= \case
        Done r     -> return $ Done r
        Skip s'    -> return $ Skip (Left s')
        Yield s' a -> step' (Right (s',a))

    step' (Right (s, Stream inner j)) = liftM (\case
        Done _     -> Skip (Left s)
        Skip j'    -> Skip (Right (s, Stream inner j'))
        Yield j' a -> Yield (Right (s, Stream inner j')) a) (inner j)
{-# INLINE_FUSED concat #-}

-- decodeUtf8 :: Applicative m => Stream ByteString m r -> Stream Text m ()
-- decodeUtf8 = Stream step' (i, Pass n)

lines :: Applicative m => Stream Text m r -> Stream Text m r
lines (Stream step i) = Stream step' (Left (i, id))
  where
    -- Right means we have pending lines to emit, followed by either the next
    -- state, or the end.
    step' (Right (n, x:xs))     = pure $ Yield (Right (n, xs)) x
    step' (Right (Left n, []))  = step' (Left n)
    step' (Right (Right r, [])) = pure $ Done r

    -- Left means we want to read more lines, gathering up the ends in case
    -- they form a line with the next chunk
    step' (Left (s, prev)) = step s <&> \case
        Done r     -> case prev [] of
            []     -> Done r
            (x:xs) -> Yield (Right (Right r, xs)) x
        Skip s'    -> Skip (Left (s', prev))
        Yield s' a -> case T.lines a of
            []     -> Skip (Left (s', prev))
            [x]    -> Skip (Left (s', prev . (x:)))
            -- This case is particularly complicated because we need to:
            --  1. Emit the known line 'x' now, prepending any remainder
            --     from previous reads (prev)
            --  2. Queue remaining known lines (init xs) for yielding after
            --  3. Preserve the remainder for the next read (last xs)
            --  4. Indicate the next state to read from after we've flushed
            --     everything that was queued (s')
            (x:xs) -> Yield (Right (Left (s', (last xs:)), init xs))
                            (T.concat (prev [x]))
{-# INLINE_FUSED lines #-}

fromList :: (F.Foldable f, Applicative m) => f a -> Stream a m ()
fromList = Stream (pure . step) . F.toList
  where
    {-# INLINE_INNER step #-}
    step []     = Done ()
    step (x:xs) = Yield xs x
{-# INLINE_FUSED fromList #-}

fromListM :: (Applicative m, F.Foldable f) => m (f a) -> Stream a m ()
fromListM = Stream (step `fmap`) . fmap F.toList
  where
    {-# INLINE_INNER step #-}
    step []     = Done ()
    step (y:ys) = Yield (pure ys) y
{-# INLINE_FUSED fromListM #-}

runStream :: Monad m => Stream a m r -> m r
runStream (Stream step i) = step' i
  where
    {-# INLINE_INNER step' #-}
    step' s = step s >>= \case
        Done r     -> return r
        Skip s'    -> step' s'
        Yield s' _ -> step' s'
{-# INLINE runStream #-}

runStream' :: Monad m => Stream Void m r -> m r
runStream' (Stream step i) = step' i
  where
    {-# INLINE_INNER step' #-}
    step' s = step s >>= \case
        Done r    -> return r
        Skip s'   -> step' s'
        Yield _ a -> absurd a
{-# INLINE runStream' #-}

foldlStream :: Monad m
            => (b -> a -> b) -> (b -> r -> s) -> b -> Stream a m r -> m s
foldlStream f w z (Stream step i) = step' i z
  where
    {-# INLINE_INNER step' #-}
    step' s !acc = step s >>= \case
        Done r     -> return $ w acc r
        Skip s'    -> step' s' acc
        Yield s' a -> step' s' (f acc a)
{-# INLINE_FUSED foldlStream #-}

foldlStreamM :: Monad m
             => (m b -> a -> m b) -> (m b -> r -> m s) -> m b -> Stream a m r
             -> m s
foldlStreamM f w z (Stream step i) = step' i z
  where
    {-# INLINE_INNER step' #-}
    step' s acc = step s >>= \case
        Done r     -> w acc r
        Skip s'    -> step' s' acc
        Yield s' a -> step' s' (f acc a)
{-# INLINE_FUSED foldlStreamM #-}

foldrStream :: Monad m => (a -> b -> b) -> (r -> b) -> Stream a m r -> m b
foldrStream f w (Stream step i) = step' i
  where
    {-# INLINE_INNER step' #-}
    step' s = step s >>= \case
        Done r     -> return $ w r
        Skip s'    -> step' s'
        Yield s' a -> liftM (f a) (step' s')
{-# INLINE_FUSED foldrStream #-}

foldrStreamM :: Monad m
             => (a -> m b -> m b) -> (r -> m b) -> Stream a m r -> m b
foldrStreamM f w (Stream step i) = step' i
  where
    {-# INLINE_INNER step' #-}
    step' s = step s >>= \case
        Done r     -> w r
        Skip s'    -> step' s'
        Yield s' a -> f a (step' s')
{-# INLINE_FUSED foldrStreamM #-}

lazyFoldrStreamIO :: (a -> IO b -> IO b) -> (r -> IO b) -> Stream a IO r -> IO b
lazyFoldrStreamIO f w (Stream step i) = step' i
  where
    {-# INLINE_INNER step' #-}
    step' s = step s >>= \case
        Done r     -> w r
        Skip s'    -> step' s'
        Yield s' a -> f a (unsafeInterleaveIO (step' s'))
{-# INLINE_FUSED lazyFoldrStreamIO #-}

toListM :: Monad m => Stream a m r -> m [a]
toListM (Stream step i) = step' i id
  where
    {-# INLINE_INNER step' #-}
    step' s acc = step s >>= \case
        Done _     -> return $ acc []
        Skip s'    -> step' s' acc
        Yield s' a -> step' s' (acc . (a:))
{-# INLINE toListM #-}

lazyToListIO :: Stream a IO r -> IO [a]
lazyToListIO (Stream step i) = step' i
  where
    {-# INLINE_INNER step' #-}
    step' s = step s >>= \case
        Done _     -> return []
        Skip s'    -> step' s'
        Yield s' a -> liftM (a:) (unsafeInterleaveIO (step' s'))
{-# INLINE lazyToListIO #-}

emptyStream :: (Monad m, Applicative m) => Stream Void m ()
emptyStream = pure ()
{-# INLINE CONLIKE emptyStream #-}

bracket :: (Monad m, MonadMask (Base m), MonadSafe m)
         => Base m s
         -> (s -> Base m ())
         -> (forall r. s -> (s -> a -> m r) -> (s -> m r) -> m r -> m r)
         -> Stream a m ()
bracket i f step = Stream step' $ mask $ \unmask -> do
    s   <- unmask $ liftBase i
    key <- register (f s)
    return (s, key)
  where
    {-# INLINE_INNER step' #-}
    step' mx = mx >>= \(s, key) -> step s
        (\s' a -> return $ Yield (return (s', key)) a)
        (\s'   -> return $ Skip  (return (s', key)))
        (mask $ \unmask -> do
              unmask $ liftBase $ f s
              release key
              return $ Done ())
{-# INLINE_FUSED bracket #-}

streamFile :: (MonadIO m, MonadMask (Base m), MonadSafe m)
           => FilePath -> Stream ByteString m ()
streamFile path = bracket
    (liftIO $ openFile path ReadMode)
    (liftIO . hClose)
    (\h yield _skip done -> do
          b <- liftIO $ hIsEOF h
          if b
              then done
              else yield h =<< liftIO (B.hGetSome h 8192))
{-# SPECIALIZE streamFile :: FilePath -> Stream ByteString (SafeT IO) () #-}

next :: Monad m => Stream a m r -> m (Either r (a, Stream a m r))
next (Stream step i) = step' i
  where
    {-# INLINE_INNER step' #-}
    step' s = step s >>= \case
        Done r     -> return $ Left r
        Skip s'    -> step' s'
        Yield s' a -> return $ Right (a, Stream step s')
{-# INLINE next #-}

-- ListT

newtype ListT m a = ListT { getListT :: Stream a m () }

instance Functor m => Functor (ListT m) where
    {-# SPECIALIZE instance Functor (ListT IO) #-}
    fmap f = ListT . map f . getListT
    {-# INLINE fmap #-}

instance (Monad m, Applicative m) => Applicative (ListT m) where
    {-# SPECIALIZE instance Applicative (ListT IO) #-}
    pure = return
    {-# INLINE pure #-}
    (<*>) = ap
    {-# INLINE (<*>) #-}

instance (Monad m, Applicative m) => Monad (ListT m) where
    {-# SPECIALIZE instance Monad (ListT IO) #-}
    return = ListT . fromList . (:[])
    {-# INLINE return #-}
    (>>=) = (concatL .) . flip fmap
    {-# INLINE (>>=) #-}

concatL :: (Monad m, Applicative m) => ListT m (ListT m a) -> ListT m a
concatL = ListT . concat . getListT . liftM getListT
{-# INLINE concatL #-}

-- Pipes

type Producer   b m r = Stream b m r
type Pipe     a b m r = Stream a m () -> Stream b m r
type Consumer a   m r = Stream a m () -> m r

each :: (Applicative m, F.Foldable f) => f a -> Producer a m ()
each = fromList
{-# INLINE_FUSED each #-}

(>->) :: Stream a m r -> (Stream a m r -> Stream b m r) -> Stream b m r
f >-> g = g f
{-# INLINE_FUSED (>->) #-}
