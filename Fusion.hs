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
    , Stream(..), map, filter, drop, take, concat, linesUnbounded
    , runStream, runStream', bindStream, applyStream, stepStream
    , foldlStream, foldlStreamM
    , foldrStream, foldrStreamM, lazyFoldrStreamIO
    , fromList, fromListM, toListM, lazyToListIO
    , emptyStream, next
    , bracketS, streamFile
    -- * StreamList
    , ListT(..), concatL
    -- * Pipes
    , Producer, Pipe, Consumer {-, pipe-}
    , each
    , (>->), (>&>)
    )
    where

import           Control.Applicative
import           Control.Concurrent.Async.Lifted
import           Control.Concurrent.STM
import           Control.Monad
import           Control.Monad.Catch
import           Control.Monad.IO.Class
import           Control.Monad.Trans.Class
import           Control.Monad.Trans.Control
import           Control.Monad.Trans.Free
import           Data.ByteString (ByteString)
import qualified Data.ByteString as B
import qualified Data.Foldable as F
import           Data.Function
import           Data.Functor.Identity
import           Data.Text (Text)
import qualified Data.Text as T
--import qualified Data.Text.Encoding as T
import           Data.Void
import           GHC.Exts hiding (fromList, toList)
import           Pipes.Safe (SafeT, MonadSafe(..))
import           Prelude hiding (map, concat, filter, take, drop, lines)
import           System.IO
import           System.IO.Unsafe

-- import qualified Pipes as P
-- import qualified Pipes.Internal as P

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

