module Reach.Test_Eval
  ( spec_examples_cover_EvalError
  , spec_examples_cover_ParserError
  , test_compileBundle_errs
  )
where

import Control.DeepSeq
import Data.Proxy
import Reach.Eval
import Reach.Parser
import Reach.Test.Util
import Test.Hspec
import Test.Tasty

partialCompile :: FilePath -> IO ()
partialCompile fp = do
  bundle <- gatherDeps_top fp
  let prog = compileBundle bundle "main"
  return $! rnf prog

evalGoldenTest :: FilePath -> TestTree
evalGoldenTest = errExampleStripAbs ".txt" partialCompile

test_compileBundle_errs :: IO TestTree
test_compileBundle_errs = goldenTests evalGoldenTest ".rsh" "nl-eval-errors"

spec_examples_cover_EvalError :: Spec
spec_examples_cover_EvalError =
  mkSpecExamplesCoverCtors p exceptions ".rsh" "nl-eval-errors"
  where
    p = Proxy @EvalError
    exceptions =
      [ "Err_App_InvalidArgs"
      , "Err_CannotReturn" -- most attempts were not valid js
      , "Err_Decl_IllegalJS"
      , "Err_Each_NotTuple"
      , "Err_Eval_IllegalLift"
      , "Err_Eval_IndirectRefNotArray"
      , "Err_Eval_NoReturn" -- not syntactically possible?
      , "Err_Eval_NotApplicableVals" -- previous test example subsumed by Err_ToConsensus_TimeoutArgs
      , "Err_Form_InvalidArgs" -- previous test example subsumed by Err_Only_NotOneClosure
      , "Err_Import_IllegalJS"
      , "Err_Obj_IllegalFieldValues" -- not possible with Grammar7?
      , "Err_ToConsensus_Double" -- prevented by earlier parsing?
      , "Err_TopFun_NoName" -- hiding behind Err_Type_None
      , "Err_Transfer_NotBound"
      , "Err_While_IllegalInvariant"
      ]

spec_examples_cover_ParserError :: Spec
spec_examples_cover_ParserError =
  mkSpecExamplesCoverCtors p exceptions ".rsh" "nl-eval-errors"
  where
    p = Proxy @ParserError
    exceptions =
      [ "Err_Parser_Arrow_NoFormals" -- (=> e) didn't work
      , "Err_Parse_IllegalLiteral" -- undefined didn't work
      , "Err_Parse_NotModule"
      ]
