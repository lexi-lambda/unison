{-# Language OverloadedStrings #-}

module Unison.FileParser where

-- import           Text.Parsec.Prim (ParsecT)
import           Control.Applicative
import           Control.Arrow (second)
import           Control.Monad.Reader
import           Data.Either (partitionEithers)
import           Data.Map (Map)
import qualified Data.Map as Map
import qualified Data.Text as Text
import           Prelude hiding (readFile)
import qualified Text.Parsec.Layout as L
import qualified Unison.ABT as ABT
import           Unison.DataDeclaration (DataDeclaration(..), hashDecls, EffectDeclaration(..), mkEffectDecl)
-- import           Unison.Parser
import           Unison.Parser (Parser, PEnv, traced, token_, sepBy, string)
import           Unison.Reference (Reference)
import           Unison.Term (Term)
import qualified Unison.Term as Term
import qualified Unison.TermParser as TermParser
import qualified Unison.Type as Type
import           Unison.TypeParser (S)
import qualified Unison.TypeParser as TypeParser
import           Unison.Var (Var)
import qualified Unison.Var as Var

-- import qualified Unison.TypeParser as TypeParser

data UnisonFile v = UnisonFile {
  dataDeclarations :: Map v (Reference, DataDeclaration v),
  effectDeclarations :: Map v (Reference, EffectDeclaration v),
  term :: Term v
} deriving (Show)

file :: Var v => [(v, Term v)] -> Parser (S v) (UnisonFile v)
file builtinEnv = traced "file" $ do
  (dataDecls, effectDecls) <- traced "declarations" declarations
  let (dataDecls', effectDecls', penv') = environmentFor dataDecls effectDecls
  local (`Map.union` penv') $ do
    term <- TermParser.block
    let dataEnv0 = Map.fromList [ (Var.named (Text.pack n), Term.constructor r i) | (n, (r,i)) <- Map.toList penv' ]
        dataEnv = dataEnv0 `Map.difference` effectDecls
        effectEnv = dataEnv0 `Map.difference` dataEnv
    let term2 = ABT.substs (builtinEnv ++ Map.toList dataEnv ++ Map.toList effectEnv) term
    pure $ UnisonFile dataDecls' effectDecls' term2

environmentFor :: Var v
               => Map v (DataDeclaration v)
               -> Map v (EffectDeclaration v)
               -> (Map v (Reference, DataDeclaration v),
                   Map v (Reference, EffectDeclaration v),
                   PEnv)
environmentFor dataDecls effectDecls =
  let hashDecls' = hashDecls (Map.union dataDecls (toDataDecl <$> effectDecls))
      allDecls = Map.fromList [ (v, (r,de)) | (v,r,de) <- hashDecls' ]
      dataDecls' = Map.difference allDecls effectDecls
      effectDecls' = second EffectDeclaration <$> Map.difference allDecls dataDecls
  in (dataDecls', effectDecls', Map.fromList (constructors' =<< hashDecls'))

constructors' :: Var v => (v, Reference, DataDeclaration v) -> [(String, (Reference, Int))]
constructors' (typeSymbol, r, (DataDeclaration _ constructors)) =
  let qualCtorName ((ctor,_), i) =
       (Text.unpack $ mconcat [Var.qualifiedName typeSymbol, ".", Var.qualifiedName ctor], (r, i))
  in qualCtorName <$> constructors `zip` [0..]

declarations :: Var v => Parser (S v)
                         (Map v (DataDeclaration v),
                          Map v (EffectDeclaration v))
declarations = do
  declarations <- many ((Left <$> dataDeclaration) <|> Right <$> effectDeclaration)
  let (dataDecls, effectDecls) = partitionEithers declarations
  pure (Map.fromList dataDecls, Map.fromList effectDecls)


dataDeclaration :: Var v => Parser (S v) (v, DataDeclaration v)
dataDeclaration = traced "data declaration" $ do
  token_ $ string "type"
  (name, typeArgs) <- --L.withoutLayout "type introduction" $
    (,) <$> TermParser.prefixVar <*> traced "many prefixVar" (many TermParser.prefixVar)
  traced "=" . token_ $ string "="
  -- dataConstructorTyp gives the type of the constructor, given the types of
  -- the constructor arguments, e.g. Cons becomes forall a . a -> List a -> List a
  let dataConstructorTyp ctorArgs =
        Type.foralls typeArgs $ Type.arrows ctorArgs (Type.apps (Type.var name) (Type.var <$> typeArgs))
      dataConstructor =
        (,) <$> TermParser.prefixVar
            <*> (dataConstructorTyp <$> many TypeParser.valueTypeLeaf)
  traced "vblock" $ L.vblockIncrement $ do
    constructors <- traced "constructors" $ sepBy (token_ $ string "|") dataConstructor
    pure $ (name, DataDeclaration typeArgs constructors)


effectDeclaration :: Var v => Parser (S v) (v, EffectDeclaration v)
effectDeclaration = traced "effect declaration" $ do
  token_ $ string "effect"
  name <- TermParser.prefixVar
  typeArgs <- many TermParser.prefixVar
  token_ $ string "where"
  L.vblockNextToken $ do
    constructors <- sepBy L.vsemi constructor
    pure $ (name, mkEffectDecl typeArgs constructors)
  where
    constructor = (,) <$> (TermParser.prefixVar <* token_ (string ":")) <*> traced "computation type" TypeParser.computationType
