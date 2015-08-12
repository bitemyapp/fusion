{-# LANGUAGE CPP #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TupleSections #-}

module Fusion
    (
    -- * Step
    Step(..)
    -- * StepList
    , StepList(..)
    -- * Stream
    , Stream(..), mapS, filterS, dropS, concatS, fromList, fromListM
    , toListS, lazyToListS, runStream, runStream_
    , emptyStream, bracketS, next
    -- * StreamList
    , ListT(..), concatL
    -- * Pipes
    , Producer, Pipe, Consumer
    , each, mapP
    )
    where

import Control.Applicative
import Control.Monad
import Control.Monad.Trans.Class
import Data.Foldable
import Data.Functor.Identity
import Data.Void
import Pipes.Safe
import System.IO.Unsafe

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

data Stream a m r where
    Stream :: (s -> m (Step s a r)) -> s -> Stream a m r

instance Show a => Show (Stream a Identity r) where
    show xs = "Stream " ++ show (runIdentity (toListS xs))

instance Functor m => Functor (Stream a m) where
    fmap f (Stream k m) = Stream (fmap (fmap f) . k) m
    {-# INLINE_FUSED fmap #-}

instance (Monad m, Applicative m) => Applicative (Stream a m) where
    pure = Stream (pure . Done)
    {-# INLINE_FUSED pure #-}
    sf <*> sx = Stream (\() -> Done <$> (runStream sf <*> runStream sx)) ()
    {-# INLINE_FUSED (<*>) #-}

instance MonadTrans (Stream a) where
    lift = Stream (Done `liftM`)
    {-# INLINE_FUSED lift #-}

(<&>) :: Functor f => f a -> (a -> b) -> f b
(<&>) = flip (<$>)
{-# INLINE (<&>) #-}

-- | Map over the values produced by a stream.
--
-- >>> mapS (+1) (fromList [1..3]) :: Stream Int Identity ()
-- Stream [2,3,4]
mapS :: Functor m => (a -> b) -> Stream a m r -> Stream b m r
mapS f (Stream step i) = Stream step' i
  where
    {-# INLINE_INNER step' #-}
    step' s = step s <&> \case
        Done r     -> Done r
        Skip s'    -> Skip s'
        Yield s' a -> Yield s' (f a)
{-# INLINE_FUSED mapS #-}

filterS :: Functor m => (a -> Bool) -> Stream a m r -> Stream a m r
filterS p (Stream step i) = Stream step' i
  where
    {-# INLINE_INNER step' #-}
    step' s = step s <&> \case
        Done r     -> Done r
        Skip s'    -> Skip s'
        Yield s' a | p a -> Yield s' a
                   | otherwise -> Skip s'
{-# INLINE_FUSED filterS #-}

dropS :: Monad m => Int -> Stream a m r -> Stream a m ()
dropS n (Stream step i) = Stream step' (i, Just n)
  where
    {-# INLINE_INNER step' #-}
    step' (s, Just n')
        | n' > 0 = step s <&> \case
            Yield s' _ -> Skip (s', Just (n'-1))
            Skip  s'   -> Skip (s', Just n')
            Done  _    -> Done ()
        | otherwise = return $ Skip (s, Nothing)

    step' (s, Nothing) = step s <&> \case
        Yield s' x -> Yield (s', Nothing) x
        Skip  s'   -> Skip  (s', Nothing)
        Done _     -> Done ()
{-# INLINE_FUSED dropS #-}

concatS :: Monad m => Stream (Stream a m r) m r -> Stream a m r
concatS (Stream step i) = Stream step' (Left i)
  where
    {-# INLINE_INNER step' #-}
    step' (Left s) = step s >>= \case
        Done r     -> return $ Done r
        Skip s'    -> return $ Skip (Left s')
        Yield s' a -> step' (Right (s',a))

    step' (Right (s, Stream inner j)) = inner j <&> \case
        Done _     -> Skip (Left s)
        Skip j'    -> Skip (Right (s, Stream inner j'))
        Yield j' a -> Yield (Right (s, Stream inner j')) a
{-# INLINE_FUSED concatS #-}

fromList :: Foldable f => Applicative m => f a -> Stream a m ()
fromList = Stream (pure . step) . toList
  where
    {-# INLINE_INNER step #-}
    step []     = Done ()
    step (x:xs) = Yield xs x
{-# INLINE_FUSED fromList #-}

fromListM :: (Monad m, Foldable f) => m (f a) -> Stream a m ()
fromListM = Stream (step `liftM`) . liftM toList
  where
    {-# INLINE_INNER step #-}
    step []     = Done ()
    step (y:ys) = Yield (return ys) y
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

runStream_ :: Monad m => Stream Void m r -> m r
runStream_ (Stream step i) = step' i
  where
    {-# INLINE_INNER step' #-}
    step' s = step s >>= \case
        Done r    -> return r
        Skip s'   -> step' s'
        Yield _ a -> absurd a
{-# INLINE runStream_ #-}

toListS :: Monad m => Stream a m r -> m [a]
toListS (Stream step i) = step' i
  where
    {-# INLINE_INNER step' #-}
    step' s = step s >>= \case
        Done _     -> return []
        Skip s'    -> step' s'
        Yield s' a -> liftM (a:) (step' s')
{-# INLINE toListS #-}

lazyToListS :: Stream a IO r -> IO [a]
lazyToListS (Stream step i) = step' i
  where
    {-# INLINE_INNER step' #-}
    step' s = step s >>= \case
        Done _     -> return []
        Skip s'    -> step' s'
        Yield s' a -> liftM (a:) (unsafeInterleaveIO (step' s'))
{-# INLINE lazyToListS #-}

emptyStream :: (Monad m, Applicative m) => Stream Void m ()
emptyStream = pure ()
{-# INLINE CONLIKE emptyStream #-}

bracketS :: (Monad m, MonadMask (Base m), MonadSafe m)
         => Base m s
         -> (s -> Base m ())
         -> (forall r. s -> (s -> a -> m r) -> (s -> m r) -> m r -> m r)
         -> Stream a m ()
bracketS i f step = Stream step' $ mask $ \unmask -> do
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
{-# INLINE_FUSED bracketS #-}

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
    fmap f (ListT s) = ListT $ mapS f s
    {-# INLINE fmap #-}

instance (Monad m, Applicative m) => Applicative (ListT m) where
    pure = return
    {-# INLINE pure #-}
    (<*>) = ap
    {-# INLINE (<*>) #-}

instance (Monad m, Applicative m) => Monad (ListT m) where
    return x = ListT $ fromList [x]
    {-# INLINE return #-}
    m >>= f = concatL $ fmap f m
    {-# INLINE (>>=) #-}

concatL :: (Monad m, Applicative m) => ListT m (ListT m a) -> ListT m a
concatL = ListT . concatS . getListT . liftM getListT
{-# INLINE concatL #-}

-- Pipes

type Producer   b m r = Stream b m r
type Pipe     a b m r = Stream a m () -> Stream b m r
type Consumer a   m r = Stream a m () -> m r

each :: (Applicative m, Foldable f) => f a -> Producer a m ()
each = fromList
{-# INLINE each #-}

mapP :: (Monad m, Applicative m) => (a -> b) -> Pipe a b m ()
mapP f = getListT . liftM f . ListT
{-# INLINE mapP #-}
