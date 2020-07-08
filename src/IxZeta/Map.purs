module IxZeta.Map where

import Prelude
import Data.Maybe (Maybe (..))
import Data.Tuple (Tuple)
import Data.Profunctor.Strong (first)
import Effect (Effect)
import Effect.Ref (Ref)
import Effect.Ref (new, read, write) as Ref
import IxQueue (IxQueue)
import IxQueue (broadcast, new, on, del) as IxQueue
import Queue.Types (READ, WRITE) as Q
import Zeta.Types (READ, WRITE, kind SCOPE) as S
import Foreign.Object (Object)
import Foreign.Object (empty, lookup, delete, insert, toUnfoldable) as Object


-- | Represents only atomic changes to a mapping
data MapUpdate key value
  = MapInsert { key :: key, valueNew :: value }
  | MapUpdate { key :: key, valueOld :: value, valueNew :: value }
  | MapDelete { key :: key, valueOld :: value }

newtype IxSignalMap key ( rw :: # S.SCOPE ) value = IxSignalMap
  { fromString :: String -> key
  , toString :: key -> String
  , state :: Ref (Object value)
  , queue :: IxQueue (read :: Q.READ, write :: Q.WRITE) (MapUpdate key value)
  }

new :: forall key value. { fromString :: String -> key, toString :: key -> String } -> Effect (IxSignalMap key (read :: S.READ, write :: S.WRITE) value)
new {fromString, toString} = do
  queue <- IxQueue.new
  state <- Ref.new Object.empty
  pure $ IxSignalMap
    { fromString
    , toString
    , state
    , queue
    }

get :: forall key value rw. key -> IxSignalMap key (read :: S.READ | rw) value -> Effect (Maybe value)
get key (IxSignalMap {toString, state}) = do
  Object.lookup (toString key) <$> Ref.read state

getAll :: forall key value rw. IxSignalMap key (read :: S.READ | rw) value -> Effect (Array (Tuple key value))
getAll (IxSignalMap {fromString, state}) = do
  (map (first fromString) <<< Object.toUnfoldable) <$> Ref.read state

set :: forall key value rw. key -> value -> IxSignalMap key (write :: S.WRITE | rw) value -> Effect Unit
set key value (IxSignalMap {toString, state, queue}) = do
  state' <- Ref.read state
  let k = toString key
  Ref.write (Object.insert k value state') state
  let up = case Object.lookup k state' of
        Nothing -> MapInsert {key, valueNew: value}
        Just valueOld -> MapUpdate {key, valueOld, valueNew: value}
  IxQueue.broadcast queue up

update :: forall key value rw. key -> (value -> value) -> IxSignalMap key (write :: S.WRITE | rw) value -> Effect Unit
update key f (IxSignalMap {toString, state, queue}) = do
  state' <- Ref.read state
  let k = toString key
  case Object.lookup k state' of
    Nothing -> pure unit
    Just valueOld -> do
      let valueNew = f valueOld
      Ref.write (Object.insert k valueNew state') state
      IxQueue.broadcast queue (MapUpdate {key, valueOld, valueNew})

delete :: forall key value rw. key -> IxSignalMap key (write :: S.WRITE | rw) value -> Effect Unit
delete key (IxSignalMap {toString, state, queue}) = do
  state' <- Ref.read state
  let k = toString key
  case Object.lookup k state' of
    Nothing -> pure unit
    Just valueOld -> do
      Ref.write (Object.delete k state') state
      IxQueue.broadcast queue (MapDelete {key, valueOld})

subscribeLight :: forall key value rw. String -> (MapUpdate key value -> Effect Unit) -> IxSignalMap key (read :: S.READ | rw) value -> Effect Unit
subscribeLight index f (IxSignalMap {queue}) = IxQueue.on queue index f

unsubscribe :: forall key value rw. String -> IxSignalMap key (read :: S.READ | rw) value -> Effect Boolean
unsubscribe index (IxSignalMap {queue}) = IxQueue.del queue index