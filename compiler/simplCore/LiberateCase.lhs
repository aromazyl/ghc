%
% (c) The AQUA Project, Glasgow University, 1994-1998
%
\section[LiberateCase]{Unroll recursion to allow evals to be lifted from a loop}

\begin{code}
module LiberateCase ( liberateCase ) where

#include "HsVersions.h"

import DynFlags
import HscTypes
import CoreLint		( showPass, endPass )
import CoreSyn
import CoreUnfold	( couldBeSmallEnoughToInline )
import Rules		( RuleBase )
import UniqSupply	( UniqSupply )
import SimplMonad	( SimplCount, zeroSimplCount )
import Id
import VarEnv
import Name		( localiseName )
import Util             ( notNull )
\end{code}

The liberate-case transformation
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
This module walks over @Core@, and looks for @case@ on free variables.
The criterion is:
	if there is case on a free on the route to the recursive call,
	then the recursive call is replaced with an unfolding.

Example

   f = \ t -> case v of
	         V a b -> a : f t

=> the inner f is replaced.

   f = \ t -> case v of
	         V a b -> a : (letrec
				f =  \ t -> case v of
					       V a b -> a : f t
			       in f) t
(note the NEED for shadowing)

=> Simplify

  f = \ t -> case v of
	         V a b -> a : (letrec
				f = \ t -> a : f t
			       in f t)

Better code, because 'a' is  free inside the inner letrec, rather
than needing projection from v.

Other examples we'd like to catch with this kind of transformation

	last []     = error 
	last (x:[]) = x
	last (x:xs) = last xs

We'd like to avoid the redundant pattern match, transforming to

	last [] = error
	last (x:[]) = x
	last (x:(y:ys)) = last' y ys
		where
		  last' y []     = y
		  last' _ (y:ys) = last' y ys

	(is this necessarily an improvement)

Similarly drop:

	drop n [] = []
	drop 0 xs = xs
	drop n (x:xs) = drop (n-1) xs

Would like to pass n along unboxed.
	
Note [Scrutinee with cast]
~~~~~~~~~~~~~~~~~~~~~~~~~~
Consider this:
    f = \ t -> case (v `cast` co) of
	         V a b -> a : f t

Exactly the same optimisation (unrolling one call to f) will work here, 
despite the cast.  See mk_alt_env in the Case branch of libCase.


To think about (Apr 94)
~~~~~~~~~~~~~~

Main worry: duplicating code excessively.  At the moment we duplicate
the entire binding group once at each recursive call.  But there may
be a group of recursive calls which share a common set of evaluated
free variables, in which case the duplication is a plain waste.

Another thing we could consider adding is some unfold-threshold thing,
so that we'll only duplicate if the size of the group rhss isn't too
big.

Data types
~~~~~~~~~~
The ``level'' of a binder tells how many
recursive defns lexically enclose the binding
A recursive defn "encloses" its RHS, not its
scope.  For example:
\begin{verbatim}
	letrec f = let g = ... in ...
	in
	let h = ...
	in ...
\end{verbatim}
Here, the level of @f@ is zero, the level of @g@ is one,
and the level of @h@ is zero (NB not one).


%************************************************************************
%*									*
	 Top-level code
%*									*
%************************************************************************

\begin{code}
liberateCase :: HscEnv -> UniqSupply -> RuleBase -> ModGuts
	     -> IO (SimplCount, ModGuts)
