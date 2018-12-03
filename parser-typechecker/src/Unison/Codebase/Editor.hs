{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE GADTs #-}

module Unison.Codebase.Editor where

import           Data.Sequence                  ( Seq )
import           Data.Set                       ( Set )
import           Data.Text                      ( Text )
import           Unison.Codebase                ( Codebase )
import qualified Unison.Codebase               as Codebase
import           Unison.Codebase.Branch         ( Branch
                                                , Branch0
                                                )
import qualified Unison.Codebase.Branch        as Branch
-- import           Unison.DataDeclaration     (DataDeclaration', EffectDeclaration')
import           Unison.Names                   ( Name
                                                , NameTarget
                                                , Referent
                                                )
import           Unison.Parser                  ( Ann )
import qualified Unison.Parser                 as Parser
import qualified Unison.PrettyPrintEnv         as PPE
import           Unison.Reference               ( Reference )
import           Unison.Result                  ( Note
                                                , Result
                                                )
import qualified Unison.Term                   as Term
import qualified Unison.Type                   as Type
import qualified Unison.Typechecker.Context    as Context
import qualified Unison.UnisonFile             as UF
import           Unison.Util.Free               ( Free )
import qualified Unison.Util.Free              as Free
import           Unison.Var                     ( Var )

type BranchName = Name
type Source = Text -- "id x = x\nconst a b = a"
type SourceName = Text -- "foo.u" or "buffer 7"
type TypecheckingResult v =
  Result (Seq (Note v Ann))
         (PPE.PrettyPrintEnv, Maybe (UF.TypecheckedUnisonFile' v Ann))
type Term v a = Term.AnnotatedTerm v a
type Type v a = Type.AnnotatedType v a

data AddOutputComponent v =
  AddOutputComponent { implicatedTypes :: Set v, implicatedTerms :: Set v }

data AddOutput v
  = NothingToAdd
  | NoBranch BranchName
  | Added {
          -- The file that we tried to add from
            originalFile :: UF.TypecheckedUnisonFile v Ann
          -- Previously existed only in the file; now added to the codebase.
          , successful :: AddOutputComponent v
          -- Exists in the branch and the file, with the same name and contents.
          , duplicates :: AddOutputComponent v
          -- Already defined in the branch, but with a different name.
          , duplicateReferents :: AddOutputComponent v
          -- Has a colliding name but a different definition than the codebase.
          , collisions :: AddOutputComponent v
          }

data SearchType = Exact | Fuzzy

data Input
  -- high-level manipulation of names
  = AliasUnconflictedI NameTarget Name Name
  | RenameUnconflictedI NameTarget Name Name
  | UnnameAllI NameTarget Name
  -- low-level manipulation of names
  | AddTermNameI Referent Name
  | AddTypeNameI Reference Name
  | AddPatternNameI Reference Int Name
  | RemoveTermNameI Referent Name
  | RemoveTypeNameI Reference Name
  | RemovePatternNameI Reference Int Name
  -- resolving naming conflicts
  | ChooseTermForNameI Referent Name
  | ChooseTypeForNameI Reference Name
  | ChoosePatternForNameI Reference Int Name
  -- create and remove update directives
  | AddTermUpdateI Referent Referent
  | AddTypeUpdateI Reference Reference
  | RemoveTermUpdateI Referent Referent
  | RemoveTypeUpdateI Referent Referent
  | ListUpdatesI
  -- other
  | AddI -- [Name]
  | ListBranchesI
  | SearchByNameI SearchType String
  | SwitchBranchI BranchName
  | ForkBranchI BranchName
  | MergeBranchI BranchName
  | QuitI

data Output v
  = Success Input
  | NoUnisonFile
  | UnknownBranch BranchName
  | UnknownName BranchName NameTarget Name
  | NameAlreadyExists BranchName NameTarget Name
  -- `name` refers to more than one `nameTarget`
  | ConflictedName BranchName NameTarget Name
  | BranchAlreadyExists BranchName
  | ListOfBranches [BranchName]
  | SearchResult BranchName SearchType String [(Name, Referent, Type v Ann)] [(Name, Reference {-, Kind -})] [(Name, Reference, Int, Type v Ann)]
  | AddOutput (AddOutput v)
  | ParseErrors [Parser.Err v]
  | TypeErrors PPE.PrettyPrintEnv [Context.ErrorNote v Ann]

data Command i v a where
  Input :: Command i v (Either (TypecheckingResult v) i)

  -- Presents some output to the user
  Notify :: Output v -> Command i v ()

  Add :: BranchName -> UF.TypecheckedUnisonFile' v Ann -> Command i v (AddOutput v)

  Typecheck :: SourceName -> Source -> Command i v (TypecheckingResult v)

  -- Load definitions from codebase:
  -- option 1:
      -- LoadTerm :: Reference -> Command i v (Maybe (Term v Ann))
      -- LoadTypeOfTerm :: Reference -> Command i v (Maybe (Type v Ann))
      -- LoadDataDeclaration :: Reference -> Command i v (Maybe (DataDeclaration' v Ann))
      -- LoadEffectDeclaration :: Reference -> Command i v (Maybe (EffectDeclaration' v Ann))
  -- option 2:
      -- LoadTerm :: Reference -> Command i v (Maybe (Term v Ann))
      -- LoadTypeOfTerm :: Reference -> Command i v (Maybe (Type v Ann))
      -- LoadTypeDecl :: Reference -> Command i v (Maybe (TypeLookup.Decl v Ann))
  -- option 3:
      -- TypeLookup :: [Reference] -> Command i v (TypeLookup.TypeLookup)

  ListBranches :: Command i v [BranchName]

  -- Loads a branch by name from the codebase, returning `Nothing` if not found.
  LoadBranch :: BranchName -> Command i v (Maybe Branch)

  -- Returns `Nothing` if a branch by that name already exists.
  NewBranch :: BranchName -> Command i v Bool

  -- Create a new branch which is a copy of the given branch, and assign the
  -- forked branch the given name. Returns `False` if the forked branch name
  -- already exists.
  ForkBranch :: Branch -> BranchName -> Command i v Bool

  -- Merges the branch with the existing branch with the given name. Returns
  -- `Nothing` if no branch with that name exists.
  MergeBranch :: BranchName -> Branch -> Command i v Bool

  -- Return the subset of the branch tip which is in a conflicted state
  GetConflicts :: BranchName -> Command i v (Maybe Branch0)

  -- Tell the UI to display a set of conflicts
  DisplayConflicts :: Branch0 -> Command i v ()

  -- RemainingWork :: Branch -> Command i v [RemainingWork]

  -- idea here is to find "close matches" of stuff in the input file, so
  -- can suggest use of preexisting definitions
  -- Search :: UF.TypecheckedUnisonFile' v Ann -> Command v (UF.TypecheckedUnisonFile' v Ann?)

notifyUser :: Output v -> IO ()
notifyUser = undefined

addToBranch :: Var v => Branch -> UF.TypecheckedUnisonFile v Ann -> AddOutput v
addToBranch branch unisonFile
  = let
      branchUpdate = Branch.fromTypecheckedFile unisonFile
      collisions   = Branch.collisions branchUpdate branch
      duplicates   = Branch.duplicates branchUpdate branch
      dupeRefs     = Branch.ours
        $ Branch.diff' (Branch.refCollisions branchUpdate branch) duplicates
      successes = Branch.ours
        $ Branch.diff' branchUpdate (collisions <> duplicates <> dupeRefs)
      mkOutput x =
        uncurry AddOutputComponent $ Branch.intersectWithFile x unisonFile
    in
      Added unisonFile
            (mkOutput successes)
            (mkOutput duplicates)
            (mkOutput dupeRefs)
            (mkOutput collisions)

commandLine
  :: forall i v a
   . Var v
  => IO (Either (TypecheckingResult v) i)
  -> Codebase IO v Ann
  -> Free (Command i v) a
  -> IO a
commandLine awaitInput codebase command = do
  Free.fold go command
 where
  go :: forall x . Command i v x -> IO x
  go = \case
    -- Wait until we get either user input or a unison file update
    Input                     -> awaitInput
    Notify output             -> notifyUser output
    Add branchName unisonFile -> do
      branch <- Codebase.getBranch codebase branchName
      case branch of
        Nothing -> pure $ NoBranch branchName
        Just branch ->
          pure . addToBranch branch $ UF.discardTopLevelTerm unisonFile
