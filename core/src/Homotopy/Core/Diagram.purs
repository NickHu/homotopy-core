module Homotopy.Core.Diagram
  ( Diagram(..)
  , DiagramN
  , attach
  , checkEmbedding
  , cospans
  , dimension
  , enumerateEmbeddings
  , fromGenerator
  , identity
  , internalizeHeight
  , make
  , regularSlices
  , singularSlices
  , size
  , sliceAt
  , slices
  , source
  , target
  , toDiagramN
  , unsafeMake
  , rewriteForward
  , rewriteBackward
  ) where

import Control.MonadZero (empty, guard, (>>=))
import Data.Eq ((/=))
import Data.Foldable (foldM, foldl, length)
import Data.Generic.Rep (class Generic)
import Data.Generic.Rep.Show (genericShow)
import Data.Hashable (class Hashable, hash)
import Data.Lazy (Lazy, defer, force)
import Data.List (List(..), concatMap, drop, head, index, mapWithIndex, reverse, slice, tail, take, (:))
import Data.List.NonEmpty (NonEmptyList(..), scanl)
import Data.List.NonEmpty as NEL
import Data.Maybe (Maybe(..), fromMaybe, isJust, maybe)
import Data.Newtype (class Newtype, unwrap, wrap)
import Data.NonEmpty ((:|))
import Data.Tuple (Tuple(..), fst)
import Data.Unfoldable (replicate)
import Homotopy.Core.Common (Boundary(..), Generator, Height(..), SliceIndex(..))
import Homotopy.Core.Rewrite (Cospan, Rewrite(..), coneSize, cospanPad, cospanReverse, makeRewriteN)
import Partial.Unsafe (unsafePartial)
import Prelude (class Eq, class Show, Ordering(..), bind, compare, discard, join, map, otherwise, pure, ($), (&&), (*), (+), (-), (<), (<<<), (<>), (==), (>), (>=), (>>>))
import Unsafe.Reference (unsafeRefEq)

-- | A diagram is either 0-dimensional, in which case it consists of a
-- | generator, or n-dimensional (for n > 0), in which case it has a source
-- | $n-1$ diagram a list of (n - 1) cospans
data Diagram
  = Diagram0 Generator
  | DiagramN DiagramN

derive instance genericDiagram :: Generic Diagram _

instance showDiagram :: Show Diagram where
  show x = genericShow x

newtype DiagramN
  = InternalDiagram
  { source :: Diagram
  , cospans :: List Cospan
  , hash :: Lazy Int
  }

derive instance newtypeDiagramN :: Newtype DiagramN _

derive instance genericDiagramN :: Generic DiagramN _

derive newtype instance showDiagramN :: Show DiagramN

-- | Construct a `DiagramN` from a source `Diagram` and a list of `Cospan`s. No
-- | validation is performed on the input.
unsafeMake :: Diagram -> List Cospan -> DiagramN
unsafeMake s cs =
  InternalDiagram
    { source: s
    , cospans: cs
    , hash: defer \_ -> hash { source: s, cospans: cs }
    }

-- | Try to construct a `DiagramN` from a source `Diagram` and a list of
-- | `Cospan`s (smart constructor).
make :: Partial => Diagram -> List Cospan -> Maybe DiagramN
make s cs
  | isJust
      $ foldM
          ( \r { forward: f, backward: b } -> do
              sh <- safeRewriteForward f r
              safeRewriteBackward b sh
          )
          s
          (cs) = pure $ unsafeMake s cs
  | otherwise = empty

toDiagramN :: Partial => Diagram -> DiagramN
toDiagramN (DiagramN d) = d

-- | Promotes an n-dimensional diagram to an (n + 1)-dimensional diagram with
-- | the original diagram as its unique regular slice.
identity :: Diagram -> DiagramN
identity d = unsafeMake d Nil

-- | Every diagram has a dimension
dimension :: Diagram -> Int
dimension (Diagram0 _) = 0

dimension (DiagramN d) = 1 + dimension (source d)

