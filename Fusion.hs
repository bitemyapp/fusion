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
    , Stream(..), mapS, concatS, fromList, fromListM
    , toListS, lazyToListS, runEffect, emptyStream
    , bracketS, next
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

instance (Monad m, Applicative m) => Applicative (Stream a m) where
    pure x = Stream (pure . Done) (pure x)
    {-# INLINE pure #-}
    sf <*> sx = Stream (pure . Done) (runEffect sf <*> runEffect sx)
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
        go' (Skip s')   = Skip (Right (e, Stream ys (return s')))
        go' (Yield s' a) = Yield (Right (e, Stream ys (return s'))) a
{-# SPECIALIZE concatS :: Stream (Stream a IO r) IO r -> Stream a IO r #-}

fromList :: Foldable f => Applicative m => f a -> Stream a m ()
fromList = Stream (\case []     -> pure $ Done ()
                         (x:xs) -> pure $ Yield xs x) . pure . toList
{-# INLINE fromList #-}

fromListM :: (Monad m, Foldable f) => m (f a) -> Stream a m ()
fromListM xs = Stream (\case []     -> return $ Done ()
                             (y:ys) -> return $ Yield ys y)
                      (toList `liftM` xs)
{-# INLINE fromListM #-}

runEffect :: Monad m => Stream a m r -> m r
runEffect (Stream f i) = i >>= f >>= go
  where
    go (Done r)    = return r
    go (Skip s)    = f s >>= go
    go (Yield s _) = f s >>= go
{-# INLINE runEffect #-}

toListS :: Monad m => Stream a m r -> m [a]
toListS (Stream f i) = i >>= f >>= go
  where
    go (Done _)   = return []
    go (Skip s)    = f s >>= go
    go (Yield s a) = f s >>= liftM (a:) . go
{-# INLINE toListS #-}

lazyToListS :: Stream a IO r -> IO [a]
lazyToListS (Stream f i) = i >>= f >>= go
  where
    go (Done _)   = return []
    go (Skip s)    = f s >>= go
    go (Yield s a) = f s >>= liftM (a:) . unsafeInterleaveIO . go
{-# INLINE lazyToListS #-}

emptyStream :: (Monad m, Applicative m) => Stream Void m ()
emptyStream = pure ()
{-# INLINE emptyStream #-}

bracketS :: (Monad m, MonadMask m, MonadSafe m)
         => Base m s
         -> (s -> Base m ())
         -> (forall r. s -> (a -> s -> m r) -> (s -> m r) -> m r -> m r)
         -> Stream a m ()
bracketS i f step = Stream go $ mask $ \_unmask -> do
    s   <- liftBase i
    key <- register (f s)
    return (s, key)
  where
    go (s, key) =
        step s (\a s' -> return $ Yield (s', key) a)
               (\s'   -> return $ Skip (s', key))
               (release key >> (const (Done ()) `liftM` liftBase (f s)))
{-
{-# SPECIALIZE bracketS
      :: IO s
      -> (s -> IO ())
      -> (forall r. s -> (a -> s -> SafeT IO r)
           -> (s -> SafeT IO r)
           -> SafeT IO r
           -> SafeT IO r)
      -> Stream a (SafeT IO) () #-}
-}

next :: Monad m => Stream a m r -> m (Either r (a, Stream a m r))
next (Stream xs i) = do
    s <- i
    x <- xs s
    case x of
        Done r     -> return $ Left r
        Skip s'    -> next (Stream xs (return s'))
        Yield s' a -> return $ Right (a, Stream xs (return s'))
{-# SPECIALIZE next :: Stream a IO r -> IO (Either r (a, Stream a IO r)) #-}

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
