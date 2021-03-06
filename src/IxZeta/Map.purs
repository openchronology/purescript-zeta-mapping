module IxZeta.Map where

import Prelude
import Data.Maybe (Maybe (..))
import Data.Tuple (Tuple (..))
import Data.Profunctor.Strong (first)
import Data.Generic.Rep (class Generic)
import Effect (Effect)
import Effect.Ref (Ref)
import Effect.Ref (new, read, write) as Ref
import IxQueue (IxQueue)
import IxQueue (broadcast, broadcastExcept, new, on, del) as IxQueue
import Queue.Types (READ, WRITE) as Q
import Zeta.Types (READ, WRITE, kind SCOPE, class SignalScope) as S
import Foreign.Object (Object)
import Foreign.Object (empty, lookup, delete, insert, toUnfoldable) as Object


-- | Represents only atomic changes to a mapping
data MapUpdate value
  = MapInsert { valueNew :: value }
  | MapUpdate { valueOld :: value, valueNew :: value }
  | MapDelete { valueOld :: value }

derive instance genericMapUpdate :: (Generic value value') => Generic (MapUpdate value) _

instance eqMapUpdate :: (Eq value) => Eq (MapUpdate value) where
  eq x y = case Tuple x y of
    Tuple (MapInsert x') (MapInsert y') -> x'.valueNew == y'.valueNew
    Tuple (MapUpdate x') (MapUpdate y') -> x'.valueNew == y'.valueNew && x'.valueOld == y'.valueOld
    Tuple (MapDelete x') (MapDelete y') -> x'.valueOld == y'.valueOld
    _ -> false

instance showMapUpdate :: (Show value) => Show (MapUpdate value) where
  show x = case x of
    MapInsert {valueNew} -> "(MapInsert {alueNew: " <> show valueNew <> "})"
    MapUpdate {valueNew,valueOld} -> "(MapUpdate {valueOld: " <> show valueOld <> ", valueNew: " <> show valueNew <> "})"
    MapDelete {valueOld} -> "(MapDelete {valueOld: " <> show valueOld <> "})"

newtype IxSignalMap key ( rw :: # S.SCOPE ) value = IxSignalMap
  { fromString :: String -> key
  , toString :: key -> String
  , state :: Ref (Object value)
  , queue :: IxQueue (read :: Q.READ, write :: Q.WRITE) (Tuple key (MapUpdate value))
  }

instance signalScopeIxSignalMap :: S.SignalScope (IxSignalMap key) where
  readOnly (IxSignalMap x) = IxSignalMap x
  writeOnly (IxSignalMap x) = IxSignalMap x
  allowReading (IxSignalMap x) = IxSignalMap x
  allowWriting (IxSignalMap x) = IxSignalMap x

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

-- | Updates when already existing
assign :: forall key value rw. key -> value -> IxSignalMap key (write :: S.WRITE | rw) value -> Effect Unit
assign key value (IxSignalMap {toString, state, queue}) = do
  state' <- Ref.read state
  let k = toString key
  Ref.write (Object.insert k value state') state
  let up = case Object.lookup k state' of
        Nothing -> Tuple key (MapInsert {valueNew: value})
        Just valueOld -> Tuple key (MapUpdate {valueOld, valueNew: value})
  IxQueue.broadcast queue up

assignExcept :: forall key value rw. Array String -> key -> value -> IxSignalMap key (write :: S.WRITE | rw) value -> Effect Unit
assignExcept indicies key value (IxSignalMap {toString, state, queue}) = do
  state' <- Ref.read state
  let k = toString key
  Ref.write (Object.insert k value state') state
  let up = case Object.lookup k state' of
        Nothing -> Tuple key (MapInsert {valueNew: value})
        Just valueOld -> Tuple key (MapUpdate {valueOld, valueNew: value})
  IxQueue.broadcastExcept queue indicies up

-- | Only inserts, does not update existing values
insert :: forall key value rw. key -> value -> IxSignalMap key (write :: S.WRITE | rw) value -> Effect Boolean
insert key value (IxSignalMap {toString, state, queue}) = do
  state' <- Ref.read state
  let k = toString key
  case Object.lookup k state' of
    Just _ -> pure false
    Nothing -> do
      Ref.write (Object.insert k value state') state
      IxQueue.broadcast queue (Tuple key (MapInsert {valueNew: value}))
      pure true

insertExcept :: forall key value rw. Array String -> key -> value -> IxSignalMap key (write :: S.WRITE | rw) value -> Effect Boolean
insertExcept indicies key value (IxSignalMap {toString, state, queue}) = do
  state' <- Ref.read state
  let k = toString key
  case Object.lookup k state' of
    Just _ -> pure false
    Nothing -> do
      Ref.write (Object.insert k value state') state
      IxQueue.broadcastExcept queue indicies (Tuple key (MapInsert {valueNew: value}))
      pure true

update :: forall key value rw. key -> (value -> value) -> IxSignalMap key (write :: S.WRITE | rw) value -> Effect Boolean
update key f (IxSignalMap {toString, state, queue}) = do
  state' <- Ref.read state
  let k = toString key
  case Object.lookup k state' of
    Nothing -> pure false
    Just valueOld -> do
      let valueNew = f valueOld
      Ref.write (Object.insert k valueNew state') state
      IxQueue.broadcast queue (Tuple key (MapUpdate {valueOld, valueNew}))
      pure true

updateExcept :: forall key value rw. Array String -> key -> (value -> value) -> IxSignalMap key (write :: S.WRITE | rw) value -> Effect Boolean
updateExcept indicies key f (IxSignalMap {toString, state, queue}) = do
  state' <- Ref.read state
  let k = toString key
  case Object.lookup k state' of
    Nothing -> pure false
    Just valueOld -> do
      let valueNew = f valueOld
      Ref.write (Object.insert k valueNew state') state
      IxQueue.broadcastExcept queue indicies (Tuple key (MapUpdate {valueOld, valueNew}))
      pure true

delete :: forall key value rw. key -> IxSignalMap key (write :: S.WRITE | rw) value -> Effect Boolean
delete key (IxSignalMap {toString, state, queue}) = do
  state' <- Ref.read state
  let k = toString key
  case Object.lookup k state' of
    Nothing -> pure false
    Just valueOld -> do
      Ref.write (Object.delete k state') state
      IxQueue.broadcast queue (Tuple key (MapDelete {valueOld}))
      pure true

deleteExcept :: forall key value rw. Array String -> key -> IxSignalMap key (write :: S.WRITE | rw) value -> Effect Boolean
deleteExcept indicies key (IxSignalMap {toString, state, queue}) = do
  state' <- Ref.read state
  let k = toString key
  case Object.lookup k state' of
    Nothing -> pure false
    Just valueOld -> do
      Ref.write (Object.delete k state') state
      IxQueue.broadcastExcept queue indicies (Tuple key (MapDelete {valueOld}))
      pure true

subscribeLight :: forall key value rw. String -> (Tuple key (MapUpdate value) -> Effect Unit) -> IxSignalMap key (read :: S.READ | rw) value -> Effect Unit
subscribeLight index f (IxSignalMap {queue}) = IxQueue.on queue index f

unsubscribe :: forall key value rw. String -> IxSignalMap key (read :: S.READ | rw) value -> Effect Boolean
unsubscribe index (IxSignalMap {queue}) = IxQueue.del queue index