-- | Every non-zero-dimensional diagram has a list of cospans.
cospans :: DiagramN -> List Cospan
cospans (InternalDiagram d) = d.cospans

-- | The size of a diagram in the top dimension. This is the number of cospans
-- | or equivalently the number of singular slices.
size :: DiagramN -> Int
size = cospans >>> length

instance eqDiagram :: Eq Diagram where
  eq (Diagram0 g) (Diagram0 g') = g == g'
  eq (DiagramN d) (DiagramN d') = d == d'
  eq _ _ = false

instance hashableDiagram :: Hashable Diagram where
  hash = case _ of
    Diagram0 g -> hash g
    DiagramN d -> hash d

instance eqDiagramN :: Eq DiagramN where
  eq = case _, _ of
    InternalDiagram d0, InternalDiagram d1
      | unsafeRefEq d0 d1 -> true
      | d0.hash /= d1.hash -> false
      | otherwise -> d0.source == d1.source && d0.cospans == d1.cospans

instance hashableDiagramN :: Hashable DiagramN where
  hash (InternalDiagram d) = force d.hash

-- | Creates a new diagram for a generator with a specified source and target.
fromGenerator :: Diagram -> Diagram -> Generator -> DiagramN
fromGenerator s t generator = unsafeMake s (cospan : Nil)
  where
  cospan = { forward: rewriteCone generator s, backward: rewriteCone generator t }

  rewriteCone :: Generator -> Diagram -> Rewrite
  rewriteCone g (Diagram0 base) = Rewrite0 { source: base, target: g }

  rewriteCone g (DiagramN base) =
    makeRewriteN (dimension (DiagramN base))
      $ ( { index: 0
          , source: cospans base
          , target: { forward: rewriteCone g (source base), backward: rewriteCone g (target base) }
          , slices: map (\sl -> rewriteCone g sl) $ singularSlices base
          }
            : Nil
        )

-- | The source slice of an (n + 1)-dimensional diagram.
source :: DiagramN -> Diagram
source (InternalDiagram d) = d.source

-- | The target slice of an (n + 1)-dimensional diagram.
target :: DiagramN -> Diagram
target = slices >>> NEL.last

-- | The slices of an (n + 1)-dimensional diagram.
slices :: DiagramN -> NonEmptyList Diagram
slices d = unsafePartial $ NonEmptyList (source d :| scanl (\s r -> r s) (source d) (concatMap genRewrites (cospans d)))
  where
  genRewrites :: Partial => Cospan -> List (Diagram -> Diagram)
  genRewrites { forward: fw, backward: bw } = rewriteForward fw : rewriteBackward bw : Nil

-- | Compute a forward `Rewrite` as a `Diagram -> Diagram` function.
-- |
-- | In a diagram, given a forward rewrite `fᵢ` and a regular level `rᵢ`,
-- | `rewriteForward fᵢ rᵢ` yields `sᵢ`: the subsequent singular level.
rewriteForward :: Partial => Rewrite -> Diagram -> Diagram
rewriteForward (Rewrite0 rewrite) (Diagram0 _) = Diagram0 rewrite.target

rewriteForward RewriteI (Diagram0 g) = Diagram0 g

rewriteForward (RewriteN { cones }) (DiagramN d') =
  DiagramN $ unsafeMake (source d')
    $ fst
    $ foldl
        ( \(Tuple cspans i) c ->
            let
              start = c.index + i

              end = start + coneSize c
            in
              Tuple
                (take start cspans <> c.target : drop end cspans)
                (i - coneSize c + 1)
        )
        (Tuple (cospans d') 0)
        cones

-- | Compute a backward `Rewrite` as a `Diagram -> Diagram` function.
-- |
-- | In a diagram, given a backward rewrite `bᵢ₊₁` and a regular level `rᵢ`,
-- | `rewriteBackward bᵢ₊₁ rᵢ` yields `sᵢ`: the subsequent singular level
-- | (rewriting happens in the *opposite* direction to the rewrite itself).
rewriteBackward :: Partial => Rewrite -> Diagram -> Diagram
rewriteBackward (Rewrite0 rewrite) (Diagram0 _) = Diagram0 rewrite.source

rewriteBackward RewriteI (Diagram0 g) = Diagram0 g

rewriteBackward (RewriteN { cones }) (DiagramN d') =
  DiagramN $ unsafeMake (source d')
    $ fst
    $ foldl
        ( \(Tuple cspans i) c ->
            let
              start = c.index + i
            in
              Tuple
                (take start cspans <> c.source <> drop (start + 1) cspans)
                (i + coneSize c - 1)
        )
        (Tuple (cospans d') 0)
        cones

-- same as `rewriteForward`, but also checks that the deleted cospans are the same source cospans in the cone
safeRewriteForward :: Partial => Rewrite -> Diagram -> Maybe Diagram
safeRewriteForward (RewriteN { cones }) (DiagramN d) =
  foldM
    ( \(Tuple cspans i) c -> do
        let
          start = c.index + i

          end = start + coneSize c
        guard (slice start end cspans == c.source)
        pure $ Tuple (take start cspans <> c.target : drop end cspans) (i - coneSize c + 1)
    )
    (Tuple (cospans d) 0)
    cones
    >>= (fst >>> unsafeMake (source d) >>> DiagramN >>> pure)

safeRewriteForward r d = pure $ rewriteForward r d

-- same as `rewriteBackward`, but also checks that the deleted cospan is the same target cospan in the cone
safeRewriteBackward :: Partial => Rewrite -> Diagram -> Maybe Diagram
safeRewriteBackward (RewriteN { cones }) (DiagramN d) =
  foldM
    ( \(Tuple cspans i) c -> do
        let
          start = c.index + i
        guard (index cspans start == (pure $ c.target))
        pure $ Tuple (take start cspans <> c.source <> drop (start + 1) cspans) (i + coneSize c - 1)
    )
    (Tuple (cospans d) 0)
    cones
    >>= (fst >>> unsafeMake (source d) >>> DiagramN >>> pure)

safeRewriteBackward r d = pure $ rewriteBackward r d

-- | The slice of an (n + 1)-dimensional diagram at a particular height.
sliceAt :: DiagramN -> SliceIndex -> Maybe Diagram
sliceAt d i = do
  height <- internalizeHeight d i
  slices d NEL.!! heightToIndex height
  where
  heightToIndex (Singular h) = h * 2 + 1

  heightToIndex (Regular h) = h * 2

-- | The list of the singular slices of an (n + 1)-dimensional diagram.
singularSlices :: DiagramN -> List Diagram
singularSlices d = keepOdds (NEL.toList (slices d))

-- | The list of the regular slices of an (n + 1)-dimensional diagram.
regularSlices :: DiagramN -> NonEmptyList Diagram
regularSlices d = wrap (source :| keepOdds rest)
  where
  source :| rest = unwrap (slices d)

keepOdds :: forall a. List a -> List a
keepOdds = everyOther <<< fromMaybe Nil <<< tail

everyOther :: forall a. List a -> List a
everyOther Nil = Nil

everyOther (x : Nil) = x : Nil

everyOther (x : _ : xs) = x : everyOther xs

internalizeHeight :: DiagramN -> SliceIndex -> Maybe Height
internalizeHeight _ (Boundary Source) = Just (Regular 0)

internalizeHeight d (Boundary Target) = Just (Regular (size d))

internalizeHeight d (Interior (Regular h))
  | h < 0 = Nothing
  | h > size d = Nothing
  | otherwise = Just (Regular h)

internalizeHeight d (Interior (Singular h))
  | h < 0 = Nothing
  | h >= size d = Nothing
  | otherwise = Just (Singular h)

type Embedding
  = List Int

checkCospanEmbedding :: Embedding -> List Cospan -> List Cospan -> Boolean
checkCospanEmbedding embedding needle haystack = needleCospans == haystackCospans
  where
  height = fromMaybe 0 (head embedding)

  rest = fromMaybe Nil (tail embedding)

  haystackCospans = take (length needle) $ drop height haystack

  needleCospans = map (cospanPad rest) needle

-- | Check whether a diagram embeds into another using a given embedding.
checkEmbedding :: Embedding -> Diagram -> Diagram -> Boolean
checkEmbedding embedding n h = case n, h of
  Diagram0 needle, Diagram0 haystack -> needle == haystack
  DiagramN _, Diagram0 _ -> false
  needle@(Diagram0 _), DiagramN haystack -> maybe false (checkEmbedding rest needle) (sliceAt haystack height)
  DiagramN needle, DiagramN haystack -> case compare (dimension $ DiagramN needle) (dimension $ DiagramN haystack) of
    LT -> maybe false (checkEmbedding rest (DiagramN needle)) (sliceAt haystack height)
    EQ ->
      maybe false (checkEmbedding rest (source needle)) (sliceAt haystack height)
        && checkCospanEmbedding embedding (cospans needle) (cospans haystack)
    GT -> false
  where
  height = Interior (Regular (fromMaybe 0 (head embedding)))

  rest = fromMaybe Nil (tail embedding)

-- | Enumerate the embeddings of one diagram into another.
enumerateEmbeddings ::
  Diagram ->
  Diagram ->
  List Embedding
enumerateEmbeddings n h = case n, h of
  Diagram0 needle, Diagram0 haystack
    | needle == haystack -> Nil : Nil
    | otherwise -> Nil
  DiagramN _, Diagram0 _ -> Nil
  Diagram0 needle, DiagramN haystack -> enumerateSliceEmbeddings (Diagram0 needle) haystack
  DiagramN needle, DiagramN haystack -> case compare (dimension (DiagramN needle)) (dimension (DiagramN haystack)) of
    LT -> enumerateSliceEmbeddings (DiagramN needle) haystack
    EQ -> do
      embedding <- enumerateSliceEmbeddings (source needle) haystack
      guard (checkCospanEmbedding embedding (cospans needle) (cospans haystack))
      pure embedding
    GT -> Nil
  where
  enumerateSliceEmbeddings :: Diagram -> DiagramN -> List Embedding
  enumerateSliceEmbeddings needle haystack = join $ mapWithIndex (\i slice -> map ((:) i) (enumerateEmbeddings needle slice)) $ NEL.toList $ regularSlices haystack

-- | Build diagrams from smaller diagrams. A `small` diagram is attached to a
-- | `large` diagram, where the attachment point is determined by `boundary`
-- | and `embedding`. `boundary` specifies the top-level dimension attachment
-- | point and `embedding` specifies the lower dimensional coordinates.
attach :: Boundary -> Embedding -> DiagramN -> DiagramN -> Maybe DiagramN
attach boundary embedding small large = unsafePartial $ go (dimension (DiagramN large) - dimension (DiagramN small)) boundary
  where
  go :: Partial => Int -> Boundary -> Maybe DiagramN
  go depth _
    | depth < 0 = Nothing

  go 0 Source = do
    guard (checkEmbedding embedding (target small) (source large))
    let
      cospansPadded = map (cospanPad embedding) (cospans small)
    pure $ unsafeMake (rewriteBackwards cospansPadded (source large)) (cospansPadded <> cospans large)

  go 0 Target = do
    guard (checkEmbedding embedding (source small) (target large))
    let
      cospansPadded = map (cospanPad embedding) (cospans small)
    pure $ unsafeMake (source large) (cospans large <> cospansPadded)

  go depth Source = do
    source_ <- attach boundary embedding small (toDiagramN (source large))
    pure $ unsafeMake (DiagramN source_) (map (padDepth depth (size small)) (cospans large))

  go _ Target = do
    source_ <- attach boundary embedding small (toDiagramN (source large))
    pure $ unsafeMake (DiagramN source_) (cospans large)

  padDepth :: Int -> Int -> Cospan -> Cospan
  padDepth depth pad cospan = cospanPad (replicate (depth - 1) 0 <> (pad : Nil)) cospan

  rewriteBackwards :: List Cospan -> Diagram -> Diagram
  rewriteBackwards cospans_ diagram = target $ unsafeMake diagram (reverse $ map cospanReverse cospans_)
