module Sample where

import Control.Monad.Trans.State
import Fusion as F

bar :: Monad m => Stream Int (StateT (Stream Int m s) m) Int
bar = do
    mx <- await
    case mx of
        Nothing -> return 1
        Just x -> do
            yield (x + 10)
            yield (x + 20)
            yield (x + 30)
            my <- await
            case my of
                Nothing -> return 2
                Just y -> do
                    yield (y + 100)
                    mz <- await
                    case mz of
                        Nothing -> return 3
                        Just z -> do
                            yield (z + 1000)
                            return 4
{-# INLINEABLE bar #-}
{-# SPECIALIZE bar :: Stream Int (StateT (Stream Int IO s) IO) Int #-}

main :: IO ()
main = do
    xs <- toListM $ each [1..1000] >-> stateful bar >-> F.take 10
    print xs