liberateCase hsc_env _ _ guts
  = do	{ let dflags = hsc_dflags hsc_env

	; showPass dflags "Liberate case"
	; let { env = initEnv dflags
	      ; binds' = do_prog env (mg_binds guts) }
	; endPass dflags "Liberate case" Opt_D_verbose_core2core binds'
			{- no specific flag for dumping -} 
	; return (zeroSimplCount dflags, guts { mg_binds = binds' }) }
  where
    do_prog env [] = []
    do_prog env (bind:binds) = bind' : do_prog env' binds
			     where
			       (env', bind') = libCaseBind env bind
\end{code}


%************************************************************************
%*									*
	 Main payload
%*									*
%************************************************************************

Bindings
~~~~~~~~
\begin{code}
libCaseBind :: LibCaseEnv -> CoreBind -> (LibCaseEnv, CoreBind)

libCaseBind env (NonRec binder rhs)
  = (addBinders env [binder], NonRec binder (libCase env rhs))

libCaseBind env (Rec pairs)
  = (env_body, Rec pairs')
  where
    (binders, rhss) = unzip pairs

    env_body = addBinders env binders

    pairs' = [(binder, libCase env_rhs rhs) | (binder,rhs) <- pairs]

    env_rhs = if all rhs_small_enough rhss then extended_env else env

	-- We extend the rec-env by binding each Id to its rhs, first
	-- processing the rhs with an *un-extended* environment, so
	-- that the same process doesn't occur for ever!
	--
    extended_env = addRecBinds env [ (adjust binder, libCase env_body rhs)
				   | (binder, rhs) <- pairs ]

	-- Two subtle things: 
	-- (a)  Reset the export flags on the binders so
	-- 	that we don't get name clashes on exported things if the 
	-- 	local binding floats out to top level.  This is most unlikely
	-- 	to happen, since the whole point concerns free variables. 
	-- 	But resetting the export flag is right regardless.
	-- 
	-- (b)  Make the name an Internal one.  External Names should never be
	--	nested; if it were floated to the top level, we'd get a name
	-- 	clash at code generation time.
    adjust bndr = setIdNotExported (setIdName bndr (localiseName (idName bndr)))

    rhs_small_enough rhs = couldBeSmallEnoughToInline lIBERATE_BOMB_SIZE rhs
    lIBERATE_BOMB_SIZE   = bombOutSize env
\end{code}


Expressions
~~~~~~~~~~~

\begin{code}
libCase :: LibCaseEnv
	-> CoreExpr
	-> CoreExpr

libCase env (Var v)		= libCaseId env v
libCase env (Lit lit)		= Lit lit
libCase env (Type ty)		= Type ty
libCase env (App fun arg)       = App (libCase env fun) (libCase env arg)
libCase env (Note note body)    = Note note (libCase env body)
libCase env (Cast e co)         = Cast (libCase env e) co

libCase env (Lam binder body)
  = Lam binder (libCase (addBinders env [binder]) body)

libCase env (Let bind body)
  = Let bind' (libCase env_body body)
  where
    (env_body, bind') = libCaseBind env bind

libCase env (Case scrut bndr ty alts)
  = Case (libCase env scrut) bndr ty (map (libCaseAlt env_alts) alts)
  where
    env_alts = addBinders (mk_alt_env scrut) [bndr]
    mk_alt_env (Var scrut_var) = addScrutedVar env scrut_var
    mk_alt_env (Cast scrut _)  = mk_alt_env scrut	-- Note [Scrutinee with cast]
    mk_alt_env otehr	       = env

libCaseAlt env (con,args,rhs) = (con, args, libCase (addBinders env args) rhs)
\end{code}


Ids
~~~
\begin{code}
libCaseId :: LibCaseEnv -> Id -> CoreExpr
libCaseId env v
  | Just the_bind <- lookupRecId env v	-- It's a use of a recursive thing
  , notNull free_scruts 		-- with free vars scrutinised in RHS
  = Let the_bind (Var v)

  | otherwise
  = Var v

  where
    rec_id_level = lookupLevel env v
    free_scruts  = freeScruts env rec_id_level
\end{code}


%************************************************************************
%*									*
	Utility functions
%*									*
%************************************************************************

\begin{code}
addBinders :: LibCaseEnv -> [CoreBndr] -> LibCaseEnv
addBinders env@(LibCaseEnv { lc_lvl = lvl, lc_lvl_env = lvl_env }) binders
  = env { lc_lvl_env = lvl_env' }
  where
    lvl_env' = extendVarEnvList lvl_env (binders `zip` repeat lvl)

addRecBinds :: LibCaseEnv -> [(Id,CoreExpr)] -> LibCaseEnv
addRecBinds env@(LibCaseEnv {lc_lvl = lvl, lc_lvl_env = lvl_env, 
			     lc_rec_env = rec_env}) pairs
  = env { lc_lvl = lvl', lc_lvl_env = lvl_env', lc_rec_env = rec_env' }
  where
    lvl'     = lvl + 1
    lvl_env' = extendVarEnvList lvl_env [(binder,lvl) | (binder,_) <- pairs]
    rec_env' = extendVarEnvList rec_env [(binder, Rec pairs) | (binder,_) <- pairs]

addScrutedVar :: LibCaseEnv
	      -> Id		-- This Id is being scrutinised by a case expression
	      -> LibCaseEnv

addScrutedVar env@(LibCaseEnv { lc_lvl = lvl, lc_lvl_env = lvl_env, 
				lc_scruts = scruts }) scrut_var
  | bind_lvl < lvl
  = env { lc_scruts = scruts' }
	-- Add to scruts iff the scrut_var is being scrutinised at
	-- a deeper level than its defn

  | otherwise = env
  where
    scruts'  = (scrut_var, lvl) : scruts
    bind_lvl = case lookupVarEnv lvl_env scrut_var of
		 Just lvl -> lvl
		 Nothing  -> topLevel

lookupRecId :: LibCaseEnv -> Id -> Maybe CoreBind
lookupRecId env id = lookupVarEnv (lc_rec_env env) id

lookupLevel :: LibCaseEnv -> Id -> LibCaseLevel
lookupLevel env id
  = case lookupVarEnv (lc_lvl_env env) id of
      Just lvl -> lvl
      Nothing  -> topLevel

freeScruts :: LibCaseEnv
	   -> LibCaseLevel 	-- Level of the recursive Id
	   -> [Id]		-- Ids that are scrutinised between the binding
				-- of the recursive Id and here
freeScruts env rec_bind_lvl
  = [v | (v,scrut_lvl) <- lc_scruts env, scrut_lvl > rec_bind_lvl]
\end{code}

%************************************************************************
%*									*
	 The environment
%*									*
%************************************************************************

\begin{code}
type LibCaseLevel = Int

topLevel :: LibCaseLevel
topLevel = 0
\end{code}

\begin{code}
data LibCaseEnv
  = LibCaseEnv {
	lc_size :: Int,		-- Bomb-out size for deciding if
				-- potential liberatees are too big.
				-- (passed in from cmd-line args)

	lc_lvl :: LibCaseLevel,	-- Current level

	lc_lvl_env :: IdEnv LibCaseLevel,  
			-- Binds all non-top-level in-scope Ids
			-- (top-level and imported things have
			-- a level of zero)

	lc_rec_env :: IdEnv CoreBind, 
			-- Binds *only* recursively defined ids, 
			-- to their own binding group,
			-- and *only* in their own RHSs

	lc_scruts :: [(Id,LibCaseLevel)]
     			-- Each of these Ids was scrutinised by an
			-- enclosing case expression, with the
			-- specified number of enclosing
			-- recursive bindings; furthermore,
			-- the Id is bound at a lower level
			-- than the case expression.  The order is
			-- insignificant; it's a bag really
	}

initEnv :: DynFlags -> LibCaseEnv
initEnv dflags 
  = LibCaseEnv { lc_size = specThreshold dflags,
		 lc_lvl = 0,
		 lc_lvl_env = emptyVarEnv, 
		 lc_rec_env = emptyVarEnv,
		 lc_scruts = [] }

bombOutSize = lc_size
\end{code}


