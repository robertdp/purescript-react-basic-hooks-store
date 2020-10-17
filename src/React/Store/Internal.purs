module React.Store.Internal where

import Prelude
import Control.Applicative.Free (FreeAp, hoistFreeAp, retractFreeAp)
import Control.Monad.Free (Free, liftF, runFreeM)
import Control.Monad.Resource (ReleaseKey, Resource)
import Control.Monad.Resource as Resource
import Control.Monad.State (class MonadState)
import Control.Monad.Trans.Class (class MonadTrans, lift)
import Data.Bifunctor (lmap)
import Data.Foldable (sequence_)
import Data.Maybe (Maybe(..))
import Data.Tuple (Tuple(..))
import Effect (Effect)
import Effect.Aff (Aff, parallel, sequential)
import Effect.Aff as Aff
import Effect.Aff.Class (class MonadAff, liftAff)
import Effect.Class (class MonadEffect, liftEffect)
import Effect.Ref (Ref)
import Effect.Ref as Ref

newtype EventSource a
  = EventSource ((a -> Effect Unit) -> Effect (Effect Unit))

data StoreF state action m a
  = State (state -> Tuple a state)
  | Subscribe (ReleaseKey -> EventSource action) (ReleaseKey -> a)
  | Unsubscribe ReleaseKey a
  | Lift (m a)
  | Par (ComponentAp state action m a)
  | Fork (ComponentM state action m Unit) (ReleaseKey -> a)
  | Kill ReleaseKey a

instance functorStoreF :: Functor m => Functor (StoreF state action m) where
  map f = case _ of
    State k -> State (lmap f <<< k)
    Subscribe fes k -> Subscribe fes (map f k)
    Unsubscribe sid a -> Unsubscribe sid (f a)
    Lift m -> Lift (map f m)
    Par m -> Par (map f m)
    Fork m k -> Fork m (map f k)
    Kill fid a -> Kill fid (f a)

newtype ComponentM state action m a
  = ComponentM (Free (StoreF state action m) a)

derive newtype instance functorComponentM :: Functor (ComponentM state action m)

derive newtype instance applyComponentM :: Apply (ComponentM state action m)

derive newtype instance applicativeComponentM :: Applicative (ComponentM state action m)

derive newtype instance bindComponentM :: Bind (ComponentM state action m)

derive newtype instance monadComponentM :: Monad (ComponentM state action m)

instance monadTransComponentM :: MonadTrans (ComponentM state action) where
  lift x = ComponentM (liftF (Lift x))

instance monadEffectComponentM :: MonadEffect m => MonadEffect (ComponentM state action m) where
  liftEffect x = lift (liftEffect x)

instance monadAffComponentM :: MonadAff m => MonadAff (ComponentM state action m) where
  liftAff x = lift (liftAff x)

instance monadStateComponentM :: MonadState state (ComponentM state action m) where
  state x = ComponentM (liftF (State x))

newtype ComponentAp state action m a
  = ComponentAp (FreeAp (ComponentM state action m) a)

derive newtype instance functorComponentAp :: Functor (ComponentAp state action m)

derive newtype instance applyComponentAp :: Apply (ComponentAp state action m)

derive newtype instance applicativeComponentAp :: Applicative (ComponentAp state action m)

data Lifecycle props action
  = Initialize props
  | Update props
  | Action action
  | Finalize

evalComponent :: forall state action a. Ref state -> (action -> Effect Unit) -> ComponentM state action Aff a -> Resource a
evalComponent stateRef enqueueAction (ComponentM store) = runFreeM interpret store
  where
  interpret = case _ of
    State f -> do
      liftEffect do
        state <- Ref.read stateRef
        case f state of
          Tuple next state' -> do
            Ref.write state' stateRef
            pure next
    Subscribe prepare next -> do
      canceler <- liftEffect $ Ref.new Nothing
      key <- Resource.register $ liftEffect $ Ref.read canceler >>= sequence_
      liftEffect do
        runCanceler <- case prepare key of EventSource subscribe -> subscribe enqueueAction
        Ref.write (Just runCanceler) canceler
      pure (next key)
    Unsubscribe key next -> do
      Resource.release key
      pure next
    Lift aff -> do
      lift aff
    Par (ComponentAp p) -> do
      sequential $ retractFreeAp $ hoistFreeAp (parallel <<< evalComponent stateRef enqueueAction) p
    Fork runFork next -> do
      fiber <- Resource.fork $ evalComponent stateRef enqueueAction runFork
      key <- Resource.register $ Aff.killFiber (Aff.error "Fiber killed") fiber
      pure (next key)
    Kill key next -> do
      Resource.release key
      pure next