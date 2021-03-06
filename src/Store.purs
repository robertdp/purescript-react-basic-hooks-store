module React.Store
  ( Instance
  , Spec
  , Store
  , UseStore
  , useStore
  , Instance'
  , Spec'
  , UseStore'
  , useStore'
  ) where

import Prelude
import Control.Monad.Rec.Class (forever)
import Data.Bitraversable (ltraverse)
import Data.Either (Either)
import Data.Newtype (class Newtype)
import Data.Tuple.Nested ((/\))
import Effect (Effect)
import Effect.AVar (AVar)
import Effect.AVar as AVar
import Effect.Aff (Aff, Error)
import Effect.Aff as Aff
import Effect.Aff.AVar as AffVar
import Effect.Class (class MonadEffect, liftEffect)
import Effect.Class.Console as Console
import Effect.Ref (Ref)
import Effect.Ref as Ref
import Effect.Unsafe (unsafePerformEffect)
import React.Basic.Hooks (Hook, UseEffect, UseMemo, UseState)
import React.Basic.Hooks as React

-- | A stores internal interface, only accessible inside the `update` function.
type Instance props state m
  = { props :: props
    , state :: state
    , setState :: (state -> state) -> m Unit
    , readProps :: m props
    , readState :: m state
    }

type Instance' state m
  = Instance Unit state m

-- | The spec required to configure and run a store.
type Spec props state action m
  = { props :: props
    , init :: state
    , update :: Instance props state m -> action -> m Unit
    , launch :: m Unit -> Aff Unit
    }

type Spec' state action m
  = { init :: state
    , update :: Instance' state m -> action -> m Unit
    , launch :: m Unit -> Aff Unit
    }

-- | A stores external interface, returned from `useStore`.
type Store state action
  = { state :: state
    , dispatch :: action -> Effect Unit
    , readState :: Effect state
    }

newtype UseStore props state action m hooks
  = UseStore
  ( UseEffect Unit
      ( UseState (Store state action)
          ( UseEffect Unit
              ( UseMemo Unit
                  { actionQueue :: AVar action
                  , specRef :: Ref (Spec props state action m)
                  , stateRef :: Ref state
                  }
                  hooks
              )
          )
      )
  )

derive instance newtypeUseStore :: Newtype (UseStore props state action hooks m) _

type UseStore' state action hooks m
  = UseStore Unit state action hooks m

useStore ::
  forall props state action m.
  MonadEffect m =>
  Spec props state action m ->
  Hook (UseStore props state action m) (Store state action)
useStore spec =
  React.coerceHook React.do
    { actionQueue, specRef, stateRef } <-
      React.useMemo unit \_ ->
        unsafePerformEffect ado
          -- A variable so the main store loop can subscribe to asynchronous actions sent from the component
          actionQueue <- AVar.empty
          -- A mutable version of the spec that gets constantly updated for access inside the fiber
          specRef <- Ref.new spec
          -- Internal mutable state for fast reads that don't need to touch React state
          stateRef <- Ref.new spec.init
          in { actionQueue, specRef, stateRef }
    React.useEffectAlways do
      -- keep the spec constantly up-to-date, so the next action is using the latest values
      Ref.write spec specRef
      mempty
    store /\ modifyStore <-
      React.useState
        { dispatch:
            -- sends actions to the bus asynchronously
            \action -> Aff.launchAff_ do Aff.attempt do AffVar.put action actionQueue
        , readState: Ref.read stateRef
        , state: spec.init
        }
    React.useEffectOnce do
      let
        readProps :: forall n. MonadEffect n => n props
        readProps = liftEffect do _.props <$> Ref.read specRef

        readState :: forall n. MonadEffect n => n state
        readState = liftEffect do Ref.read stateRef

        setState :: (state -> state) -> m Unit
        setState f =
          liftEffect do
            state <- Ref.modify f stateRef
            modifyStore _ { state = state }
      -- This is the main loop. It waits for an action to come in over the bus and then runs the `update` function from
      -- the spec in a forked fiber. State updates are applied to the local mutable state and pushed back to React for
      -- rendering. This continues until the action bus is shut down, causing the main loop to terminate and all child
      -- fibers to be cleaned up.
      -- - `forever` will cause it to loop indefinitely
      -- - `supervise` will clean up forked child fibers when the main fiber is shutdown
      -- - `attempt` will prevent the shutdown from logging an error
      fiber <-
        (Aff.launchAff <<< Aff.attempt <<< Aff.supervise <<< forever) do
          action <- AffVar.take actionQueue
          -- We log these errors because they are created by the `update` function
          (Aff.forkAff <<< logError <<< Aff.attempt) do
            { props, update, launch } <- liftEffect do Ref.read specRef
            state <- readState
            let
              store' =
                { props
                , readProps
                , readState
                , setState
                , state
                }
            launch do update store' action
      pure do
        let
          message = Aff.error "Unmounting"
        -- When the component unmounts, trigger the main loop shutdown by killing the action bus.
        Aff.launchAff_ do Aff.killFiber message fiber
        AVar.kill message actionQueue
    pure store

useStore' ::
  forall m state action.
  MonadEffect m =>
  Spec' state action m ->
  Hook (UseStore' state action m) (Store state action)
useStore' { init, update, launch } = useStore { props: unit, init, update, launch }

logError :: forall m a. MonadEffect m => m (Either Error a) -> m Unit
logError ma = void $ ma >>= ltraverse Console.errorShow
