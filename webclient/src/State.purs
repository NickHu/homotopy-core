module Homotopy.Webclient.State where

import Prelude
import Data.Foldable (all, foldr)
import Data.Lens (Lens', Traversal', _Just)
import Data.Lens as Lens
import Data.Lens.At (at)
import Data.List (List(..), (:))
import Data.List as List
import Data.Map (Map)
import Data.Maybe (Maybe(..), fromJust)
import Effect (Effect)
import Homotopy.Core.Common (Boundary(..), Generator(..), Height(..), SliceIndex(..))
import Homotopy.Core.Diagram (Diagram(..), DiagramN)
import Homotopy.Core.Diagram as Diagram
import Homotopy.Webclient.Lenses as R
import Partial.Unsafe (unsafePartial)

type State
  = { signature :: Signature
    , project :: Project
    , view :: Maybe View
    , workspace :: Maybe Workspace
    }

type Workspace
  = { diagram :: Diagram
    , path :: List SliceIndex
    }

type Signature
  = { generators :: Map Generator GeneratorInfo
    }

type GeneratorInfo
  = { name :: String
    , color :: String
    }

type Project
  = { name :: String
    , abstract :: String
    }

-------------------------------------------------------------------------------
data View
  = ViewSignature
  | ViewProject
  | ViewUser

derive instance viewEq :: Eq View

derive instance viewOrd :: Ord View

-------------------------------------------------------------------------------
data Action
  = ToggleView View
  | RenameGenerator Generator String
  | RecolorGenerator Generator String
  | SelectGenerator Generator
  | DescendSlice SliceIndex
  | AscendSlice Int
  | ClearWorkspace
  | IdentityDiagram
  | MakeBoundary Boundary
  | RestrictDiagram

-------------------------------------------------------------------------------
_generator :: Generator -> Lens' State (Maybe GeneratorInfo)
_generator id = R.signature <<< R.generators <<< at id

_path :: Traversal' State (List SliceIndex)
_path = R.workspace <<< _Just <<< R.path

-------------------------------------------------------------------------------
initial :: State
initial =
  { signature:
      { generators: mempty
      }
  , project:
      { name: ""
      , abstract: ""
      }
  , view: Nothing
  , workspace:
      Just
        { path: Nil
        , diagram: DiagramN associativity
        }
  }

-------------------------------------------------------------------------------
reduce :: Action -> State -> State
reduce action = case action of
  --
  ToggleView view -> \state ->
    if state.view == Just view then
      state { view = Nothing }
    else
      state { view = Just view }
  --
  RenameGenerator id name -> Lens.set (_generator id <<< _Just <<< R.name) name
  --
  RecolorGenerator id color -> Lens.set (_generator id <<< _Just <<< R.color) color
  --
  SelectGenerator id -> \state -> state
  --
  DescendSlice index -> Lens.over _path (index : _)
  --
  AscendSlice count -> Lens.over _path (List.drop count)
  --
  ClearWorkspace -> _ { workspace = Nothing }
  --
  IdentityDiagram ->
    Lens.over (R.workspace <<< _Just) \workspace ->
      { diagram: DiagramN (Diagram.identity workspace.diagram)
      , path: workspace.path
      }
  --
  MakeBoundary boundary -> \state -> state -- TODO
  --
  RestrictDiagram ->
    Lens.over (R.workspace <<< _Just) \workspace ->
      let
        isNonSingular = case _ of
          Interior (Singular _) -> false
          _ -> true

        sliceAt i d = unsafePartial $ fromJust $ Diagram.sliceAt (Diagram.toDiagramN d) i
      in
        if all isNonSingular workspace.path then
          { diagram: foldr sliceAt workspace.diagram workspace.path, path: Nil }
        else
          workspace

-------------------------------------------------------------------------------
type Store
  = { state :: State
    , dispatch :: Action -> Effect Unit
    }

-------------------------------------------------------------------------------
associativity :: DiagramN
associativity =
  let
    attach b e s l = unsafePartial $ fromJust $ Diagram.attach b e s l

    x = Generator { id: 0, dimension: 0 }

    f = Generator { id: 1, dimension: 1 }

    m = Generator { id: 2, dimension: 2 }

    a = Generator { id: 3, dimension: 3 }

    fd = Diagram.fromGenerator (Diagram0 x) (Diagram0 x) f

    ffd = attach Target Nil fd fd

    md = Diagram.fromGenerator (DiagramN ffd) (DiagramN fd) m

    mfd = attach Target Nil fd md

    ld = attach Target Nil md mfd

    fmd = attach Source Nil fd md

    rd = attach Target Nil md fmd

    ad = Diagram.fromGenerator (DiagramN ld) (DiagramN rd) a
  in
    ad
