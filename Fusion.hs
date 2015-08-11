{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE GADTs #-}

module Fusion
    (
    -- * Step
    Step(..)
    -- * StepList
    , StepList(..)
    -- * Stream
    , Stream(..), mapS, concatS, fromList, toListS, reduceS, emptyStream
    -- * StreamList
    , StreamList(..), concatSL, toListSL, toListSL', eachM
    -- * Pipes
    , Producer, Pipe, Consumer, Effect
    , runEffect, each, map, collect
    , toListM, lazyToListM
    )
    where

import Control.Applicative
import Control.Monad
import Control.Monad.Trans.Class
import Data.Foldable
import Data.Functor.Identity
import Data.Void
import Prelude hiding (map)
import System.IO.Unsafe

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
    Stream :: (s -> m (Step s a r)) -> m s -> Stream a m r

instance Show a => Show (Stream a Identity r) where
    show xs = "Stream " ++ show (runIdentity (toListS xs))

instance Functor m => Functor (Stream a m) where
    fmap f (Stream k m) = Stream (fmap (fmap f) . k) m
    {-# INLINE fmap #-}

instance Monad m => Applicative (Stream a m) where
    pure x = Stream (pure . Done) (pure x)
    {-# INLINE pure #-}
    sf <*> sx = Stream (pure . Done) (reduceS sf <*> reduceS sx)
    {-# INLINE (<*>) #-}

instance MonadTrans (Stream a) where
    lift = Stream (return . Done)
    {-# INLINE lift #-}

-- | Map over the values produced by a stream.
--
-- >>> mapS (+1) (fromList [1..3]) :: Stream Int Identity ()
-- Stream [2,3,4]
mapS :: Functor m => (a -> b) -> Stream a m r -> Stream b m r
mapS f (Stream s i) = Stream (fmap go . s) i
  where
    go (Done r)     = Done r
    go (Skip s')    = Skip s'
    go (Yield s' a) = Yield s' (f a)
{-# INLINE mapS #-}

concatS :: Monad m => Stream (Stream a m r) m r -> Stream a m r
concatS (Stream xs i) =
    Stream (\case Left  s       -> xs s >>= go Nothing
                  Right (st, t) -> go (Just t) st)
           (Left `liftM` i)
  where
    go _ (Done r) = return $ Done r
    go _ (Skip s) = return $ Skip (Left s)

    go Nothing e@(Yield _ z)              = go (Just z) e
    go (Just (Stream ys j)) e@(Yield s _) = go' `liftM` (j >>= ys)
      where
        go' (Done _)    = Skip (Left s)
        go' (Skip s')   = Skip (Right (e, Stream ys (pure s')))
        go' (Yield s' a) = Yield (Right (e, Stream ys (pure s'))) a
{-# SPECIALIZE concatS :: Stream (Stream a IO r) IO r -> Stream a IO r #-}

fromList :: Applicative m => [a] -> Stream a m ()
fromList = Stream (\case []     -> pure $ Done ()
                         (x:xs) -> pure $ Yield xs x) . pure
{-# INLINE fromList #-}

reduceS :: Monad m => Stream a m r -> m r
reduceS (Stream f i) = i >>= f >>= go
  where
    go (Done r)    = return r
    go (Skip s)    = f s >>= go
    go (Yield s _) = f s >>= go
{-# INLINE reduceS #-}

toListS :: Monad m => Stream a m r -> m [a]
toListS (Stream f i) = i >>= f >>= go
  where
    go (Done _)   = return []
    go (Skip s)    = f s >>= go
    go (Yield s a) = f s >>= liftM (a:) . go
{-# INLINE toListS #-}

emptyStream :: Monad m => Stream Void m ()
emptyStream = pure ()
{-# INLINE emptyStream #-}

-- StreamList

newtype StreamList m a = StreamList { getStreamList :: Stream a m () }

instance Functor m => Functor (StreamList m) where
    fmap f (StreamList s) = StreamList $ mapS f s
    {-# INLINE fmap #-}

instance Monad m => Applicative (StreamList m) where
    pure = return
    {-# INLINE pure #-}
    (<*>) = ap
    {-# INLINE (<*>) #-}

instance Monad m => Monad (StreamList m) where
    return x = StreamList $
        Stream (\case True  -> return $ Yield False x
                      False -> return $ Done ())
               (return True)
    {-# INLINE return #-}
    m >>= f = concatSL $ fmap f m
    {-# INLINE (>>=) #-}

concatSL :: Monad m => StreamList m (StreamList m a) -> StreamList m a
concatSL = StreamList . concatS . getStreamList . fmap getStreamList
{-# INLINE concatSL #-}

toListSL :: forall m a. Monad m => StreamList m a -> m [a]
toListSL (StreamList (Stream f i)) = i >>= f >>= go
  where
    go (Done ())   = return []
    go (Skip s)    = f s >>= go
    go (Yield s a) = f s >>= liftM (a:) . go
{-# SPECIALIZE toListSL :: StreamList IO a -> IO [a] #-}

-- | This does the same as toListSL, but uses 'unsafeInterleaveIO'.
toListSL' :: StreamList IO a -> IO [a]
toListSL' (StreamList (Stream f i)) = i >>= f >>= go
  where
    go (Done ())   = return []
    go (Skip s)    = f s >>= go
    go (Yield s a) = f s >>= liftM (a:) . unsafeInterleaveIO . go

eachM :: (Monad m, Foldable f) => m (f a) -> StreamList m a
eachM xs = StreamList $ Stream (\case []     -> return $ Done ()
                                      (y:ys) -> return $ Yield ys y)
                           (toList <$> xs)
{-# INLINE eachM #-}

-- Pipes

type Producer   b m r = Stream Void m () -> Stream b    m r
type Pipe     a b m r = Stream a    m () -> Stream b    m r
type Consumer a   m r = Stream a    m () -> Stream Void m r
type Effect       m r = Stream Void m () -> Stream Void m r

runEffect :: Monad m => Effect m r -> m r
runEffect f = reduceS (f emptyStream)
{-# INLINE runEffect #-}

each :: (Monad m, Foldable f) => f a -> Producer a m ()
each xs = const $ Stream (\case []     -> return $ Done ()
                                (y:ys) -> return $ Yield ys y)
                         (return (toList xs))
{-# INLINE each #-}

map :: Monad m => (a -> b) -> Pipe a b m ()
map f xs = getStreamList $ fmap f (StreamList xs)
{-# INLINE map #-}

collect :: Monad m => Consumer a m [a]
collect xs = lift $ toListSL (StreamList xs)
{-# INLINE collect #-}

toListM :: Monad m => Producer a m () -> m [a]
toListM xs = toListSL (StreamList (xs emptyStream))
{-# INLINE toListM #-}

lazyToListM :: Producer a IO () -> IO [a]
lazyToListM xs = toListSL' (StreamList (xs emptyStream))
{-# INLINE lazyToListM #-}