instance (Monad m, Applicative m) => Monad (Stream a m) where
    {-# SPECIALIZE instance Monad (Stream a IO) #-}
    return = Stream (return . Done)
    {-# INLINE_FUSED return #-}
    Stream step i >>= f = Stream step' (i, Nothing)
      where
        {-# INLINE_INNER step' #-}
        step' (s, Nothing) = step s >>= \case
            Done r     -> step' (s, Just (f r))
            Skip s'    -> return $ Skip (s', Nothing)
            Yield s' a -> return $ Yield (s', Nothing) a

        step' (old, Just (Stream step'' s)) = step'' s <&> \case
            Done r     -> Done r
            Skip s'    -> Skip (old, Just (Stream step'' s'))
            Yield s' a -> Yield (old, Just (Stream step'' s')) a
    {-# INLINE_FUSED (>>=) #-}

instance MonadThrow m => MonadThrow (Stream a m) where
    throwM e = Stream (\_ -> throwM e) ()
    {-# INLINE_FUSED throwM #-}

instance MonadCatch m => MonadCatch (Stream a m) where
    catch (Stream step i) c = Stream step' (i, Nothing)
      where
        {-# INLINE_INNER step' #-}
        step' (s, Nothing) = go `catch` \e -> step' (s, Just (c e))
          where
            {-# INLINE_INNER go #-}
            go = step s <&> \case
                Done r     -> Done r
                Skip s'    -> Skip (s', Nothing)
                Yield s' a -> Yield (s', Nothing) a

        step' (old, Just (Stream step'' s)) = step'' s <&> \case
            Done r     -> Done r
            Skip s'    -> Skip (old, Just (Stream step'' s'))
            Yield s' a -> Yield (old, Just (Stream step'' s')) a
    {-# INLINE_FUSED catch #-}
-- #if MIN_VERSION_exceptions(0,6,0)

instance MonadMask m => MonadMask (Stream a m) where
-- #endif
    mask action = Stream step' Nothing
      where
        step' Nothing = mask $ \unmask ->
            step' $ Just $ action $ \(Stream step s) -> Stream (unmask . step) s
        step' (Just (Stream step'' i'')) = step'' i'' <&> \case
            Done r     -> Done r
            Skip s'    -> Skip (Just (Stream step'' s'))
            Yield s' a -> Yield (Just (Stream step'' s')) a
    {-# INLINE mask #-}
    uninterruptibleMask action = Stream step' Nothing
      where
        step' Nothing = mask $ \unmask ->
            step' $ Just $ action $ \(Stream step s) -> Stream (unmask . step) s
        step' (Just (Stream step'' i'')) = step'' i'' <&> \case
            Done r     -> Done r
            Skip s'    -> Skip (Just (Stream step'' s'))
            Yield s' a -> Yield (Just (Stream step'' s')) a
    {-# INLINEABLE uninterruptibleMask #-}

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

take :: Applicative m => Int -> Stream a m r -> Stream a m ()
take n (Stream step i) = Stream step' (i, n)
  where
    {-# INLINE_INNER step' #-}
    step' (_, 0)  = pure $ Done ()
    step' (s, n') = step s <&> \case
        Yield s' a -> Yield (s', n' - 1) a
        Skip  s'   -> Skip (s', n')
        Done  _    -> Done ()
{-# INLINE_FUSED take #-}

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

linesUnbounded :: Applicative m => Stream Text m r -> Stream Text m r
linesUnbounded (Stream step i) = Stream step' (Left (i, id))
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
{-# INLINE_FUSED linesUnbounded #-}

lines :: (Monad m, Functor f)
      => (FreeT (Stream Text m) m r -> f (FreeT (Stream Text m) m r))
      -> Stream Text m r -> f (Stream Text m r)
lines k p = fmap _unlines (k (_lines p))
{-# INLINE lines #-}

_lines :: Monad m => Stream Text m r -> FreeT (Stream Text m) m r
_lines (Stream step i) = FreeT (go (step i))
    where
      go p = p >>= \case
          Done  r    -> return $ Pure r
          Skip  s'   -> go (step s')
          Yield s' a ->
              if T.null a
              then go (step s')
              else let (a',b') = T.break (== '\n') a in
                   return $ Free $ Stream step' s'
      step' = undefined
{-# INLINABLE _lines #-}

_unlines :: Monad m => FreeT (Stream Text m) m r -> Stream Text m r
-- _unlines = concat . map (<* return (T.singleton '\n'))
_unlines = undefined
{-# INLINABLE _unlines #-}

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

streamFile :: (MonadIO m, MonadMask (Base m), MonadSafe m)
           => FilePath -> Stream ByteString m ()
streamFile path = bracketS
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
type Pipe     a b m r = Stream a m r -> Stream b m r
type Consumer a   m r = Stream a m () -> m r

each :: (Applicative m, F.Foldable f) => f a -> Producer a m ()
each = fromList
{-# INLINE_FUSED each #-}

(>->) :: Stream a m r -> (Stream a m r -> Stream b m r) -> Stream b m r
f >-> g = g f
{-# INLINE_FUSED (>->) #-}

{-
pipe :: Monad m => P.Proxy () a () b m r -> Pipe a b m r
pipe p0 (Stream step i) = Stream step' (i, p0)
  where
    step' (s, p) = case p of
        P.Request () fa -> step s >>= \case
            Done r     -> return $ Done r
            Skip s'    -> return $ Skip (s', p)
            Yield s' a -> step' (s', fa a)
        P.Respond b  f_ -> return $ Yield (s, f_ ()) b
        P.M       m     -> m >>= \p' -> step' (s, p')
        P.Pure    r     -> return $ Done r
{-# INLINE_FUSED pipe #-}
-}

{-
newtype Pipe a b m r = Pipe { pipe :: Stream a m () -> Stream b m r }
    deriving Functor

instance Monad m => Applicative (Pipe a b m) where
    pure  = return
    {-# INLINE pure  #-}
    (<*>) = ap
    {-# INLINE (<*>)  #-}

{-
foo = do
    x <- await
    yield (x + 10)
    yield (x + 20)
    yield (x + 30)
    y <- await
    yield (y + 100)
    z <- await
    yield (z + 1000)
    foo
-}

foo :: Applicative m => Stream Int m r -> Stream Int m r
foo (Stream step i) = Stream step' (Left i, 0 :: Int)
  where
    {-# INLINE_INNER step' #-}
    step' (Right (s, [x]),  n) = pure $ Yield (Left s, n) x
    step' (Right (s, x:xs), n) = pure $ Yield (Right (s, xs), n) x

    step' (Left s, 0) = step s <&> \case
        Done r     -> Done r
        Skip s'    -> Skip (Left s', 0)
        Yield s' x -> Yield (Right (s', [x + 20, x + 30]), 1) (x + 10)

    step' (Left s, 1) = step s <&> \case
        Done r     -> Done r
        Skip s'    -> Skip (Left s', 1)
        Yield s' y -> Yield (Left s', 2) (y + 100)

    step' (Left s, 2) = step s <&> \case
        Done r     -> Done r
        Skip s'    -> Skip (Left s', 2)
        Yield s' z -> Yield (Left s', 0) (z + 1000)
{-# INLINE foo #-}

instance Monad m => Monad (Pipe a b m) where
    return x = Pipe $ \_ -> pure x
    {-# INLINE return #-}
    Pipe p >>= f = Pipe $ \(Stream step i) -> Stream (step' step) i
      where
        {-# INLINE_INNER step' #-}
        step' step s = step s >>= \case
            Done r     -> _
                -- let Pipe g = f r in
                -- case g undefined of
                --     Stream step'' i'' -> step'' s >>= \case
                --         Done r     -> Done r
                --         Skip s'    -> pure $ Skip s'
                --         Yield s' a -> _
            Skip s'    -> pure $ Skip s'
            Yield s' a -> pure $ Yield s' a
    {-# INLINE (>>=) #-}

await :: Functor m => Pipe a b m a
await = Pipe $ \(Stream step i) -> Stream (step' step) i
  where
    step' step s = step s <&> \case
        Done r     -> error "Upstream has ended"
        Skip s'    -> Skip s'
        Yield s' x -> Done x

yield :: Applicative m => b -> Pipe a b m ()
yield b = Pipe $ \_ ->
    Stream (\case True  -> pure (Yield False b)
                  False -> pure (Done ())) True
-}

{-
bar :: Monad m => P.Proxy () Int () Int m r
bar = do
    x <- P.await
    P.yield (x + 10)
    P.yield (x + 20)
    P.yield (x + 30)
    y <- P.await
    P.yield (y + 100)
    z <- P.await
    P.yield (z + 1000)
    bar

main :: IO ()
main = do
    xs <- toListM $ take 10 $ pipe bar $ each ([1..1000] :: [Int])
    print xs
-}

-- | Connect two streams, but gather elements from upstream in a separate
-- thread. Exceptions raised in that thread are propagated back to the main
-- thread. A bounded buffer is used of 16 elements.
--
-- Note that monadic effects from upstream are discarded. This is acceptable
-- if effects propagate beyond the thread, such as in 'IO', but does prevent
-- 'StateT' changes from being seen downstream, for example.
(>&>) :: (MonadBaseControl IO m, MonadIO m, MonadMask m)
      => Stream a m r -> (Stream a m r -> Stream b m r) -> Stream b m r
Stream step i >&> k = k $ Stream step' $ do
    q <- liftIO $ newTBQueueIO 16
    mask $ \unmask -> do
        a <- unmask $ async $ flip fix i $ \loop s -> step s >>= \case
            Done r     -> liftIO $ atomically $ writeTBQueue q (Left r)
            Skip s'    -> loop s'
            Yield s' a -> do
                liftIO $ atomically $ writeTBQueue q (Right a)
                loop s'
        link a
    return q
  where
    {-# INLINE_INNER step' #-}
    step' s = s >>= \q -> liftIO (atomically (readTBQueue q)) <&> \case
        Left r  -> Done r
        Right a -> Yield (return q) a
{-# INLINE_FUSED (>&>) #-}
